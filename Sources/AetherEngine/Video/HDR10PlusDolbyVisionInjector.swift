import Foundation
import AetherLibavcodec
import AetherLibavutil
import Dovi

/// Generates Profile 8.1 RPUs with libdovi's own generator (`dovi_generate_from_json`, the `GenerateConfig`
/// behind `dovi_tool generate`), two per shot: the scene-cut RPU a shot opens with and the RPU of every
/// picture after it. HDR10+ is per scene, so a title needs a handful of these, and each pair is generated
/// once and kept.
final class DolbyVisionRPUGenerator {

    struct Pair {
        let sceneCut: [UInt8]
        let continuation: [UInt8]
    }

    let level6: HDR10PlusDolbyVisionMapping.Level6
    let primaryIndex: Int?
    private var cache: [HDR10PlusDolbyVisionMapping.Level1: Pair] = [:]
    /// Enough for the shots of a long title; a source that varies per picture (no scenes at all) is bounded.
    private let cacheLimit = 512
    private(set) var generatedCount = 0
    private(set) var lastError: String?

    init(level6: HDR10PlusDolbyVisionMapping.Level6, primaryIndex: Int?) {
        self.level6 = level6
        self.primaryIndex = primaryIndex
    }

    /// The complete unspec62 NAL (header included, emulation prevention applied) for a picture with this
    /// L1, or nil when libdovi refused the configuration.
    func rpuNAL(for level1: HDR10PlusDolbyVisionMapping.Level1, opensShot: Bool) -> [UInt8]? {
        let pair: Pair
        if let cached = cache[level1] {
            pair = cached
        } else {
            let json = HDR10PlusDolbyVisionMapping.generateConfigJSON(
                level1: level1, level6: level6, primaryIndex: primaryIndex)
            guard let generated = Self.generatePair(json: json, error: &lastError) else { return nil }
            if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
            cache[level1] = generated
            generatedCount += 1
            pair = generated
        }
        return opensShot ? pair.sceneCut : pair.continuation
    }

    static func generatePair(json: String, error: inout String?) -> Pair? {
        guard let list = json.withCString({ dovi_generate_from_json($0) }) else {
            error = "dovi_generate_from_json returned nothing"
            return nil
        }
        defer { dovi_rpu_list_free(list) }
        if let message = list.pointee.error {
            error = String(cString: message)
            return nil
        }
        guard list.pointee.len == 2, let entries = list.pointee.list else {
            error = "dovi_generate_from_json generated \(list.pointee.len) RPUs, expected 2"
            return nil
        }
        var nals: [[UInt8]] = []
        for index in 0..<2 {
            guard let rpu = entries[index], let written = dovi_write_unspec62_nalu(rpu) else {
                error = "dovi_write_unspec62_nalu failed"
                return nil
            }
            defer { dovi_data_free(written) }
            guard let bytes = written.pointee.data, written.pointee.len > 2 else {
                error = "dovi_write_unspec62_nalu wrote nothing"
                return nil
            }
            nals.append(Array(UnsafeBufferPointer(start: bytes, count: written.pointee.len)))
        }
        return Pair(sceneCut: nals[0], continuation: nals[1])
    }
}

/// Per-session packet rewrite for `LoadOptions.convertsHDR10PlusToDolbyVision`: each HEVC access unit gets
/// one Profile 8.1 RPU, derived from the access unit's own HDR10+ and appended as its last NAL unit, which is
/// where a Dolby Vision RPU lives. Everything else in the packet, the HDR10+ SEI included, passes through
/// byte for byte.
///
/// A picture without HDR10+ of its own keeps its shot's metadata. Before the first HDR10+ picture the shot
/// is the base layer's static metadata (MaxCLL / MaxFALL, or the mastering peak), so no picture of a
/// session that serves Dolby Vision goes out without an RPU.
///
/// Not thread-safe: one instance belongs to one producer read loop (or one I-frame read).
final class HDR10PlusDolbyVisionInjector {

    enum Outcome: Equatable {
        /// An RPU was appended; `opensShot` when it is the scene-cut one.
        case injected(opensShot: Bool)
        /// The packet already carries an RPU (unspec62); left as it is.
        case alreadyDolbyVision
        /// libdovi produced no RPU, or the packet holds no picture.
        case noRPU
        /// A framing this rewrite does not emit (a 1/2/3-byte length prefix).
        case unsupportedFraming
    }

    private static let nalTypeRPU: UInt8 = 62
    private static let lengthPrefixSize = 4

    private let generator: DolbyVisionRPUGenerator
    private let peakSource: HDR10PlusDolbyVisionMapping.PeakSource
    private var currentLevel1: HDR10PlusDolbyVisionMapping.Level1
    private var tracker = HDR10PlusDolbyVisionMapping.SceneCutTracker()
    private(set) var injectedCount = 0
    private(set) var framesFromHDR10Plus = 0

    init(generator: DolbyVisionRPUGenerator, peakSource: HDR10PlusDolbyVisionMapping.PeakSource = .histogram) {
        self.generator = generator
        self.peakSource = peakSource
        self.currentLevel1 = Self.staticLevel1(generator.level6)
    }

    /// The L1 a picture gets before any HDR10+: the base layer's own static statement of its peak and
    /// average, through the same encoding and clamp.
    static func staticLevel1(_ level6: HDR10PlusDolbyVisionMapping.Level6) -> HDR10PlusDolbyVisionMapping.Level1 {
        let peak = level6.maxCLL > 0 ? level6.maxCLL : level6.maxMasteringLuminance
        return HDR10PlusDolbyVisionMapping.clamped(.init(
            minPQ: 0,
            maxPQ: HDR10PlusDolbyVisionMapping.pq12(Double(peak)),
            avgPQ: HDR10PlusDolbyVisionMapping.pq12(Double(max(level6.maxFALL, 0)))))
    }

    func process(_ packet: UnsafeMutablePointer<AVPacket>, framing: VideoNALFraming) -> Outcome {
        guard let data = packet.pointee.data, packet.pointee.size > 2 else { return .noRPU }
        let size = Int(packet.pointee.size)
        switch framing {
        case .annexB: break
        case .lengthPrefixed(let width): guard width == Self.lengthPrefixSize else { return .unsupportedFraming }
        }
        let base = UnsafePointer(data)

        var hasPicture = false
        var hasRPU = false
        A53SEIParser.forEachNAL(base, size, framing) { nal, length in
            guard length >= 2 else { return }
            let type = (nal[0] >> 1) & 0x3F
            if type < 32 { hasPicture = true }
            if type == Self.nalTypeRPU { hasRPU = true }
        }
        guard !hasRPU else { return .alreadyDolbyVision }
        guard hasPicture else { return .noRPU }

        if let stats = HDR10PlusMetadataScan.frameStats(packet, codecID: AV_CODEC_ID_HEVC, framing: framing),
           let level1 = HDR10PlusDolbyVisionMapping.level1(stats, peakSource: peakSource) {
            currentLevel1 = level1
            framesFromHDR10Plus += 1
        }
        let pts = packet.pointee.pts == Int64.min ? nil : packet.pointee.pts
        let opensShot = tracker.opensShot(pts: pts, level1: currentLevel1)
        guard let rpu = generator.rpuNAL(for: currentLevel1, opensShot: opensShot) else { return .noRPU }

        let prefix: [UInt8]
        switch framing {
        case .annexB:
            prefix = [0, 0, 0, 1]
        case .lengthPrefixed:
            let n = rpu.count
            prefix = [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
        }
        let total = size + prefix.count + rpu.count
        let pad = Int(AV_INPUT_BUFFER_PADDING_SIZE)
        guard let newRef = av_buffer_alloc(total + pad), let dst = newRef.pointee.data else { return .noRPU }
        memcpy(dst, base, size)
        prefix.withUnsafeBufferPointer { _ = memcpy(dst + size, $0.baseAddress!, $0.count) }
        rpu.withUnsafeBufferPointer { _ = memcpy(dst + size + prefix.count, $0.baseAddress!, $0.count) }
        memset(dst + total, 0, pad)   // decoders read past size
        av_buffer_unref(&packet.pointee.buf)
        packet.pointee.buf = newRef
        packet.pointee.data = newRef.pointee.data
        packet.pointee.size = Int32(total)
        injectedCount += 1
        return .injected(opensShot: opensShot)
    }
}

/// Whether a session converts HDR10+ to Dolby Vision, decided at load, before the display is asked for a mode.
enum HDR10PlusDolbyVisionPolicy {

    /// The source half: HEVC with a PQ transfer and no Dolby Vision record of its own. Whether it carries
    /// HDR10+ is the audit's question (`sourceCarriesHDR10Plus`).
    static func sourceIsEligible(codecID: AVCodecID, hasDolbyVisionRecord: Bool,
                                 colorTransfer: AVColorTransferCharacteristic) -> Bool {
        codecID == AV_CODEC_ID_HEVC && !hasDolbyVisionRecord && colorTransfer == AVCOL_TRC_SMPTE2084
    }

    /// Everything but the audit: the host asked, the display presents Dolby Vision, the source is eligible,
    /// and the session is one the native path serves (the conversion lives in its segment producer): VOD,
    /// a `.url` source with a second open to give, no software preference.
    static func worthAuditing(requested: Bool, displayPresentsDolbyVision: Bool, sourceEligible: Bool,
                              isLive: Bool, isURLSource: Bool, prefersSoftware: Bool) -> Bool {
        requested && displayPresentsDolbyVision && sourceEligible && !isLive && isURLSource && !prefersSoftware
    }

    /// A second, bounded open of the source and the probe's own HDR10+ scan over its first video packets
    /// (`HDR10PlusDetectionOptions` defaults: 32 packets, 16 MiB, 2 s).
    static func sourceCarriesHDR10Plus(url: URL, extraHeaders: [String: String]) -> Bool {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        do {
            try demuxer.open(
                url: url, extraHeaders: extraHeaders,
                profile: .dolbyVisionRecordAuditDemuxer(callerProbesize: nil, callerMaxAnalyzeDuration: nil))
        } catch {
            return false
        }
        return AetherEngine.detectHDR10Plus(
            demuxer: demuxer, videoIndex: demuxer.videoStreamIndex,
            options: HDR10PlusDetectionOptions()).carriesHDR10Plus
    }
}
