import Foundation

/// HDR10+ (SMPTE ST 2094-40) -> Dolby Vision Profile 8.1, the arithmetic half. Pure, so every number it
/// produces can be pinned by a test; `DolbyVisionRPUGenerator` turns its output into RPUs and
/// `HDR10PlusDolbyVisionInjector` puts them in the bitstream.
///
/// This is dovi_tool's own conversion (MIT, `dovi_tool generate --hdr10plus-json`, `src/dovi/generator.rs`),
/// run per picture instead of from a JSON file:
/// - Level 1 per shot: `min_pq` 0; `max_pq` from the HDR10+ peak, by default the largest value of the maxRGB
///   distribution (dovi_tool's default peak source, `histogram`); `avg_pq` from `average_maxrgb`. Both are
///   rounded to whole cd/m2 and encoded with `nits_to_pq_12_bit`, then clamped the way the generator's
///   `fixup_l1` clamps them for CM v4.0 (min to 0...12, max to 2081...4095, avg to 1229...max-1).
/// - Level 6 from the HDR10 static metadata the base layer already carries (mastering display, MaxCLL /
///   MaxFALL), Level 9 from its mastering primaries where they are one of Dolby's predefined sets.
/// - The RPU itself, with the generator's Profile 8.1 defaults (identity mapping over the HDR10 base layer,
///   CM v4.0 L3 / L9 / L11 / L254), is libdovi's `dovi_generate_from_json`, the library dovi_tool is built on.
///
/// The base layer is unchanged and its HDR10+ stays in it, so a display without Dolby Vision still gets the
/// HDR10+ the file was mastered with.
enum HDR10PlusDolbyVisionMapping {

    /// One picture's ST 2094-40 values, in the standard's integer units (0.1 cd/m2).
    struct FrameStats: Equatable, Sendable {
        var maxSCL: [UInt32]
        var averageMaxRGB: UInt32
        var distribution: [UInt32]
    }

    /// Where the Dolby Vision peak is taken from, as dovi_tool's `--hdr10plus-peak-source` names them.
    enum PeakSource: String, Sendable {
        /// The largest value in the maxRGB distribution. dovi_tool's default.
        case histogram
        /// The last distribution entry, the 99.98th percentile.
        case histogram99
        /// The largest MaxSCL component.
        case maxSCL

        func peakNits(_ stats: FrameStats) -> Double? {
            switch self {
            case .histogram: return stats.distribution.max().map { Double($0) / 10 }
            case .histogram99: return stats.distribution.last.map { Double($0) / 10 }
            case .maxSCL: return stats.maxSCL.max().map { Double($0) / 10 }
            }
        }
    }

    /// L1 in 12-bit PQ code values.
    struct Level1: Hashable, Sendable {
        var minPQ: Int
        var maxPQ: Int
        var avgPQ: Int
    }

    static let l1MinPQMax = 12
    static let l1MaxPQMin = 2081
    static let l1MaxPQMax = 4095
    static let l1AvgPQMinCMv40 = 1229

    /// dovi_tool's HDR10+ -> L1, clamped for CM v4.0. nil when the picture states no peak at all.
    static func level1(_ stats: FrameStats, peakSource: PeakSource = .histogram) -> Level1? {
        guard let peak = peakSource.peakNits(stats) else { return nil }
        let average = Double(stats.averageMaxRGB) / 10
        return clamped(Level1(minPQ: 0, maxPQ: pq12(peak.rounded()), avgPQ: pq12(average.rounded())))
    }

    /// `ExtMetadataBlockLevel1::clamp_values_int` for CM v4.0.
    static func clamped(_ l1: Level1) -> Level1 {
        let maxPQ = min(max(l1.maxPQ, l1MaxPQMin), l1MaxPQMax)
        return Level1(minPQ: min(max(l1.minPQ, 0), l1MinPQMax),
                      maxPQ: maxPQ,
                      avgPQ: min(max(l1.avgPQ, l1AvgPQMinCMv40), maxPQ - 1))
    }

    // MARK: - SMPTE ST 2084

    private static let m1 = 2610.0 / 16384
    private static let m2 = 2523.0 / 4096 * 128
    private static let c1 = 3424.0 / 4096
    private static let c2 = 2413.0 / 4096 * 32
    private static let c3 = 2392.0 / 4096 * 32

    /// dovi_tool's `nits_to_pq_12_bit`: PQ of `nits`, scaled to 4095 and rounded half away from zero.
    static func pq12(_ nits: Double) -> Int {
        let y = max(nits, 0) / 10000
        let ym = pow(y, m1)
        let pq = pow((c1 + c2 * ym) / (1 + c3 * ym), m2)
        return Int((pq * 4095).rounded())
    }

    // MARK: - Static metadata

    /// The HDR10 static metadata the base layer carries, as the generator's Level 6 wants it.
    struct Level6: Equatable, Sendable {
        /// cd/m2.
        var maxMasteringLuminance: Int
        /// 0.0001 cd/m2.
        var minMasteringLuminance: Int
        var maxCLL: Int
        var maxFALL: Int

        /// The generator's own default, used when the base layer states no mastering display.
        static let generatorDefault = Level6(maxMasteringLuminance: 1000, minMasteringLuminance: 1, maxCLL: 0, maxFALL: 0)
    }

    /// Dolby's predefined mastering primaries (dovi_tool `primaries.rs`) that a Level 9 index can name, as
    /// CIE 1931 xy, red, green, blue, white.
    static let predefinedPrimaries: [(index: Int, xy: [Double])] = [
        (0, [0.68, 0.32, 0.265, 0.69, 0.15, 0.06, 0.3127, 0.329]),       // DCI-P3 D65
        (1, [0.64, 0.33, 0.30, 0.60, 0.15, 0.06, 0.3127, 0.329]),        // BT.709
        (2, [0.708, 0.292, 0.170, 0.797, 0.131, 0.046, 0.3127, 0.329]),  // BT.2020
    ]

    /// The Level 9 index for mastering primaries (red, green, blue, white xy), or nil when they are none of
    /// the predefined sets; the RPU then keeps the generator's default.
    static func primaryIndex(_ xy: [Double], tolerance: Double = 0.002) -> Int? {
        guard xy.count == 8 else { return nil }
        return predefinedPrimaries.first { entry in
            zip(entry.xy, xy).allSatisfy { abs($0 - $1) <= tolerance }
        }?.index
    }

    /// What a session converting HDR10+ to Dolby Vision carries into its producers: the static half of every
    /// RPU, read once from the source's HDR10 metadata.
    struct Conversion: Equatable, Sendable {
        var level6: Level6
        var primaryIndex: Int?
    }

    // MARK: - Generator configuration

    /// The `GenerateConfig` JSON for one shot of two pictures: libdovi's generator sets the scene-cut flag on
    /// a shot's first picture, so the pair is the shot's scene-cut RPU and the RPU of every picture after it.
    static func generateConfigJSON(level1: Level1, level6: Level6, primaryIndex: Int?) -> String {
        var defaults: [[String: Any]] = []
        if let primaryIndex {
            defaults.append(["Level9": ["length": 1, "source_primary_index": primaryIndex]])
        }
        let config: [String: Any] = [
            "cm_version": "V40",
            "profile": "8.1",
            "length": 2,
            "level6": [
                "max_display_mastering_luminance": level6.maxMasteringLuminance,
                "min_display_mastering_luminance": level6.minMasteringLuminance,
                "max_content_light_level": level6.maxCLL,
                "max_frame_average_light_level": level6.maxFALL,
            ],
            "default_metadata_blocks": defaults,
            "shots": [[
                "start": 0,
                "duration": 2,
                "metadata_blocks": [[
                    "Level1": ["min_pq": level1.minPQ, "max_pq": level1.maxPQ, "avg_pq": level1.avgPQ],
                ]],
            ]],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Dolby Vision level

    /// The Dolby Vision level a Profile 8.1 stream of this size and rate declares: the lowest whose maximum
    /// pixel rate and picture width admit it. The table and the rule are FFmpeg's (`dv_levels[]` in
    /// libavcodec/dovi_rpuenc.c, LGPL), which also leaves the bitrate out; the slack of one part in a
    /// thousand keeps a rate stated as 30.0003 from climbing a level.
    static func dolbyVisionLevel(width: Int, height: Int, framesPerSecond: Double?) -> Int {
        let fps = (framesPerSecond.map { $0.isFinite && $0 > 0 ? $0 : 24 }) ?? 24
        let rate = Double(width * height) * fps
        let levels: [(level: Int, maxWidth: Int, maxRate: Double)] = [
            (1, 1280, 22_118_400), (2, 1280, 27_648_000), (3, 1920, 49_766_400), (4, 2560, 62_208_000),
            (5, 3840, 124_416_000), (6, 3840, 199_065_600), (7, 3840, 248_832_000), (8, 3840, 398_131_200),
            (9, 3840, 497_664_000), (10, 3840, 995_328_000), (11, 7680, 995_328_000),
            (12, 7680, 1_990_656_000), (13, 7680, 3_981_312_000),
        ]
        return levels.first { width <= $0.maxWidth && rate <= $0.maxRate * 1.001 }?.level ?? 13
    }

    // MARK: - Scene cuts in presentation order

    /// Decides which picture opens a shot. dovi_tool sets the scene-cut flag on a shot's first picture in
    /// presentation order, while packets arrive in decode order. A picture opens a shot when its L1 differs
    /// from the already-decoded picture that presents just before it. That catches every cut (measured
    /// against dovi_tool's own output on hdr10plus_tool's test stream: every cut found), and at worst flags
    /// an anchor decoded ahead of its B-pictures as well. The extra refresh lands inside a shot whose
    /// pictures all carry the same L1, so the display does nothing different.
    struct SceneCutTracker {
        private var recent: [(pts: Int64, level1: Level1)] = []
        private let capacity: Int
        private var lastDecoded: Level1?

        init(capacity: Int = 32) { self.capacity = capacity }

        mutating func opensShot(pts: Int64?, level1: Level1) -> Bool {
            defer { lastDecoded = level1 }
            guard let pts else { return level1 != lastDecoded }
            var low = 0, high = recent.count
            while low < high {
                let mid = (low + high) / 2
                if recent[mid].pts < pts { low = mid + 1 } else { high = mid }
            }
            let predecessor = low > 0 ? recent[low - 1].level1 : nil
            recent.insert((pts, level1), at: low)
            if recent.count > capacity { recent.removeFirst() }
            return predecessor != level1
        }
    }
}
