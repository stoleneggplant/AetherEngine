import Foundation

/// The enhancement layer a single-track Dolby Vision Profile 7 access unit carries, pulled out of it.
///
/// A UHD Blu-ray remux keeps both layers in one HEVC track: the base layer's NAL units as they are, the
/// RPU as an `unspec62` NAL, and every NAL unit of the enhancement layer (its own VPS / SPS / PPS, SEI and
/// slices) wrapped in an `unspec63` NAL whose two-byte header is followed by the enhancement NAL unit,
/// header and emulation prevention included. Unwrapping is therefore dropping those two bytes, which is
/// what `dovi_tool demux` does. The result is an ordinary HEVC elementary stream any decoder accepts.
enum DolbyVisionEnhancementLayer {

    static let nalTypeRPU: UInt8 = 62
    static let nalTypeEL: UInt8 = 63

    static let nalTypeVPS: UInt8 = 32
    static let nalTypeSPS: UInt8 = 33
    static let nalTypePPS: UInt8 = 34

    /// HEVC NAL unit type: bits 1...6 of the first header byte.
    static func nalType(_ nal: [UInt8]) -> UInt8? {
        guard let first = nal.first else { return nil }
        return (first >> 1) & 0x3F
    }

    /// The enhancement-layer NAL units of one access unit, unwrapped, in bitstream order. Empty for a
    /// packet with no `unspec63` NAL, which is every packet of a single-layer profile.
    static func nalUnits(_ data: UnsafePointer<UInt8>, _ size: Int, framing: VideoNALFraming) -> [[UInt8]] {
        var out: [[UInt8]] = []
        A53SEIParser.forEachNAL(data, size, framing) { nal, len in
            // Two bytes of wrapper header and at least the inner NAL's own two-byte header.
            guard len > 4, (nal[0] >> 1) & 0x3F == nalTypeEL else { return }
            out.append([UInt8](UnsafeBufferPointer(start: nal + 2, count: len - 2)))
        }
        return out
    }

    static func nalUnits(_ bytes: [UInt8], framing: VideoNALFraming) -> [[UInt8]] {
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress, !bytes.isEmpty else { return [] }
            return nalUnits(base, bytes.count, framing: framing)
        }
    }

    /// The enhancement layer's parameter sets, when this access unit carries all three. A decoder for
    /// the layer can only be opened on them; a stream repeats them at every IRAP, so a seek finds them in
    /// the access unit it lands on.
    struct ParameterSets: Equatable, Sendable {
        var vps: [UInt8]
        var sps: [UInt8]
        var pps: [UInt8]
    }

    static func parameterSets(in nals: [[UInt8]]) -> ParameterSets? {
        var vps: [UInt8]?, sps: [UInt8]?, pps: [UInt8]?
        for nal in nals {
            switch nalType(nal) {
            case nalTypeVPS?: vps = vps ?? nal
            case nalTypeSPS?: sps = sps ?? nal
            case nalTypePPS?: pps = pps ?? nal
            default: break
            }
        }
        guard let vps, let sps, let pps else { return nil }
        return ParameterSets(vps: vps, sps: sps, pps: pps)
    }

    /// NAL units behind four-byte big-endian length prefixes, the framing VideoToolbox decodes.
    static func lengthPrefixed(_ nals: [[UInt8]]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(nals.reduce(0) { $0 + $1.count + 4 })
        for nal in nals {
            let n = nal.count
            out.append(UInt8((n >> 24) & 0xFF))
            out.append(UInt8((n >> 16) & 0xFF))
            out.append(UInt8((n >> 8) & 0xFF))
            out.append(UInt8(n & 0xFF))
            out.append(contentsOf: nal)
        }
        return out
    }

    /// The `dvvC` payload (`DOVIDecoderConfigurationRecord`, 24 bytes) of the single-layer Profile 8.1
    /// stream the base layer is decoded as: profile 8, the source's level, RPU and base layer present,
    /// no enhancement layer, signal compatibility 1 (HDR10). It is what tells VideoToolbox to decode the
    /// layer as Dolby Vision, and so to attach the per-frame metadata the display layer presents with.
    static func profile81ConfigurationRecord(level: Int) -> [UInt8] {
        let lvl = UInt16(min(max(level, 1), 13))
        let bits: UInt16 = (8 << 9) | (lvl << 3) | (1 << 2) | (0 << 1) | 1
        var record = [UInt8](repeating: 0, count: 24)
        record[0] = 1                               // dv_version_major
        record[1] = 0                               // dv_version_minor
        record[2] = UInt8(bits >> 8)
        record[3] = UInt8(bits & 0xFF)
        record[4] = 1 << 4                          // dv_bl_signal_compatibility_id = 1, reserved 0
        return record
    }
}

/// Which session composes a Profile 7 Full Enhancement Layer instead of converting it to Profile 8.1.
///
/// Everything has to hold at once, and anything missing keeps the single-layer conversion the engine
/// already serves: the source is a Profile 7 whose first RPU says FEL (a MEL's residual is zero by
/// construction, so composing it would spend a second decoder on nothing), the display presents Dolby
/// Vision (without it the base layer plays as HDR10, as it always did), the device has a Metal GPU and
/// hardware HEVC decode for both layers, the host has not turned it off, and the source is a seekable
/// VOD whose samples are length-prefixed (the software host feeds VideoToolbox those as they are).
enum DolbyVisionFELPolicy {

    struct Inputs: Equatable, Sendable {
        var dvProfile: Int?
        var enhancementLayerType: String?
        var displayPresentsDolbyVision: Bool
        var presentsBaseLayerOnly: Bool
        var hostAllowsComposition: Bool
        var isLive: Bool
        var sourceIsSeekable: Bool
        var samplesAreLengthPrefixed: Bool
        var hardwareCanCompose: Bool
    }

    static func composes(_ i: Inputs) -> Bool {
        i.dvProfile == 7
            && i.enhancementLayerType == "FEL"
            && i.displayPresentsDolbyVision
            && !i.presentsBaseLayerOnly
            && i.hostAllowsComposition
            && !i.isLive
            && i.sourceIsSeekable
            && i.samplesAreLengthPrefixed
            && i.hardwareCanCompose
    }

    /// Whether the enhancement layer is worth reading for at all, i.e. whether the load pays for a
    /// second open of the source to learn FEL from MEL. Everything `composes` needs except the RPU's
    /// own answer and the hardware, which is the cheapest to ask last.
    static func worthAuditing(_ i: Inputs) -> Bool {
        i.dvProfile == 7
            && i.displayPresentsDolbyVision
            && !i.presentsBaseLayerOnly
            && i.hostAllowsComposition
            && !i.isLive
            && i.sourceIsSeekable
            && i.samplesAreLengthPrefixed
    }
}

/// Pairs the two layers' decoded pictures by presentation time and releases them in the base layer's
/// order. Both VideoToolbox sessions emit in presentation order, but on their own threads and at their
/// own pace, so a base picture can arrive before or after its enhancement partner.
///
/// A base picture whose access unit carried no enhancement layer (or whose enhancement decode failed)
/// is released alone and composed without a residual, which is the prediction from the base layer and
/// exactly what the single-layer conversion would have shown. A partner that never arrives cannot hold
/// the picture forever: past `maxWaiting` base pictures the oldest goes without it.
struct DolbyVisionFramePairing<Picture> {

    struct Key: Hashable, Sendable {
        var value: Int64
        var timescale: Int32
    }

    struct Pair {
        var key: Key
        var base: Picture
        var enhancement: Picture?
    }

    let maxWaiting: Int
    private var expected: Set<Key> = []
    private var bases: [(key: Key, picture: Picture)] = []
    private var enhancements: [Key: Picture] = [:]
    private var enhancementOrder: [Key] = []

    init(maxWaiting: Int = 8) {
        self.maxWaiting = max(1, maxWaiting)
    }

    var waitingBaseCount: Int { bases.count }
    var heldEnhancementCount: Int { enhancements.count }

    /// Register, BEFORE the base access unit is submitted, that its enhancement layer is being decoded,
    /// so a base picture that comes back first waits for it.
    mutating func expectEnhancement(_ key: Key) {
        expected.insert(key)
    }

    /// The enhancement decode for `key` failed or was dropped; its base picture goes without it.
    mutating func enhancementFailed(_ key: Key) -> [Pair] {
        expected.remove(key)
        return release()
    }

    mutating func addBase(_ key: Key, _ picture: Picture) -> [Pair] {
        bases.append((key, picture))
        return release()
    }

    mutating func addEnhancement(_ key: Key, _ picture: Picture) -> [Pair] {
        if enhancements.updateValue(picture, forKey: key) == nil {
            enhancementOrder.append(key)
        }
        // A partner that outlived every base picture it could belong to is not going to be claimed.
        while enhancementOrder.count > maxWaiting * 2, let oldest = enhancementOrder.first {
            enhancementOrder.removeFirst()
            enhancements.removeValue(forKey: oldest)
            expected.remove(oldest)
        }
        return release()
    }

    mutating func reset() {
        expected.removeAll()
        bases.removeAll()
        enhancements.removeAll()
        enhancementOrder.removeAll()
    }

    private mutating func release() -> [Pair] {
        var out: [Pair] = []
        while let head = bases.first {
            if let el = enhancements.removeValue(forKey: head.key) {
                enhancementOrder.removeAll { $0 == head.key }
                expected.remove(head.key)
                out.append(Pair(key: head.key, base: head.picture, enhancement: el))
            } else if !expected.contains(head.key) || bases.count > maxWaiting {
                expected.remove(head.key)
                out.append(Pair(key: head.key, base: head.picture, enhancement: nil))
            } else {
                break
            }
            bases.removeFirst()
        }
        return out
    }
}
