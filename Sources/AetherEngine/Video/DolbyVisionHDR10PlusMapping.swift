import Foundation

/// Dolby Vision Level 1 brightness statistics -> SMPTE ST 2094-40 (HDR10+) dynamic metadata.
///
/// Pure arithmetic and bit packing, no FFmpeg and no libdovi, so every number it produces can be pinned
/// by a test. `DolbyVisionHDR10PlusSynthesizer` is the half that reads the RPU and rewrites packets.
///
/// What maps exactly, and where the equivalence comes from:
/// - Dolby Vision L1 `max_pq` is the per-shot peak of the PQ-encoded maxRGB signal. It becomes the HDR10+
///   MaxSCL (all three components) and the 99.98th maxRGB percentile. dovi_tool (MIT) derives L1 max from
///   exactly these two HDR10+ fields when it generates an RPU from HDR10+ (`generate --hdr10plus-json`,
///   peak source `max-scl` / `histogram99`), and libplacebo (LGPL-2.1) treats L1 max and the HDR10+ peak
///   as the same tone-mapping input. This is that mapping run the other way.
/// - L3 (CM v4.0 "L1 offsets") is applied to L1 before anything else, as a CM v4.0 display manager does.
///
/// What is modelled, because ST 2094-40 carries more than L1 does:
/// - L1 `avg_pq` is a mean in the PQ domain (dovi_tool's madVR import writes madVR's PQ average into it
///   unchanged), while HDR10+ `average_maxrgb` is a linear-light mean in nits. A PQ mean read straight as
///   nits under-states the linear mean several times over (Jensen; measured 26.8 vs 104.6 nits on the
///   HDR10+ conformance frame below). So the shot's maxRGB distribution is modelled, and the linear mean
///   and the percentiles are read off the model.
/// - The model is a Beta distribution over the shot's PQ range [min_pq, max_pq] whose mean is the L1
///   average, with a fixed concentration `kappa`. With `kappa = 4.4`, fitted to the one natural-content
///   frame in hdr10plus_tool's Samsung conformance clips (`ToS-s01`: 99.98% = 1444.5 nits), it reproduces
///   that frame's 25/50/75/90/95th percentiles as 5.2/26.2/104.5/282/449 nits against the measured
///   5.6/21.9/103.6/271/467, and its average as 95.5 against 103.7.
/// - The 5% and 10% slots of an application-version-1 histogram are not CDF points (ST 2094-40 8.5.4,
///   as libplacebo reads them): the 5% slot carries the frame's near-peak luminance, the 10% slot the share
///   of pixels at or under 100 nits. Both are filled the way Samsung's own encoder fills them.
///
/// The output is Profile A: one window, no Bezier curve, `targeted_system_display_maximum_luminance = 0`,
/// so the TV computes its own curve from the distribution. It passes hdr10plus_tool's validator and
/// FFmpeg decodes it as `AV_FRAME_DATA_DYNAMIC_HDR_PLUS`.
enum DolbyVisionHDR10PlusMapping {

    /// One shot's L1 statistics in 12-bit PQ code values (0...4095), with optional L3 offsets
    /// (12-bit, biased by 2048).
    struct Level1: Equatable, Sendable {
        var minPQ: Int
        var maxPQ: Int
        var avgPQ: Int

        init(minPQ: Int, maxPQ: Int, avgPQ: Int) {
            self.minPQ = minPQ
            self.maxPQ = maxPQ
            self.avgPQ = avgPQ
        }

        /// L1 with L3 applied: each L3 value is an offset biased by 2048, so 2048 is no change.
        func applyingOffsets(min: Int, max: Int, avg: Int) -> Level1 {
            func offset(_ value: Int, _ biased: Int) -> Int { Swift.min(Swift.max(value + biased - 2048, 0), 4095) }
            return Level1(minPQ: offset(minPQ, min), maxPQ: offset(maxPQ, max), avgPQ: offset(avgPQ, avg))
        }
    }

    /// The ST 2094-40 fields this mapping writes, all in the standard's units: luminance in 0.1 cd/m2
    /// (0...100000), percentages as integer percent.
    struct Metadata: Equatable, Sendable {
        var maxSCL: [UInt32]
        var averageMaxRGB: UInt32
        var distribution: [(percentage: UInt8, percentile: UInt32)]

        static func == (lhs: Metadata, rhs: Metadata) -> Bool {
            lhs.maxSCL == rhs.maxSCL && lhs.averageMaxRGB == rhs.averageMaxRGB
                && lhs.distribution.map(\.percentage) == rhs.distribution.map(\.percentage)
                && lhs.distribution.map(\.percentile) == rhs.distribution.map(\.percentile)
        }
    }

    /// The nine-entry percentile index every HDR10+ encoder in the wild writes; 99 stands for 99.98%.
    static let percentages: [UInt8] = [1, 5, 10, 25, 50, 75, 90, 95, 99]
    static let kappa = 4.4
    static let modelBins = 256

    // MARK: - L1 -> metadata

    static func metadata(for input: Level1) -> Metadata {
        let minPQ = Double(min(max(input.minPQ, 0), 4095))
        let maxPQ = max(Double(min(max(input.maxPQ, 0), 4095)), minPQ)
        let avgPQ = min(max(Double(min(max(input.avgPQ, 0), 4095)), minPQ), maxPQ)
        let maxTenths = tenths(pqToNits(maxPQ))

        guard maxPQ > minPQ else {
            // A flat shot (a title card, black): every percentile is the one level there is.
            var values = [UInt32](repeating: maxTenths, count: percentages.count)
            values[2] = pqToNits(maxPQ) <= 100 ? 100 : 0
            return Metadata(maxSCL: [maxTenths, maxTenths, maxTenths], averageMaxRGB: maxTenths,
                            distribution: zip(percentages, values).map { ($0, $1) })
        }

        let model = Model(minPQ: minPQ, maxPQ: maxPQ, avgPQ: avgPQ)
        let averageTenths = min(tenths(model.linearMeanNits()), maxTenths)
        var values: [UInt32] = []
        values.reserveCapacity(percentages.count)
        var floor: UInt32 = 0
        for percentage in percentages {
            switch percentage {
            case 5:
                values.append(maxTenths)
            case 10:
                values.append(UInt32((100 * model.share(atOrBelowPQ: nitsToPQ(100))).rounded()))
            default:
                var value = percentage == 99
                    ? maxTenths
                    : min(tenths(pqToNits(model.quantile(Double(percentage) / 100))), maxTenths)
                value = max(value, floor)
                floor = value
                values.append(value)
            }
        }
        return Metadata(maxSCL: [maxTenths, maxTenths, maxTenths], averageMaxRGB: averageTenths,
                        distribution: zip(percentages, values).map { ($0, $1) })
    }

    /// Beta(kappa * m, kappa * (1 - m)) over [minPQ, maxPQ], m the normalised L1 average, discretised
    /// into `modelBins` equal bins.
    struct Model {
        let minPQ: Double
        let span: Double
        let mass: [Double]
        let cumulative: [Double]

        init(minPQ: Double, maxPQ: Double, avgPQ: Double) {
            self.minPQ = minPQ
            span = maxPQ - minPQ
            let mean = min(max((avgPQ - minPQ) / span, 0.01), 0.99)
            let alpha = mean * DolbyVisionHDR10PlusMapping.kappa
            let beta = (1 - mean) * DolbyVisionHDR10PlusMapping.kappa
            let bins = DolbyVisionHDR10PlusMapping.modelBins
            var weights = [Double](repeating: 0, count: bins)
            var total = 0.0
            for i in 0..<bins {
                let x = (Double(i) + 0.5) / Double(bins)
                let w = exp((alpha - 1) * log(x) + (beta - 1) * log(1 - x))
                weights[i] = w
                total += w
            }
            var running = 0.0
            var cdf = [Double](repeating: 0, count: bins)
            for i in 0..<bins {
                weights[i] /= total
                running += weights[i]
                cdf[i] = running
            }
            mass = weights
            cumulative = cdf
        }

        private func pq(atBinCentre i: Int) -> Double {
            minPQ + span * (Double(i) + 0.5) / Double(mass.count)
        }

        func quantile(_ q: Double) -> Double {
            var i = 0
            while i < cumulative.count - 1, cumulative[i] < q { i += 1 }
            let lower = i > 0 ? cumulative[i - 1] : 0
            let fraction = cumulative[i] > lower ? (q - lower) / (cumulative[i] - lower) : 0
            return minPQ + span * (Double(i) + fraction) / Double(mass.count)
        }

        func linearMeanNits() -> Double {
            var sum = 0.0
            for i in 0..<mass.count { sum += mass[i] * DolbyVisionHDR10PlusMapping.pqToNits(pq(atBinCentre: i)) }
            return sum
        }

        func share(atOrBelowPQ threshold: Double) -> Double {
            var sum = 0.0
            for i in 0..<mass.count where pq(atBinCentre: i) <= threshold { sum += mass[i] }
            return sum
        }
    }

    // MARK: - SMPTE ST 2084

    private static let m1 = 2610.0 / 16384
    private static let m2 = 2523.0 / 4096 * 128
    private static let c1 = 3424.0 / 4096
    private static let c2 = 2413.0 / 4096 * 32
    private static let c3 = 2392.0 / 4096 * 32

    /// 12-bit PQ code value -> cd/m2.
    static func pqToNits(_ code: Double) -> Double {
        let e = min(max(code, 0), 4095) / 4095
        let p = pow(e, 1 / m2)
        return 10000 * pow(max(p - c1, 0) / (c2 - c3 * p), 1 / m1)
    }

    /// cd/m2 -> 12-bit PQ code value.
    static func nitsToPQ(_ nits: Double) -> Double {
        let y = pow(min(max(nits, 0), 10000) / 10000, m1)
        return 4095 * pow((c1 + c2 * y) / (1 + c3 * y), m2)
    }

    private static func tenths(_ nits: Double) -> UInt32 {
        UInt32(min(max((nits * 10).rounded(), 0), 100_000))
    }

    // MARK: - ST 2094-40 serialisation

    /// `user_data_registered_itu_t_t35` payload, from the country code on: ITU-T T.35 USA (0xB5),
    /// Samsung's provider code (0x003C) and oriented code (0x0001), application 4 version 1.
    static func t35Payload(_ metadata: Metadata) -> [UInt8] {
        var writer = BitWriter()
        writer.put(0xB5, bits: 8)                 // itu_t_t35_country_code
        writer.put(0x003C, bits: 16)              // itu_t_t35_terminal_provider_code
        writer.put(0x0001, bits: 16)              // itu_t_t35_terminal_provider_oriented_code
        writer.put(4, bits: 8)                    // application_identifier
        writer.put(1, bits: 8)                    // application_version
        writer.put(1, bits: 2)                    // num_windows
        writer.put(0, bits: 27)                   // targeted_system_display_maximum_luminance
        writer.put(0, bits: 1)                    // targeted_system_display_actual_peak_luminance_flag
        for component in metadata.maxSCL.prefix(3) {
            writer.put(min(component, 100_000), bits: 17)
        }
        writer.put(min(metadata.averageMaxRGB, 100_000), bits: 17)
        let entries = metadata.distribution.prefix(15)
        writer.put(UInt32(entries.count), bits: 4) // num_distribution_maxrgb_percentiles
        for entry in entries {
            writer.put(UInt32(min(entry.percentage, 100)), bits: 7)
            writer.put(min(entry.percentile, 100_000), bits: 17)
        }
        writer.put(0, bits: 10)                   // fraction_bright_pixels
        writer.put(0, bits: 1)                    // mastering_display_actual_peak_luminance_flag
        writer.put(0, bits: 1)                    // tone_mapping_flag (Profile A)
        writer.put(0, bits: 1)                    // color_saturation_mapping_flag
        return writer.bytes
    }

    /// The complete HEVC prefix SEI NAL unit (type 39, layer 0, temporal id 0) carrying one
    /// `user_data_registered_itu_t_t35` message, emulation prevention applied. No framing prefix.
    static func hevcPrefixSEINAL(t35Payload payload: [UInt8]) -> [UInt8] {
        var rbsp: [UInt8] = [4]                   // payloadType: user_data_registered_itu_t_t35
        var size = payload.count
        while size >= 255 { rbsp.append(0xFF); size -= 255 }
        rbsp.append(UInt8(size))
        rbsp.append(contentsOf: payload)
        rbsp.append(0x80)                         // rbsp_trailing_bits
        var nal: [UInt8] = [39 << 1, 0x01]
        nal.reserveCapacity(rbsp.count + 8)
        var zeros = 0
        for byte in rbsp {
            if zeros >= 2, byte <= 3 {
                nal.append(0x03)
                zeros = 0
            }
            nal.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return nal
    }

    struct BitWriter {
        private(set) var bytes: [UInt8] = []
        private var used = 0

        mutating func put(_ value: UInt32, bits: Int) {
            for shift in stride(from: bits - 1, through: 0, by: -1) {
                if used == 0 { bytes.append(0) }
                if (value >> UInt32(shift)) & 1 == 1 {
                    bytes[bytes.count - 1] |= UInt8(0x80 >> used)
                }
                used = (used + 1) & 7
            }
        }
    }
}
