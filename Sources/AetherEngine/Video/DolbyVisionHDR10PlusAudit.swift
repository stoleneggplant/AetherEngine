import Foundation
import AetherLibavcodec
import AetherLibavutil
import Dovi

/// What a session converting Dolby Vision to HDR10+ (`LoadOptions.convertsDolbyVisionToHDR10Plus`) needs to
/// know about its source before the first segment is cut, read from the source's first video packets:
///
/// - whether the source carries HDR10+ of its own, and where. A graded HDR10+ track is better than one
///   derived from L1, so a source that has one is served it from the first picture on, instead of
///   synthesizing until the first native message turns up.
/// - the RPU's static HDR10 metadata (Level 6, with Level 9's mastering primaries), the fallback for a base
///   layer whose container carries no `mdcv` / `clli` of its own, which an HDR10+ TV reads beside the
///   dynamic metadata.
///
/// Read from a second open, bounded like the AE#532 record audit (`DolbyVisionRecordAudit`), and paid only by
/// a session that converts. A custom reader has no second open to give: that session decides HDR10+ per
/// packet instead (`DolbyVisionHDR10PlusSynthesizer` stands down on the first native message) and has no
/// static fallback.
public enum DolbyVisionHDR10PlusAudit {

    public struct Result: Equatable, Sendable {
        /// Where the source's own HDR10+ lives, if anywhere in the packets walked.
        public enum NativeHDR10Plus: Equatable, Sendable {
            case absent
            /// ST 2094-40 SEI in the bitstream: AVPlayer receives it as it is.
            case inBand
            /// Only as packet side data (a Matroska BlockAddition), which never reaches AVPlayer; the
            /// synthesizer re-serializes it into the bitstream.
            case sideDataOnly
        }

        public var nativeHDR10Plus: NativeHDR10Plus
        public var staticMetadata: StaticMetadata?
    }

    /// HDR10 static metadata as a Dolby Vision RPU states it. Luminance in cd/m2; primaries as CIE 1931 xy,
    /// red, green, blue, white.
    public struct StaticMetadata: Equatable, Sendable {
        public var maxMasteringLuminance: Double
        public var minMasteringLuminance: Double
        public var maxCLL: Int
        public var maxFALL: Int
        public var primaries: [Double]
    }

    /// Video packets to walk. HDR10+ and the RPU are both per frame, so the first video packet answers
    /// both; the slack is for a container whose head is audio, as in the record audit.
    static let packetBudget = 16

    /// Open `url` a second time and read its first video packets. Public for `aetherctl`, which builds
    /// `HLSVideoEngine` directly and so has no load to run it.
    public static func inspect(url: URL, extraHeaders: [String: String] = [:]) -> Result? {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        do {
            try demuxer.open(
                url: url, extraHeaders: extraHeaders,
                profile: .dolbyVisionRecordAuditDemuxer(callerProbesize: nil, callerMaxAnalyzeDuration: nil))
        } catch {
            return nil
        }
        return inspect(walking: demuxer)
    }

    /// The walk over an opened demuxer. nil when no video packet was read at all.
    static func inspect(
        walking demuxer: Demuxer, packetBudget: Int = packetBudget,
        byteBudget: Int64 = Int64(DolbyVisionRecordAudit.walkByteBudget)
    ) -> Result? {
        let videoIdx = demuxer.videoStreamIndex
        guard videoIdx >= 0, let stream = demuxer.stream(at: videoIdx) else { return nil }
        let codecpar = stream.pointee.codecpar
        let framing = A53SEIParser.nalFraming(
            codec: .hevc, extradata: codecpar?.pointee.extradata,
            size: Int(codecpar?.pointee.extradata_size ?? 0))

        demuxer.beginInputByteBudget(byteBudget)
        defer { demuxer.endInputByteBudget() }

        var native = Result.NativeHDR10Plus.absent
        var staticMetadata: StaticMetadata?
        var sawRPU = false
        var walked = 0
        var packetsRead = 0
        var bytesRead = 0
        while walked < packetBudget {
            guard !DolbyVisionRecordAudit.walkExhausted(
                packetsRead: packetsRead, bytesRead: bytesRead, packetBudget: packetBudget) else { break }
            guard let packet = (try? demuxer.readPacket()) ?? nil else { break }
            defer {
                av_packet_unref(packet)
                av_packet_free_safe(packet)
            }
            packetsRead += 1
            bytesRead += Int(max(packet.pointee.size, 0))
            guard packet.pointee.stream_index == videoIdx else { continue }
            walked += 1

            if native != .inBand {
                if HDR10PlusMetadataScan.bytesCarryHDR10Plus(
                    packet.pointee.data, size: Int(packet.pointee.size),
                    codecID: AV_CODEC_ID_HEVC, framing: framing) {
                    native = .inBand
                } else if native == .absent, HDR10PlusMetadataScan.sideDataT35Payload(packet) != nil {
                    native = .sideDataOnly
                }
            }
            if !sawRPU, let data = packet.pointee.data {
                A53SEIParser.forEachNAL(data, Int(packet.pointee.size), framing) { nal, length in
                    guard !sawRPU, length > 2, (nal[0] >> 1) & 0x3F == 62 else { return }
                    sawRPU = true
                    staticMetadata = Self.staticMetadata(ofRPU: nal, length: length)
                }
            }
            // A frame that carries an RPU and was checked for HDR10+ answers both questions.
            if sawRPU { break }
        }
        guard walked > 0 else { return nil }
        return Result(nativeHDR10Plus: native, staticMetadata: staticMetadata)
    }

    /// L6 (and L9) from one unspec62 NAL. nil when the RPU does not parse or states no usable L6: a zero
    /// MaxCLL / mastering peak is the RPU saying "unknown", not a value to write.
    static func staticMetadata(ofRPU nal: UnsafePointer<UInt8>, length: Int) -> StaticMetadata? {
        guard let rpu = dovi_parse_unspec62_nalu(nal, length) else { return nil }
        defer { dovi_rpu_free(rpu) }
        guard dovi_rpu_get_error(rpu) == nil, let dm = dovi_rpu_get_vdr_dm_data(rpu) else { return nil }
        defer { dovi_rpu_free_vdr_dm_data(dm) }
        guard let l6 = dm.pointee.dm_data.level6, l6.pointee.max_display_mastering_luminance > 0 else {
            return nil
        }
        var primaries = predefinedPrimaries[0]
        if let l9 = dm.pointee.dm_data.level9 {
            primaries = Self.primaries(l9.pointee)
        }
        return StaticMetadata(
            maxMasteringLuminance: Double(l6.pointee.max_display_mastering_luminance),
            // L6 states the mastering minimum in 0.0001 cd/m2, as ST 2086 does.
            minMasteringLuminance: Double(l6.pointee.min_display_mastering_luminance) / 10000,
            maxCLL: Int(l6.pointee.max_content_light_level),
            maxFALL: Int(l6.pointee.max_frame_average_light_level),
            primaries: primaries)
    }

    /// Level 9's mastering primaries: an index into Dolby's predefined table, or 255 with explicit
    /// coordinates in units of 1/32767 (dovi_tool's `primaries.rs`). An RPU without L9 was mastered on the
    /// default, DCI-P3 D65, which is also what dovi_tool writes when it generates one.
    static func primaries(_ l9: DoviExtMetadataBlockLevel9) -> [Double] {
        if l9.source_primary_index == 255, l9.length > 1 {
            let raw = [l9.source_primary_red_x, l9.source_primary_red_y,
                       l9.source_primary_green_x, l9.source_primary_green_y,
                       l9.source_primary_blue_x, l9.source_primary_blue_y,
                       l9.source_primary_white_x, l9.source_primary_white_y]
            return raw.map { Double($0) / 32767 }
        }
        let index = Int(l9.source_primary_index)
        return index < predefinedPrimaries.count ? predefinedPrimaries[index] : predefinedPrimaries[0]
    }

    /// The first six entries of Dolby's predefined mastering primaries (dovi_tool `primaries.rs`); the
    /// remaining ones (ACES, S-Gamut) have coordinates ST 2086 cannot carry.
    static let predefinedPrimaries: [[Double]] = [
        [0.68, 0.32, 0.265, 0.69, 0.15, 0.06, 0.3127, 0.329],       // 0: DCI-P3 D65
        [0.64, 0.33, 0.30, 0.60, 0.15, 0.06, 0.3127, 0.329],        // 1: BT.709
        [0.708, 0.292, 0.170, 0.797, 0.131, 0.046, 0.3127, 0.329],  // 2: BT.2020
        [0.63, 0.34, 0.31, 0.595, 0.155, 0.07, 0.3127, 0.329],      // 3: SMPTE-C
        [0.64, 0.33, 0.29, 0.60, 0.15, 0.06, 0.3127, 0.329],        // 4: BT.601 PAL
        [0.68, 0.32, 0.265, 0.69, 0.15, 0.06, 0.314, 0.351],        // 5: DCI-P3
    ]

    // MARK: - Applying the static fallback

    /// Attach `metadata` to `codecpar` as the mastering-display and content-light side data the mp4 muxer
    /// writes as `mdcv` / `clli`, each only where the source has none of its own: a container that states
    /// its HDR10 static metadata is trusted over the RPU. Returns which of the two were added.
    @discardableResult
    static func attachStaticMetadata(
        _ metadata: StaticMetadata, to codecpar: UnsafeMutablePointer<AVCodecParameters>
    ) -> (masteringDisplay: Bool, contentLight: Bool) {
        var added = (masteringDisplay: false, contentLight: false)
        if sideData(codecpar, AV_PKT_DATA_MASTERING_DISPLAY_METADATA) == nil, metadata.primaries.count == 8 {
            let size = MemoryLayout<AVMasteringDisplayMetadata>.size
            if let item = av_packet_side_data_new(
                &codecpar.pointee.coded_side_data, &codecpar.pointee.nb_coded_side_data,
                AV_PKT_DATA_MASTERING_DISPLAY_METADATA, size, 0) {
                memset(item.pointee.data, 0, size)
                item.pointee.data.withMemoryRebound(to: AVMasteringDisplayMetadata.self, capacity: 1) { m in
                    let p = metadata.primaries
                    let chroma = { (v: Double) in AVRational(num: Int32((v * 50000).rounded()), den: 50000) }
                    m.pointee.display_primaries.0 = (chroma(p[0]), chroma(p[1]))   // red
                    m.pointee.display_primaries.1 = (chroma(p[2]), chroma(p[3]))   // green
                    m.pointee.display_primaries.2 = (chroma(p[4]), chroma(p[5]))   // blue
                    m.pointee.white_point = (chroma(p[6]), chroma(p[7]))
                    m.pointee.max_luminance = AVRational(
                        num: Int32((metadata.maxMasteringLuminance * 10000).rounded()), den: 10000)
                    m.pointee.min_luminance = AVRational(
                        num: Int32((metadata.minMasteringLuminance * 10000).rounded()), den: 10000)
                    m.pointee.has_primaries = 1
                    m.pointee.has_luminance = 1
                }
                added.masteringDisplay = true
            }
        }
        if sideData(codecpar, AV_PKT_DATA_CONTENT_LIGHT_LEVEL) == nil, metadata.maxCLL > 0 {
            let size = MemoryLayout<AVContentLightMetadata>.size
            if let item = av_packet_side_data_new(
                &codecpar.pointee.coded_side_data, &codecpar.pointee.nb_coded_side_data,
                AV_PKT_DATA_CONTENT_LIGHT_LEVEL, size, 0) {
                memset(item.pointee.data, 0, size)
                item.pointee.data.withMemoryRebound(to: AVContentLightMetadata.self, capacity: 1) { c in
                    c.pointee.MaxCLL = UInt32(metadata.maxCLL)
                    c.pointee.MaxFALL = UInt32(max(metadata.maxFALL, 0))
                }
                added.contentLight = true
            }
        }
        return added
    }

    private static func sideData(
        _ codecpar: UnsafeMutablePointer<AVCodecParameters>, _ type: AVPacketSideDataType
    ) -> UnsafePointer<AVPacketSideData>? {
        av_packet_side_data_get(codecpar.pointee.coded_side_data, codecpar.pointee.nb_coded_side_data, type)
    }
}
