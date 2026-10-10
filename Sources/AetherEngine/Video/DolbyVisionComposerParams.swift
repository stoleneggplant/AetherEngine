import Foundation
import Dovi

/// The per-frame composer half of a Profile 7 RPU: how the base layer predicts the 12-bit signal
/// (`rpu_data_mapping`, a piece-wise polynomial or MMR per component) and how the enhancement layer's
/// residual is dequantized onto it (`rpu_data_nlq`, linear dead zone). The display management half
/// (L1 / L2 / L6 ...) is not here: it rides to the display in the Profile 8.1 RPU the base layer is
/// decoded with, whose mapping is the identity, which is exactly what the composed picture needs.
///
/// Values are kept as real numbers, normalised the way the GPU kernel consumes them. Pivots are base
/// layer code values over `2^bl_bit_depth - 1`; coefficients are `int + frac / 2^coefficient_log2_denom`;
/// the NLQ offset stays in enhancement-layer code values. The arithmetic lives twice, here in Swift as
/// the reference the tests hold and in the Metal kernel (`DolbyVisionFELComposer.kernelSource`), and
/// the two are kept line for line alike.
struct DolbyVisionComposerParams: Equatable, Sendable {

    struct Curve: Equatable, Sendable {
        /// Ascending, normalised, `count >= 2` (pieces = count - 1, at most 8).
        var pivots: [Double]
        var isMMR: Bool
        /// [piece][3]: x^0, x^1, x^2 (zero above the piece's order).
        var poly: [[Double]]
        /// [piece], 1...3.
        var mmrOrder: [Int]
        /// [piece]
        var mmrConstant: [Double]
        /// [piece][order 0...2][7 terms: y, cb, cr, y*cb, y*cr, cb*cr, y*cb*cr]
        var mmrCoef: [[[Double]]]

        static let identity = Curve(
            pivots: [0, 1], isMMR: false, poly: [[0, 1, 0]],
            mmrOrder: [1], mmrConstant: [0], mmrCoef: [[[Double]](repeating: [Double](repeating: 0, count: 7), count: 3)])
    }

    struct NLQ: Equatable, Sendable {
        /// In enhancement-layer code values.
        var offset: Double
        var inMax: Double
        var slope: Double
        var threshold: Double
    }

    static let maxPieces = 8

    var blBitDepth: Int
    var elBitDepth: Int
    var vdrBitDepth: Int
    var disableResidual: Bool
    /// Y, Cb, Cr.
    var curves: [Curve]
    /// Y, Cb, Cr; nil when the RPU carries no usable residual dequantization.
    var nlq: [NLQ]?

    /// Whether a residual can be added at all.
    var appliesResidual: Bool { !disableResidual && nlq != nil }

    // MARK: - Reference arithmetic (mirrored by the Metal kernel)

    /// The predicted signal for component `c`, normalised, from the base layer's normalised
    /// (y, cb, cr). A polynomial piece reads its own component, clamped to the pivot range; an MMR piece
    /// reads all three. Pieces are picked on the component's own value.
    func predict(component c: Int, y: Double, cb: Double, cr: Double) -> Double {
        let curve = curves[c]
        let input = c == 0 ? y : (c == 1 ? cb : cr)
        let n = curve.pivots.count
        guard n >= 2 else { return input }
        let x = min(max(input, curve.pivots[0]), curve.pivots[n - 1])
        var seg = 0
        while seg < n - 2 && x >= curve.pivots[seg + 1] { seg += 1 }
        if curve.isMMR {
            let base = [y, cb, cr, y * cb, y * cr, cb * cr, y * cb * cr]
            var t = base
            var s = curve.mmrConstant[seg]
            let order = min(max(curve.mmrOrder[seg], 1), 3)
            for o in 0..<order {
                for k in 0..<7 { s += curve.mmrCoef[seg][o][k] * t[k] }
                for k in 0..<7 { t[k] *= base[k] }
            }
            return s
        }
        let p = curve.poly[seg]
        return p[0] + x * (p[1] + x * p[2])
    }

    /// The linear dead-zone dequantization of one enhancement-layer code value, normalised to the
    /// composed signal's full scale (ETSI GS CCM 001; the integer form is `vs-nlq`'s):
    /// `sign(t) * min((|t| - 2^(el_bit_depth - 11)) * slope + threshold, in_max)` with `t = code - offset`,
    /// and zero at the offset itself.
    static func residual(code: Double, nlq: NLQ, elBitDepth: Int) -> Double {
        let t = code - nlq.offset
        let a = abs(t)
        if a < 1e-3 { return 0 }
        let half = pow(2.0, Double(elBitDepth - 11))
        let r = min((a - half) * nlq.slope + nlq.threshold, nlq.inMax)
        return t < 0 ? -r : r
    }

    /// The scale of the 12-bit composed signal: the 10-bit code scale times four, so an identity
    /// mapping hands back the base layer's own codes and the requantization below is exact on them.
    static let composedScale: Double = 1023 * 4

    /// One composed sample, normalised, to a 10-bit code: quantised to 12 bits first (the precision
    /// the composer defines), then requantised to 10 with an ordered dither, `floor((v12 + d) / 4)`
    /// with `d` spread over [0, 4) by an 8x8 Bayer matrix. Truncation without the dither bands smooth
    /// gradients, which is the very detail the enhancement layer exists to add.
    static func requantize(_ normalised: Double, bayer: Int) -> UInt16 {
        let v12 = (min(max(normalised, 0), 1) * composedScale).rounded()
        let d = (Double(bayer) + 0.5) / 16
        let v10 = min(max(((v12 + d) / 4).rounded(.down), 0), 1023)
        return UInt16(v10)
    }

    /// The 8x8 ordered-dither index (0...63) at a pixel: the bit-reversed interleave of `x ^ y` and `x`.
    static func bayer8(x: Int, y: Int) -> Int {
        let u = x & 7, v = (x ^ y) & 7
        return ((v & 1) << 5) | ((u & 1) << 4) | ((v & 2) << 2) | ((u & 2) << 1) | ((v & 4) >> 1) | ((u & 4) >> 2)
    }

    // MARK: - GPU layout

    /// Floats per component in `packed()`; offsets below are within one component's block.
    static let componentStride = 224
    static let headerFloats = 8
    static let packedCount = headerFloats + 3 * componentStride

    enum Offset {
        static let numPivots = 0
        static let isMMR = 1
        static let pivots = 2          // 9
        static let mmrOrder = 11       // 8
        static let mmrConstant = 19    // 8
        static let poly = 27           // 8 x 3
        static let mmrCoef = 51        // 8 x 3 x 7
        static let nlq = 219           // offset, inMax, slope, threshold
    }

    /// The layout the kernel reads, all floats so the Swift and Metal sides cannot disagree on
    /// alignment: header `[appliesResidual, elBitDepth, ...]`, then one block per component.
    func packed() -> [Float] {
        var out = [Float](repeating: 0, count: Self.packedCount)
        out[0] = appliesResidual ? 1 : 0
        out[1] = Float(elBitDepth)
        for c in 0..<3 {
            let b = Self.headerFloats + c * Self.componentStride
            let curve = curves[c]
            let n = min(curve.pivots.count, Self.maxPieces + 1)
            out[b + Offset.numPivots] = Float(n)
            out[b + Offset.isMMR] = curve.isMMR ? 1 : 0
            for i in 0..<n { out[b + Offset.pivots + i] = Float(curve.pivots[i]) }
            for s in 0..<max(n - 1, 0) {
                if s < curve.mmrOrder.count { out[b + Offset.mmrOrder + s] = Float(curve.mmrOrder[s]) }
                if s < curve.mmrConstant.count { out[b + Offset.mmrConstant + s] = Float(curve.mmrConstant[s]) }
                if s < curve.poly.count {
                    for k in 0..<3 { out[b + Offset.poly + s * 3 + k] = Float(curve.poly[s][k]) }
                }
                if s < curve.mmrCoef.count {
                    for o in 0..<3 {
                        for k in 0..<7 { out[b + Offset.mmrCoef + s * 21 + o * 7 + k] = Float(curve.mmrCoef[s][o][k]) }
                    }
                }
            }
            if let nlq {
                out[b + Offset.nlq + 0] = Float(nlq[c].offset)
                out[b + Offset.nlq + 1] = Float(nlq[c].inMax)
                out[b + Offset.nlq + 2] = Float(nlq[c].slope)
                out[b + Offset.nlq + 3] = Float(nlq[c].threshold)
            }
        }
        return out
    }
}

// MARK: - From libdovi

extension DolbyVisionComposerParams {

    /// The composer parameters of the first `unspec62` RPU in an access unit, or nil when there is
    /// none, it does not parse, or it describes something the kernel does not implement (floating
    /// point coefficients, a linear-interpolation polynomial, more than one NLQ pivot, a bit depth
    /// other than 10-bit layers into a 12-bit signal). nil keeps the frame on the base layer alone,
    /// which is what the single-layer conversion shows.
    static func fromAccessUnit(_ data: UnsafePointer<UInt8>, _ size: Int, framing: VideoNALFraming) -> Self? {
        var result: Self?
        var seen = false
        A53SEIParser.forEachNAL(data, size, framing) { nal, len in
            guard !seen, (nal[0] >> 1) & 0x3F == DolbyVisionEnhancementLayer.nalTypeRPU else { return }
            seen = true
            guard let rpu = dovi_parse_unspec62_nalu(nal, len) else { return }
            defer { dovi_rpu_free(rpu) }
            guard let header = dovi_rpu_get_header(rpu) else { return }
            defer { dovi_rpu_free_header(header) }
            guard let mapping = dovi_rpu_get_data_mapping(rpu) else { return }
            defer { dovi_rpu_free_data_mapping(mapping) }
            result = make(header: header.pointee, mapping: mapping.pointee)
        }
        return result
    }

    static func make(header h: DoviRpuDataHeader, mapping m: DoviRpuDataMapping) -> Self? {
        // Fixed-point coefficients only; Profile 7 masters do not use the float form.
        guard h.coefficient_data_type == 0 else { return nil }
        let denom = Int(h.coefficient_log2_denom)
        guard denom > 0, denom <= 32 else { return nil }
        let blBitDepth = Int(h.bl_bit_depth_minus8) + 8
        let elBitDepth = Int(h.el_bit_depth_minus8) + 8
        let vdrBitDepth = Int(h.vdr_bit_depth_minus8) + 8
        guard blBitDepth == 10, elBitDepth == 10, vdrBitDepth >= 10, vdrBitDepth <= 16 else { return nil }
        let scale = 1.0 / Double(UInt64(1) << UInt64(denom))
        let pivotScale = Double((1 << blBitDepth) - 1)

        let raw = [m.curves.0, m.curves.1, m.curves.2]
        var curves: [Curve] = []
        for c in raw {
            guard let curve = makeCurve(c, scale: scale, pivotScale: pivotScale) else { return nil }
            curves.append(curve)
        }

        var nlq: [NLQ]?
        if let n = m.nlq, m.nlq_method_idc == 0, m.nlq_num_pivots_minus2 == 0 {
            let p = n.pointee
            let offsets = [p.nlq_offset.0, p.nlq_offset.1, p.nlq_offset.2]
            let inMaxInt = [p.vdr_in_max_int.0, p.vdr_in_max_int.1, p.vdr_in_max_int.2]
            let inMax = [p.vdr_in_max.0, p.vdr_in_max.1, p.vdr_in_max.2]
            let slopeInt = [p.linear_deadzone_slope_int.0, p.linear_deadzone_slope_int.1, p.linear_deadzone_slope_int.2]
            let slope = [p.linear_deadzone_slope.0, p.linear_deadzone_slope.1, p.linear_deadzone_slope.2]
            let thrInt = [p.linear_deadzone_threshold_int.0, p.linear_deadzone_threshold_int.1, p.linear_deadzone_threshold_int.2]
            let thr = [p.linear_deadzone_threshold.0, p.linear_deadzone_threshold.1, p.linear_deadzone_threshold.2]
            nlq = (0..<3).map { i in
                NLQ(offset: Double(offsets[i]),
                    inMax: Double(inMaxInt[i]) + Double(inMax[i]) * scale,
                    slope: Double(slopeInt[i]) + Double(slope[i]) * scale,
                    threshold: Double(thrInt[i]) + Double(thr[i]) * scale)
            }
        }

        return DolbyVisionComposerParams(
            blBitDepth: blBitDepth, elBitDepth: elBitDepth, vdrBitDepth: vdrBitDepth,
            disableResidual: h.disable_residual_flag, curves: curves, nlq: nlq)
    }

    private static func makeCurve(_ c: DoviReshapingCurve, scale: Double, pivotScale: Double) -> Curve? {
        let numPivots = Int(c.num_pivots_minus2) + 2
        let pieces = numPivots - 1
        guard pieces >= 1, pieces <= maxPieces, let pivotData = c.pivots.data, c.pivots.len >= numPivots else {
            return nil
        }
        // The bitstream codes each pivot as a delta on the one before it (libdovi keeps them as coded,
        // FFmpeg accumulates them); an identity curve reads [0, 1023].
        var pivots: [Double] = []
        var running = 0
        for i in 0..<numPivots {
            running += Int(pivotData[i])
            pivots.append(Double(running) / pivotScale)
        }

        let zeroTerms = [[Double]](repeating: [Double](repeating: 0, count: 7), count: 3)
        var poly = [[Double]](repeating: [0, 0, 0], count: pieces)
        var mmrOrder = [Int](repeating: 1, count: pieces)
        var mmrConstant = [Double](repeating: 0, count: pieces)
        var mmrCoef = [[[Double]]](repeating: zeroTerms, count: pieces)

        switch c.mapping_idc {
        case 0:
            guard let pc = c.polynomial?.pointee,
                  let orders = pc.poly_order_minus1.data, pc.poly_order_minus1.len >= pieces,
                  let ints = pc.poly_coef_int.list, pc.poly_coef_int.len >= pieces,
                  let fracs = pc.poly_coef.list, pc.poly_coef.len >= pieces else { return nil }
            if let interp = pc.linear_interp_flag.data {
                for i in 0..<min(pieces, pc.linear_interp_flag.len) where interp[i] != 0 { return nil }
            }
            for s in 0..<pieces {
                let order = Int(orders[s]) + 1
                guard order >= 1, order <= 2,
                      let rowInt = ints[s]?.pointee, let rowFrac = fracs[s]?.pointee,
                      let vi = rowInt.data, let vf = rowFrac.data,
                      rowInt.len > order, rowFrac.len > order else { return nil }
                for k in 0...order {
                    poly[s][k] = Double(vi[k]) + Double(vf[k]) * scale
                }
            }
            return Curve(pivots: pivots, isMMR: false, poly: poly,
                         mmrOrder: mmrOrder, mmrConstant: mmrConstant, mmrCoef: mmrCoef)

        case 1:
            guard let mc = c.mmr?.pointee,
                  let orders = mc.mmr_order_minus1.data, mc.mmr_order_minus1.len >= pieces,
                  let constInt = mc.mmr_constant_int.data, mc.mmr_constant_int.len >= pieces,
                  let constFrac = mc.mmr_constant.data, mc.mmr_constant.len >= pieces,
                  let coefInt = mc.mmr_coef_int.list, mc.mmr_coef_int.len >= pieces,
                  let coefFrac = mc.mmr_coef.list, mc.mmr_coef.len >= pieces else { return nil }
            for s in 0..<pieces {
                let order = Int(orders[s]) + 1
                guard order >= 1, order <= 3,
                      let planeInt = coefInt[s]?.pointee, let planeFrac = coefFrac[s]?.pointee,
                      let rowsInt = planeInt.list, let rowsFrac = planeFrac.list,
                      planeInt.len >= order, planeFrac.len >= order else { return nil }
                mmrOrder[s] = order
                mmrConstant[s] = Double(constInt[s]) + Double(constFrac[s]) * scale
                for o in 0..<order {
                    guard let rowInt = rowsInt[o]?.pointee, let rowFrac = rowsFrac[o]?.pointee,
                          let vi = rowInt.data, let vf = rowFrac.data,
                          rowInt.len >= 7, rowFrac.len >= 7 else { return nil }
                    for k in 0..<7 {
                        mmrCoef[s][o][k] = Double(vi[k]) + Double(vf[k]) * scale
                    }
                }
            }
            return Curve(pivots: pivots, isMMR: true, poly: poly,
                         mmrOrder: mmrOrder, mmrConstant: mmrConstant, mmrCoef: mmrCoef)

        default:
            return nil
        }
    }
}
