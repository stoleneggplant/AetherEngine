import Foundation
import AetherLibavcodec
import AetherLibavutil
import Dovi

/// Per-session HDR10+ synthesis from a Dolby Vision RPU (`DolbyVisionHandling.hdr10PlusOnNonDVDisplay`).
///
/// For each HEVC access unit it reads the RPU's L1 (and CM v4.0 L3) with libdovi, maps it through
/// `DolbyVisionHDR10PlusMapping`, and splices one ST 2094-40 prefix SEI in front of the access unit's first
/// slice. Everything else in the packet is passed through byte for byte, the RPU included, so the HDR10 base
/// layer the session serves is the same picture it was; only the dynamic metadata beside it is new. The
/// HDR10+ scan downstream (`HDR10PlusMetadataScan`) then sees the SEI like any other, which is what flips
/// the published `videoFormat` to `.hdr10Plus`.
///
/// It stands down for the whole session the first time the source turns out to carry HDR10+ SEI of its own
/// (Blu-ray Profile 7 and remuxes made from it often carry both): a graded HDR10+ track is better evidence
/// than one derived from L1, and two sets of ST 2094-40 messages per picture would contradict each other.
///
/// Not thread-safe: one instance belongs to one producer read loop.
final class DolbyVisionHDR10PlusSynthesizer {

    enum Outcome: Equatable {
        /// An HDR10+ SEI was spliced in front of the access unit's first slice.
        case injected
        /// The source carries HDR10+ itself; the session no longer synthesizes.
        case sourceCarriesHDR10Plus
        /// No RPU with L1 has been seen yet, or the packet holds no slice to put the SEI in front of.
        case noMetadata
        /// The packet is in a framing this rewrite does not emit (a 1/2/3-byte length prefix).
        case unsupportedFraming
    }

    private static let nalTypeRPU: UInt8 = 62
    private static let lengthPrefixSize = 4

    private(set) var injectedCount = 0
    private(set) var standsDown = false
    /// The last L1 an RPU carried. A Dolby Vision RPU states L1 per shot and some encoders omit the block
    /// on frames that repeat it, so a frame without one keeps the shot's value rather than losing HDR10+.
    private var currentLevel1: DolbyVisionHDR10PlusMapping.Level1?
    /// The SEI for `currentLevel1`, rebuilt only when the shot changes.
    private var cachedNAL: (level1: DolbyVisionHDR10PlusMapping.Level1, nal: [UInt8])?

    func process(
        _ packet: UnsafeMutablePointer<AVPacket>,
        framing: VideoNALFraming
    ) -> Outcome {
        if standsDown { return .sourceCarriesHDR10Plus }
        guard let data = packet.pointee.data, packet.pointee.size > 2 else { return .noMetadata }
        let size = Int(packet.pointee.size)
        switch framing {
        case .annexB: break
        case .lengthPrefixed(let width): guard width == Self.lengthPrefixSize else { return .unsupportedFraming }
        }

        // In-band only: what AVPlayer receives is the bitstream, and packet side data never reaches it.
        if HDR10PlusMetadataScan.bytesCarryHDR10Plus(data, size: size, codecID: AV_CODEC_ID_HEVC, framing: framing) {
            standsDown = true
            return .sourceCarriesHDR10Plus
        }

        // One walk: the first slice's offset (where the SEI goes) and this access unit's RPU (which
        // follows the slices, so the insertion point is found before the metadata that fills it).
        var firstSliceOffset: Int?
        var level1: DolbyVisionHDR10PlusMapping.Level1?
        A53SEIParser.forEachNAL(data, size, framing) { nal, length in
            guard length >= 2 else { return }
            let type = (nal[0] >> 1) & 0x3F
            if type < 32, firstSliceOffset == nil {
                firstSliceOffset = Self.unitStart(of: nal, in: data, framing: framing)
            } else if type == Self.nalTypeRPU, level1 == nil {
                level1 = Self.level1(ofRPU: nal, length: length)
            }
        }
        if let level1 { currentLevel1 = level1 }
        guard let shot = currentLevel1, let insertAt = firstSliceOffset else { return .noMetadata }

        let seiNAL: [UInt8]
        if let cached = cachedNAL, cached.level1 == shot {
            seiNAL = cached.nal
        } else {
            let metadata = DolbyVisionHDR10PlusMapping.metadata(for: shot)
            seiNAL = DolbyVisionHDR10PlusMapping.hevcPrefixSEINAL(
                t35Payload: DolbyVisionHDR10PlusMapping.t35Payload(metadata))
            cachedNAL = (shot, seiNAL)
        }

        // Both framings take a 4-byte prefix: a length, or the 00 00 00 01 start code.
        var prefix = [UInt8](repeating: 0, count: Self.lengthPrefixSize)
        switch framing {
        case .annexB:
            prefix[3] = 1
        case .lengthPrefixed:
            let n = seiNAL.count
            prefix = [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
        }
        let added = prefix.count + seiNAL.count
        let total = size + added
        let pad = Int(AV_INPUT_BUFFER_PADDING_SIZE)
        guard let newRef = av_buffer_alloc(total + pad), let dst = newRef.pointee.data else {
            return .noMetadata
        }
        memcpy(dst, data, insertAt)
        prefix.withUnsafeBufferPointer { _ = memcpy(dst + insertAt, $0.baseAddress!, $0.count) }
        seiNAL.withUnsafeBufferPointer { _ = memcpy(dst + insertAt + prefix.count, $0.baseAddress!, $0.count) }
        memcpy(dst + insertAt + added, data + insertAt, size - insertAt)
        memset(dst + total, 0, pad)   // decoders read past size
        av_buffer_unref(&packet.pointee.buf)
        packet.pointee.buf = newRef
        packet.pointee.data = newRef.pointee.data
        packet.pointee.size = Int32(total)
        injectedCount += 1
        return .injected
    }

    /// Offset of the framing that introduces `nal`: its length prefix, or its start code (a 4-byte start
    /// code when the byte before the 3-byte one is the zero the NAL walk trimmed off the previous unit).
    private static func unitStart(
        of nal: UnsafePointer<UInt8>, in data: UnsafePointer<UInt8>, framing: VideoNALFraming
    ) -> Int {
        let nalOffset = nal - data
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
