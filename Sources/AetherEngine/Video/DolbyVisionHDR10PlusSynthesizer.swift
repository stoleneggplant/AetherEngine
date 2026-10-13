import Foundation
import AetherLibavcodec
import AetherLibavutil
import Dovi

/// Per-session packet rewrite for `LoadOptions.convertsDolbyVisionToHDR10Plus`.
///
/// For each HEVC access unit, in this order of preference:
/// 1. The source's own HDR10+ SEI, when the picture carries one: passed through untouched.
/// 2. The source's own HDR10+ as packet side data (a Matroska BlockAddition, which never reaches AVPlayer):
///    re-serialized into a prefix SEI.
/// 3. HDR10+ derived from the RPU: L1 (and CM v4.0 L3) read with libdovi and mapped through
///    `DolbyVisionHDR10PlusMapping` into a prefix SEI.
///
/// Derived metadata is never mixed with native metadata. A session whose load-time audit
/// (`DolbyVisionHDR10PlusAudit`) found native HDR10+ never derives, and one that meets native HDR10+ mid-stream
/// (a custom reader has no audit) stops deriving from that picture on. A picture with nothing to serve under
/// rule 1 or 2 in such a session goes without, rather than with a derived value next to graded ones.
///
/// The SEI goes in front of the access unit's first slice. A Profile 7 enhancement layer (unspec63), which
/// nothing on this route decodes, is dropped. Everything else, the RPU included, passes through byte for
/// byte, so the HDR10 base layer is the same picture it was. The HDR10+ scan downstream
/// (`HDR10PlusMetadataScan`) sees the SEI like any other, which flips the published `videoFormat` to
/// `.hdr10Plus`.
///
/// Not thread-safe: one instance belongs to one producer read loop (or one I-frame read).
final class DolbyVisionHDR10PlusSynthesizer {

    enum Outcome: Equatable {
        /// An SEI derived from the RPU was spliced in front of the first slice.
        case derived
        /// The picture's own HDR10+ SEI was passed through.
        case nativeInBand
        /// The picture's own HDR10+ side data was serialized into an SEI.
        case nativeFromSideData
        /// Nothing to serve: no RPU with L1 seen yet, no slice to put an SEI in front of, or a session with
        /// native HDR10+ on a picture that has none.
        case noMetadata
        /// The packet is in a framing this rewrite does not emit (a 1/2/3-byte length prefix).
        case unsupportedFraming
    }

    private static let nalTypeRPU: UInt8 = 62
    private static let nalTypeEL: UInt8 = 63
    private static let lengthPrefixSize = 4

    private let dropsEnhancementLayer: Bool
    /// Native HDR10+ is known to exist (from the audit, or seen in an earlier picture): never derive.
    private(set) var servesNativeHDR10Plus: Bool
    private(set) var derivedCount = 0
    /// The last L1 an RPU carried. A Dolby Vision RPU states L1 per shot and some encoders omit the block
    /// on frames that repeat it, so a frame without one keeps the shot's value rather than losing HDR10+.
    private var currentLevel1: DolbyVisionHDR10PlusMapping.Level1?
    /// The SEI for `currentLevel1`, rebuilt only when the shot changes.
    private var cachedNAL: (level1: DolbyVisionHDR10PlusMapping.Level1, nal: [UInt8])?

    /// `nativeHDR10Plus` is the audit's answer, nil when there was none (a custom reader, a live source).
    init(nativeHDR10Plus: DolbyVisionHDR10PlusAudit.Result.NativeHDR10Plus? = nil,
         dropsEnhancementLayer: Bool = false) {
        self.dropsEnhancementLayer = dropsEnhancementLayer
        switch nativeHDR10Plus {
        case .inBand?, .sideDataOnly?: servesNativeHDR10Plus = true
        case .absent?, nil: servesNativeHDR10Plus = false
        }
    }

    private struct Unit {
        var start: Int        // offset of the unit's framing (length prefix or start code)
        var end: Int          // one past its last byte
        var type: UInt8
    }

    func process(
        _ packet: UnsafeMutablePointer<AVPacket>,
        framing: VideoNALFraming
    ) -> Outcome {
        guard let data = packet.pointee.data, packet.pointee.size > 2 else { return .noMetadata }
        let size = Int(packet.pointee.size)
        switch framing {
        case .annexB: break
        case .lengthPrefixed(let width): guard width == Self.lengthPrefixSize else { return .unsupportedFraming }
        }
        let base = UnsafePointer(data)

        // One walk: every unit's extent (to drop the enhancement layer and find the first slice) and this
        // access unit's RPU, which follows the slices.
        var units: [Unit] = []
        units.reserveCapacity(8)
        var level1: DolbyVisionHDR10PlusMapping.Level1?
        let readsRPU = !servesNativeHDR10Plus
        A53SEIParser.forEachNAL(base, size, framing) { nal, length in
            guard length >= 2 else { return }
            let type = (nal[0] >> 1) & 0x3F
            let nalOffset = nal - base
            units.append(Unit(start: Self.unitStart(nalOffset: nalOffset, in: base, framing: framing),
                              end: nalOffset + length, type: type))
            if readsRPU, type == Self.nalTypeRPU, level1 == nil {
                level1 = Self.level1(ofRPU: nal, length: length)
            }
        }
        // In Annex B a unit runs to the next start code; anything the walk did not reach is kept verbatim.
        if framing == .annexB {
            for i in units.indices { units[i].end = i + 1 < units.count ? units[i + 1].start : size }
        }
        if let level1 { currentLevel1 = level1 }

        var outcome: Outcome
        var sei: [UInt8]?
        if HDR10PlusMetadataScan.bytesCarryHDR10Plus(base, size: size, codecID: AV_CODEC_ID_HEVC, framing: framing) {
            servesNativeHDR10Plus = true
            outcome = .nativeInBand
        } else if let native = HDR10PlusMetadataScan.sideDataT35Payload(packet) {
            servesNativeHDR10Plus = true
            sei = DolbyVisionHDR10PlusMapping.hevcPrefixSEINAL(t35Payload: native)
            outcome = .nativeFromSideData
        } else if !servesNativeHDR10Plus, let shot = currentLevel1 {
            sei = derivedNAL(for: shot)
            outcome = .derived
        } else {
            outcome = .noMetadata
        }

        let firstSlice = units.firstIndex { $0.type < 32 }
        if firstSlice == nil, sei != nil {
            sei = nil
            outcome = .noMetadata
        }
        let dropsAny = dropsEnhancementLayer && units.contains { $0.type == Self.nalTypeEL }
        guard sei != nil || dropsAny else { return outcome }

        // Rebuild once: leading bytes, then each unit, the SEI in front of the first slice, the enhancement
        // layer left out, then whatever trailed the last unit the walk could read.
        var prefixedSEI: [UInt8] = []
        if let sei {
            switch framing {
            case .annexB:
                prefixedSEI = [0, 0, 0, 1] + sei
            case .lengthPrefixed:
                let n = sei.count
                prefixedSEI = [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF),
                               UInt8(n & 0xFF)] + sei
            }
        }
        let seiMarker = -1   // a piece whose bytes are `prefixedSEI`
        var pieces: [(offset: Int, count: Int)] = []
        var cursor = 0
        for (index, unit) in units.enumerated() {
            if unit.start > cursor { pieces.append((cursor, unit.start - cursor)) }
            if index == firstSlice, !prefixedSEI.isEmpty { pieces.append((seiMarker, prefixedSEI.count)) }
            if !(dropsEnhancementLayer && unit.type == Self.nalTypeEL) {
                pieces.append((unit.start, unit.end - unit.start))
            }
            cursor = max(cursor, unit.end)
        }
        if cursor < size { pieces.append((cursor, size - cursor)) }

        let total = pieces.reduce(0) { $0 + $1.count }
        // Degenerate: nothing left but the enhancement layer. Leave the packet rather than emit an empty one.
        guard total > 0 else { return outcome }
        let pad = Int(AV_INPUT_BUFFER_PADDING_SIZE)
        guard let newRef = av_buffer_alloc(total + pad), let dst = newRef.pointee.data else { return .noMetadata }
        var written = 0
        for piece in pieces {
            if piece.offset == seiMarker {
                prefixedSEI.withUnsafeBufferPointer { _ = memcpy(dst + written, $0.baseAddress!, $0.count) }
            } else {
                memcpy(dst + written, base + piece.offset, piece.count)
            }
            written += piece.count
        }
        memset(dst + total, 0, pad)   // decoders read past size
        av_buffer_unref(&packet.pointee.buf)
        packet.pointee.buf = newRef
        packet.pointee.data = newRef.pointee.data
        packet.pointee.size = Int32(total)
        if outcome == .derived { derivedCount += 1 }
        return outcome
    }

    private func derivedNAL(for shot: DolbyVisionHDR10PlusMapping.Level1) -> [UInt8] {
        if let cached = cachedNAL, cached.level1 == shot { return cached.nal }
        let nal = DolbyVisionHDR10PlusMapping.hevcPrefixSEINAL(
            t35Payload: DolbyVisionHDR10PlusMapping.t35Payload(DolbyVisionHDR10PlusMapping.metadata(for: shot)))
        cachedNAL = (shot, nal)
        return nal
    }

    /// Offset of the framing that introduces the NAL at `nalOffset`: its length prefix, or its start code (a
    /// 4-byte one when the byte before the 3-byte code is the zero the NAL walk trimmed off the previous unit).
    private static func unitStart(
        nalOffset: Int, in data: UnsafePointer<UInt8>, framing: VideoNALFraming
    ) -> Int {
        switch framing {
        case .lengthPrefixed(let width):
            return max(nalOffset - width, 0)
        case .annexB:
            var start = max(nalOffset - 3, 0)
            if start > 0, data[start - 1] == 0 { start -= 1 }
            return start
        }
    }

    /// L1 with L3 applied, from one unspec62 NAL (header included, emulation prevention intact, which is
    /// how libdovi takes it), or nil when the RPU does not parse or carries no L1.
    static func level1(ofRPU nal: UnsafePointer<UInt8>, length: Int) -> DolbyVisionHDR10PlusMapping.Level1? {
        guard let rpu = dovi_parse_unspec62_nalu(nal, length) else { return nil }
        defer { dovi_rpu_free(rpu) }
        guard dovi_rpu_get_error(rpu) == nil, let dm = dovi_rpu_get_vdr_dm_data(rpu) else { return nil }
        defer { dovi_rpu_free_vdr_dm_data(dm) }
        guard let l1 = dm.pointee.dm_data.level1 else { return nil }
        let level1 = DolbyVisionHDR10PlusMapping.Level1(
            minPQ: Int(l1.pointee.min_pq), maxPQ: Int(l1.pointee.max_pq), avgPQ: Int(l1.pointee.avg_pq))
        guard let l3 = dm.pointee.dm_data.level3 else { return level1 }
        return level1.applyingOffsets(
            min: Int(l3.pointee.min_pq_offset), max: Int(l3.pointee.max_pq_offset),
            avg: Int(l3.pointee.avg_pq_offset))
    }
}
