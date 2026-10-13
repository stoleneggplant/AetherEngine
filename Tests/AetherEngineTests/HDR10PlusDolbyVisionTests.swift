import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
import Dovi
@testable import AetherEngine

/// `LoadOptions.convertsHDR10PlusToDolbyVision`: an HDR10+ source served as Dolby Vision Profile 8.1.
///
/// The L1 values are pinned to an independent reference model of dovi_tool's HDR10+ -> L1 conversion, which
/// was checked off-device against dovi_tool itself: on hdr10plus_tool's HDR10+ test stream, the stream this
/// model builds and the one `dovi_tool generate --hdr10plus-json` + `inject-rpu` builds carry the same L1 on
/// all 259 pictures, FFmpeg decodes it with Dolby Vision RPU side data on every frame, and dovi_tool reads it
/// as Profile 8.1. The RPUs themselves come from libdovi's generator, so the tests read them back with libdovi.
@Suite("HDR10+ -> Dolby Vision Profile 8.1")
struct HDR10PlusDolbyVisionTests {

    typealias Mapping = HDR10PlusDolbyVisionMapping

    // MARK: - L1 (dovi_tool's mapping)

    static let typical = Mapping.FrameStats(
        maxSCL: [10006, 10006, 10006], averageMaxRGB: 1561,
        distribution: [3, 10006, 57, 187, 741, 2216, 4455, 5949, 10006])
    /// The first scene of hdr10plus_tool's Samsung test stream; dovi_tool's own output for it is 0 / 3243 / 2097.
    static let samsung = Mapping.FrameStats(
        maxSCL: [17830, 16895, 14252], averageMaxRGB: 1037,
        distribution: [3, 14024, 43, 56, 219, 1036, 2714, 4668, 14445])

    @Test("HDR10+ maps onto L1 the way dovi_tool generates it")
    func level1() {
        #expect(Mapping.level1(Self.typical) == .init(minPQ: 0, maxPQ: 3079, avgPQ: 2266))
        #expect(Mapping.level1(Self.samsung) == .init(minPQ: 0, maxPQ: 3243, avgPQ: 2097))
        #expect(Mapping.level1(Self.samsung, peakSource: .maxSCL) == .init(minPQ: 0, maxPQ: 3337, avgPQ: 2097))
        let bright = Mapping.FrameStats(
            maxSCL: [40000, 40000, 40000], averageMaxRGB: 9779,
            distribution: [24, 39997, 20, 1500, 5788, 15455, 26485, 31944, 39997])
        #expect(Mapping.level1(bright) == .init(minPQ: 0, maxPQ: 3696, avgPQ: 3069))
    }

    @Test("L1 is clamped for CM v4.0 as the generator's fixup does")
    func clamp() {
        let dark = Mapping.FrameStats(maxSCL: [500, 500, 500], averageMaxRGB: 10,
                                      distribution: [0, 480, 100, 1, 2, 5, 20, 40, 480])
        #expect(Mapping.level1(dark) == .init(minPQ: 0, maxPQ: 2081, avgPQ: 1229))
        #expect(Mapping.clamped(.init(minPQ: 40, maxPQ: 5000, avgPQ: 4095))
                == .init(minPQ: 12, maxPQ: 4095, avgPQ: 4094))
        #expect(Mapping.level1(.init(maxSCL: [0, 0, 0], averageMaxRGB: 0, distribution: [])) == nil)
    }

    @Test("nits_to_pq_12_bit")
    func pq() {
        #expect(Mapping.pq12(1000) == 3079)
        #expect(Mapping.pq12(100) == 2081)
        #expect(Mapping.pq12(0) == 0)
        #expect(Mapping.pq12(10000) == 4095)
    }

    // MARK: - Static metadata, level, configuration

    @Test("Dolby Vision level from size and rate, FFmpeg's table")
    func dolbyVisionLevel() {
        #expect(Mapping.dolbyVisionLevel(width: 3840, height: 2160, framesPerSecond: 23.976) == 6)
        #expect(Mapping.dolbyVisionLevel(width: 3840, height: 2160, framesPerSecond: 24) == 6)
        #expect(Mapping.dolbyVisionLevel(width: 3840, height: 2160, framesPerSecond: 30) == 7)
        #expect(Mapping.dolbyVisionLevel(width: 3840, height: 2160, framesPerSecond: 60) == 9)
        #expect(Mapping.dolbyVisionLevel(width: 1920, height: 1080, framesPerSecond: 24) == 3)
        #expect(Mapping.dolbyVisionLevel(width: 1920, height: 1080, framesPerSecond: 60) == 5)
        #expect(Mapping.dolbyVisionLevel(width: 3840, height: 2160, framesPerSecond: nil) == 6)
    }

    @Test("mastering primaries name a Level 9 index only when they are a predefined set")
    func primaryIndex() {
        #expect(Mapping.primaryIndex([0.68, 0.32, 0.265, 0.69, 0.15, 0.06, 0.3127, 0.329]) == 0)
        #expect(Mapping.primaryIndex([0.708, 0.292, 0.17, 0.797, 0.131, 0.046, 0.3127, 0.329]) == 2)
        #expect(Mapping.primaryIndex([0.7, 0.3, 0.2, 0.7, 0.15, 0.05, 0.31, 0.33]) == nil)
        #expect(Mapping.primaryIndex([]) == nil)
    }

    @Test("the generator configuration is one two-picture shot with L1, L6 and an optional L9")
    func configuration() throws {
        let json = Mapping.generateConfigJSON(
            level1: .init(minPQ: 0, maxPQ: 3079, avgPQ: 2266),
            level6: .init(maxMasteringLuminance: 1000, minMasteringLuminance: 1, maxCLL: 1000, maxFALL: 400),
            primaryIndex: 2)
        let root = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(root["profile"] as? String == "8.1")
        #expect(root["cm_version"] as? String == "V40")
        #expect(root["length"] as? Int == 2)
        let shots = try #require(root["shots"] as? [[String: Any]])
        #expect(shots.count == 1)
        #expect(shots[0]["duration"] as? Int == 2)
        let l6 = try #require(root["level6"] as? [String: Int])
        #expect(l6["max_content_light_level"] == 1000)
        #expect(l6["max_frame_average_light_level"] == 400)
        let defaults = try #require(root["default_metadata_blocks"] as? [[String: Any]])
        #expect((defaults.first?["Level9"] as? [String: Int])?["source_primary_index"] == 2)
    }

    // MARK: - libdovi generation

    private static func readBack(_ nal: [UInt8]) -> (level1: Mapping.Level1?, sceneRefresh: UInt64, profile: Int?) {
        nal.withUnsafeBufferPointer { buffer in
            guard let rpu = dovi_parse_unspec62_nalu(buffer.baseAddress, buffer.count) else { return (nil, 0, nil) }
            defer { dovi_rpu_free(rpu) }
            var profile: Int?
            if let header = dovi_rpu_get_header(rpu) {
                profile = Int(header.pointee.guessed_profile)
                dovi_rpu_free_header(header)
            }
            guard let dm = dovi_rpu_get_vdr_dm_data(rpu) else { return (nil, 0, profile) }
            defer { dovi_rpu_free_vdr_dm_data(dm) }
            let l1 = dm.pointee.dm_data.level1.map {
                Mapping.Level1(minPQ: Int($0.pointee.min_pq), maxPQ: Int($0.pointee.max_pq), avgPQ: Int($0.pointee.avg_pq))
            }
            return (l1, dm.pointee.scene_refresh_flag, profile)
        }
    }

    @Test("libdovi generates the shot's scene-cut and continuation RPUs, Profile 8.1, with the L1 asked for")
    func generatesPair() throws {
        let generator = DolbyVisionRPUGenerator(
            level6: .init(maxMasteringLuminance: 1000, minMasteringLuminance: 1, maxCLL: 1000, maxFALL: 400),
            primaryIndex: 2)
        let l1 = Mapping.Level1(minPQ: 0, maxPQ: 3243, avgPQ: 2097)
        let cut = try #require(generator.rpuNAL(for: l1, opensShot: true), "\(generator.lastError ?? "")")
        let next = try #require(generator.rpuNAL(for: l1, opensShot: false))
        #expect(cut[0] == 0x7C && cut[1] == 0x01)          // unspec62 NAL header
        let a = Self.readBack(cut), b = Self.readBack(next)
        #expect(a.level1 == l1 && b.level1 == l1)
        #expect(a.sceneRefresh == 1 && b.sceneRefresh == 0)
        #expect(a.profile == 8)
        _ = generator.rpuNAL(for: l1, opensShot: true)
        #expect(generator.generatedCount == 1)             // one libdovi call per shot
    }

    // MARK: - Packet rewrite

    private static let slice: [UInt8] = [0x02, 0x01, 0x80, 0xAA, 0xBB]

    /// An HEVC prefix SEI carrying one ST 2094-40 message for `stats`, emulation prevention applied.
    private static func hdr10PlusSEI(_ stats: Mapping.FrameStats) -> [UInt8] {
        var bits: [UInt8] = []
        func put(_ v: UInt32, _ n: Int) { for i in stride(from: n - 1, through: 0, by: -1) { bits.append(UInt8((v >> UInt32(i)) & 1)) } }
        put(0xB5, 8); put(0x003C, 16); put(0x0001, 16); put(4, 8); put(1, 8)
        put(1, 2); put(0, 27); put(0, 1)
        for v in stats.maxSCL { put(v, 17) }
        put(stats.averageMaxRGB, 17)
        let percentages: [UInt32] = [1, 5, 10, 25, 50, 75, 90, 95, 99]
        put(UInt32(stats.distribution.count), 4)
        for (p, v) in zip(percentages, stats.distribution) { put(p, 7); put(v, 17) }
        put(0, 10); put(0, 1); put(0, 1); put(0, 1)
        while bits.count % 8 != 0 { bits.append(0) }
        var payload: [UInt8] = []
        for i in stride(from: 0, to: bits.count, by: 8) {
            payload.append(bits[i..<(i + 8)].reduce(0) { ($0 << 1) | $1 })
        }
        let rbsp: [UInt8] = [4, UInt8(payload.count)] + payload + [0x80]
        var nal: [UInt8] = [39 << 1, 0x01]
        var zeros = 0
        for byte in rbsp {
            if zeros >= 2, byte <= 3 { nal.append(3); zeros = 0 }
            nal.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return nal
    }

    @Test("the picture's HDR10+ is read back as the stats it was written from")
    func readsFrameStats() {
        let packet = Self.avccPacket([Self.hdr10PlusSEI(Self.samsung), Self.slice])
        defer { Self.free(packet) }
        #expect(HDR10PlusMetadataScan.frameStats(packet, codecID: AV_CODEC_ID_HEVC, framing: .lengthPrefixed(size: 4))
                == Self.samsung)
    }

    @Test("each picture gets one RPU as its last NAL; the shot's first is the scene cut; HDR10+ stays")
    func injects() throws {
        let generator = DolbyVisionRPUGenerator(level6: .generatorDefault, primaryIndex: nil)
        let injector = HDR10PlusDolbyVisionInjector(generator: generator)
        let sei = Self.hdr10PlusSEI(Self.samsung)

        let first = Self.avccPacket([sei, Self.slice], pts: 0)
        defer { Self.free(first) }
        #expect(injector.process(first, framing: .lengthPrefixed(size: 4)) == .injected(opensShot: true))
        let nals = Self.nals(first)
        #expect(nals.count == 3 && nals[0] == sei && nals[1] == Self.slice)
        #expect((nals[2][0] >> 1) & 0x3F == 62)
        let rpu = Self.readBack(nals[2])
        #expect(rpu.level1 == .init(minPQ: 0, maxPQ: 3243, avgPQ: 2097))
        #expect(rpu.sceneRefresh == 1)

        // The next picture in the same shot, and one without HDR10+ of its own, continue it.
        let second = Self.avccPacket([sei, Self.slice], pts: 1)
        defer { Self.free(second) }
        #expect(injector.process(second, framing: .lengthPrefixed(size: 4)) == .injected(opensShot: false))
        let bare = Self.avccPacket([Self.slice], pts: 2)
        defer { Self.free(bare) }
        #expect(injector.process(bare, framing: .lengthPrefixed(size: 4)) == .injected(opensShot: false))
        #expect(Self.readBack(Self.nals(bare).last!).level1 == .init(minPQ: 0, maxPQ: 3243, avgPQ: 2097))

        // A new shot.
        let next = Self.avccPacket([Self.hdr10PlusSEI(Self.typical), Self.slice], pts: 3)
        defer { Self.free(next) }
        #expect(injector.process(next, framing: .lengthPrefixed(size: 4)) == .injected(opensShot: true))
        #expect(Self.readBack(Self.nals(next).last!).level1 == .init(minPQ: 0, maxPQ: 3079, avgPQ: 2266))
    }

    @Test("before any HDR10+ the shot is the base layer's static metadata")
    func staticFallback() {
        let level6 = Mapping.Level6(maxMasteringLuminance: 4000, minMasteringLuminance: 50, maxCLL: 1000, maxFALL: 400)
        #expect(HDR10PlusDolbyVisionInjector.staticLevel1(level6)
                == Mapping.clamped(.init(minPQ: 0, maxPQ: Mapping.pq12(1000), avgPQ: Mapping.pq12(400))))
        let noCLL = Mapping.Level6(maxMasteringLuminance: 4000, minMasteringLuminance: 50, maxCLL: 0, maxFALL: 0)
        #expect(HDR10PlusDolbyVisionInjector.staticLevel1(noCLL).maxPQ == Mapping.pq12(4000))
    }

    @Test("a packet that already carries an RPU, or a framing this rewrite does not emit, is left alone")
    func leavesAlone() {
        let injector = HDR10PlusDolbyVisionInjector(generator: DolbyVisionRPUGenerator(level6: .generatorDefault, primaryIndex: nil))
        let withRPU = Self.avccPacket([Self.slice, [62 << 1, 0x01, 0x19, 0x08]])
        defer { Self.free(withRPU) }
        #expect(injector.process(withRPU, framing: .lengthPrefixed(size: 4)) == .alreadyDolbyVision)
        let short = Self.packet([0, UInt8(Self.slice.count)] + Self.slice)
        defer { Self.free(short) }
        #expect(injector.process(short, framing: .lengthPrefixed(size: 2)) == .unsupportedFraming)
    }

    @Test("scene cuts follow presentation order, never missing one")
    func sceneCuts() {
        // Decode order of an IBBP stream across a cut at presentation 3: scene A is 0...2, B is 3...5.
        let a = Mapping.Level1(minPQ: 0, maxPQ: 3079, avgPQ: 2000)
        let b = Mapping.Level1(minPQ: 0, maxPQ: 3243, avgPQ: 2097)
        let decodeOrder: [(Int64, Mapping.Level1)] = [(0, a), (3, b), (1, a), (2, a), (5, b), (4, b)]
        var tracker = Mapping.SceneCutTracker()
        let cuts = decodeOrder.filter { tracker.opensShot(pts: $0.0, level1: $0.1) }.map(\.0)
        #expect(cuts.contains(0) && cuts.contains(3))           // every cut
        #expect(!cuts.contains(1) && !cuts.contains(2) && !cuts.contains(4))
        var noPTS = Mapping.SceneCutTracker()
        #expect(noPTS.opensShot(pts: nil, level1: a))
        #expect(!noPTS.opensShot(pts: nil, level1: a))
        #expect(noPTS.opensShot(pts: nil, level1: b))
    }

    // MARK: - Routing

    @Test("only an HEVC PQ source without a Dolby Vision record, on a DV display, native and audited, converts")
    func policy() {
        #expect(HDR10PlusDolbyVisionPolicy.sourceIsEligible(
            codecID: AV_CODEC_ID_HEVC, hasDolbyVisionRecord: false, colorTransfer: AVCOL_TRC_SMPTE2084))
        #expect(!HDR10PlusDolbyVisionPolicy.sourceIsEligible(
            codecID: AV_CODEC_ID_HEVC, hasDolbyVisionRecord: true, colorTransfer: AVCOL_TRC_SMPTE2084))
        #expect(!HDR10PlusDolbyVisionPolicy.sourceIsEligible(
            codecID: AV_CODEC_ID_HEVC, hasDolbyVisionRecord: false, colorTransfer: AVCOL_TRC_ARIB_STD_B67))
        #expect(!HDR10PlusDolbyVisionPolicy.sourceIsEligible(
            codecID: AV_CODEC_ID_AV1, hasDolbyVisionRecord: false, colorTransfer: AVCOL_TRC_SMPTE2084))
        func audits(_ edit: (inout (Bool, Bool, Bool, Bool, Bool, Bool)) -> Void = { _ in }) -> Bool {
            var v = (true, true, true, false, true, false)
            edit(&v)
            return HDR10PlusDolbyVisionPolicy.worthAuditing(
                requested: v.0, displayPresentsDolbyVision: v.1, sourceEligible: v.2,
                isLive: v.3, isURLSource: v.4, prefersSoftware: v.5)
        }
        #expect(audits())
        #expect(!audits { $0.0 = false })
        #expect(!audits { $0.1 = false })
        #expect(!audits { $0.2 = false })
        #expect(!audits { $0.3 = true })
        #expect(!audits { $0.4 = false })
        #expect(!audits { $0.5 = true })
    }

    @Test("a load identity field: a rebuild cannot ask the display again")
    func identityField() {
        var proposed = LoadOptions()
        proposed.convertsHDR10PlusToDolbyVision = true
        #expect(SessionOptionCorrection.refusedFields(from: LoadOptions(), to: proposed)
                == ["convertsHDR10PlusToDolbyVision"])
        #expect(SessionOptionCorrection.loadIdentityFields.contains("convertsHDR10PlusToDolbyVision"))
    }

    // MARK: - Helpers

    private static func packet(_ bytes: [UInt8]) -> UnsafeMutablePointer<AVPacket> {
        let pkt = av_packet_alloc()!
        _ = av_new_packet(pkt, Int32(bytes.count))
        bytes.withUnsafeBytes { _ = memcpy(pkt.pointee.data, $0.baseAddress, bytes.count) }
        return pkt
    }

    private static func avccPacket(_ nals: [[UInt8]], pts: Int64 = 0) -> UnsafeMutablePointer<AVPacket> {
        var bytes: [UInt8] = []
        for nal in nals {
            let n = nal.count
            bytes += [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
            bytes += nal
        }
        let pkt = packet(bytes)
        pkt.pointee.pts = pts
        return pkt
    }

    private static func nals(_ pkt: UnsafeMutablePointer<AVPacket>) -> [[UInt8]] {
        guard let data = pkt.pointee.data else { return [] }
        let size = Int(pkt.pointee.size)
        var out: [[UInt8]] = []
        var offset = 0
        while offset + 4 <= size {
            var length = 0
            for i in 0..<4 { length = (length << 8) | Int(data[offset + i]) }
            let start = offset + 4
            guard length > 0, start + length <= size else { break }
            out.append(Array(UnsafeBufferPointer(start: data + start, count: length)))
            offset = start + length
        }
        return out
    }

    private static func free(_ pkt: UnsafeMutablePointer<AVPacket>) {
        var p: UnsafeMutablePointer<AVPacket>? = pkt
        av_packet_free(&p)
    }
}
