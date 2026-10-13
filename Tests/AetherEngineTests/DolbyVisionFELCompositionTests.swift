import Foundation
import CoreVideo
import Testing
@testable import AetherEngine

/// Dolby Vision Profile 7 FEL composition: the pure halves of the dual-layer path. The GPU kernel
/// mirrors `DolbyVisionComposerParams`' reference arithmetic line for line, so the arithmetic is held
/// here against the integer reference it was written from (`vs-nlq`), and the plumbing around it
/// (unwrapping the enhancement layer, pairing the two decoders' pictures, the routing gate) against
/// the shapes a UHD Blu-ray remux delivers. On-device composition is validated against `dovi_tool`-
/// demuxed layers; nothing in CI has a GPU to run the kernel on.
@Suite("Dolby Vision Profile 7 FEL composition")
struct DolbyVisionFELCompositionTests {

    // MARK: - Enhancement layer extraction

    private func nal(type: UInt8, payload: [UInt8]) -> [UInt8] {
        [UInt8(type << 1), 0x01] + payload
    }

    /// An enhancement NAL wrapped the way a single-track Profile 7 carries it.
    private func wrapped(_ inner: [UInt8]) -> [UInt8] {
        [0x7E, 0x01] + inner
    }

    @Test("unspec63 NALs are unwrapped to the enhancement layer's own NAL units, in order")
    func unwrapsEnhancementLayer() {
        let vps = nal(type: 32, payload: [0xAA, 0x01])
        let sps = nal(type: 33, payload: [0xBB, 0x02])
        let pps = nal(type: 34, payload: [0xCC, 0x03])
        let slice = nal(type: 19, payload: [0xDD, 0x04, 0x05])
        let access = [
            nal(type: 19, payload: [0x10, 0x11, 0x12]),          // base layer IDR slice
            wrapped(vps), wrapped(sps), wrapped(pps), wrapped(slice),
            nal(type: 62, payload: [0x19, 0x08, 0x09]),          // RPU
        ]
        let bytes = DolbyVisionEnhancementLayer.lengthPrefixed(access)
        let el = DolbyVisionEnhancementLayer.nalUnits(bytes, framing: .lengthPrefixed(size: 4))
        #expect(el == [vps, sps, pps, slice])
        #expect(DolbyVisionEnhancementLayer.parameterSets(in: el)
                == .init(vps: vps, sps: sps, pps: pps))
    }

    @Test("a single-layer access unit has no enhancement layer and no parameter sets for it")
    func singleLayerHasNone() {
        let bytes = DolbyVisionEnhancementLayer.lengthPrefixed([
            nal(type: 1, payload: [0x01, 0x02, 0x03]), nal(type: 62, payload: [0x19]),
        ])
        let el = DolbyVisionEnhancementLayer.nalUnits(bytes, framing: .lengthPrefixed(size: 4))
        #expect(el.isEmpty)
        #expect(DolbyVisionEnhancementLayer.parameterSets(in: el) == nil)
    }

    @Test("Annex B access units unwrap the same way")
    func unwrapsAnnexB() {
        let slice = nal(type: 1, payload: [0x21, 0x22, 0x23])
        var bytes: [UInt8] = []
        for n in [nal(type: 1, payload: [0x01, 0x02]), wrapped(slice)] {
            bytes += [0, 0, 0, 1] + n
        }
        #expect(DolbyVisionEnhancementLayer.nalUnits(bytes, framing: .annexB) == [slice])
    }

    @Test("the base layer's dvvC names single-layer Profile 8.1 at the source's level")
    func profile81Record() {
        let record = DolbyVisionEnhancementLayer.profile81ConfigurationRecord(level: 6)
        #expect(record.count == 24)
        #expect(record[0] == 1 && record[1] == 0)
        let bits = (UInt16(record[2]) << 8) | UInt16(record[3])
        #expect(bits >> 9 == 8)                 // profile
        #expect((bits >> 3) & 0x3F == 6)        // level
        #expect((bits >> 2) & 1 == 1)           // rpu present
        #expect((bits >> 1) & 1 == 0)           // no enhancement layer
        #expect(bits & 1 == 1)                  // base layer present
        #expect(record[4] >> 4 == 1)            // HDR10-compatible base
        #expect(record[5...].allSatisfy { $0 == 0 })
    }

    // MARK: - Pairing

    private typealias Pairing = DolbyVisionFramePairing<Int>
    private func key(_ v: Int64) -> Pairing.Key { .init(value: v, timescale: 1000) }

    @Test("a base picture waits for the enhancement picture it was promised, in either arrival order")
    func pairsEitherOrder() {
        var p = Pairing()
        p.expectEnhancement(key(1))
        #expect(p.addBase(key(1), 10).isEmpty)
        let out = p.addEnhancement(key(1), 11)
        #expect(out.count == 1 && out[0].base == 10 && out[0].enhancement == 11)

        p.expectEnhancement(key(2))
        #expect(p.addEnhancement(key(2), 21).isEmpty)
        let out2 = p.addBase(key(2), 20)
        #expect(out2.count == 1 && out2[0].enhancement == 21)
        #expect(p.waitingBaseCount == 0 && p.heldEnhancementCount == 0)
    }

    @Test("a base picture with no enhancement expected goes out at once, behind any that wait")
    func releasesInBaseOrder() {
        var p = Pairing()
        p.expectEnhancement(key(1))
        #expect(p.addBase(key(1), 10).isEmpty)
        #expect(p.addBase(key(2), 20).isEmpty)              // held behind 1, keeps order
        let out = p.addEnhancement(key(1), 11)
        #expect(out.map(\.base) == [10, 20])
        #expect(out.map(\.enhancement) == [11, nil])
    }

    @Test("a failed enhancement decode releases its base picture alone")
    func failureReleasesBase() {
        var p = Pairing()
        p.expectEnhancement(key(1))
        #expect(p.addBase(key(1), 10).isEmpty)
        let out = p.enhancementFailed(key(1))
        #expect(out.count == 1 && out[0].enhancement == nil)
    }

    @Test("a partner that never arrives cannot hold the picture past the bound")
    func boundedWait() {
        var p = Pairing(maxWaiting: 3)
        var released: [Int] = []
        for i in 1...4 {
            p.expectEnhancement(key(Int64(i)))
            released += p.addBase(key(Int64(i)), i).map(\.base)
        }
        #expect(released == [1])
        #expect(p.waitingBaseCount == 3)
    }

    // MARK: - Routing

    private func inputs(_ edit: (inout DolbyVisionFELPolicy.Inputs) -> Void = { _ in }) -> DolbyVisionFELPolicy.Inputs {
        var i = DolbyVisionFELPolicy.Inputs(
            dvProfile: 7, enhancementLayerType: "FEL", displayPresentsDolbyVision: true,
            presentsBaseLayerOnly: false, hostAllowsComposition: true, isLive: false,
            sourceIsSeekable: true, samplesAreLengthPrefixed: true, hardwareCanCompose: true)
        edit(&i)
        return i
    }

    @Test("a Profile 7 FEL on a Dolby Vision display with the hardware composes")
    func felComposes() {
        #expect(DolbyVisionFELPolicy.composes(inputs()))
        #expect(DolbyVisionFELPolicy.worthAuditing(inputs()))
    }

    @Test("every missing requirement keeps the single-layer conversion")
    func everyGateHolds() {
        #expect(!DolbyVisionFELPolicy.composes(inputs { $0.enhancementLayerType = "MEL" }))
        #expect(!DolbyVisionFELPolicy.composes(inputs { $0.enhancementLayerType = nil }))
        #expect(!DolbyVisionFELPolicy.composes(inputs { $0.dvProfile = 8 }))
        #expect(!DolbyVisionFELPolicy.composes(inputs { $0.displayPresentsDolbyVision = false }))
        #expect(!DolbyVisionFELPolicy.composes(inputs { $0.presentsBaseLayerOnly = true }))
        #expect(!DolbyVisionFELPolicy.composes(inputs { $0.hostAllowsComposition = false }))
        #expect(!DolbyVisionFELPolicy.composes(inputs { $0.isLive = true }))
        #expect(!DolbyVisionFELPolicy.composes(inputs { $0.sourceIsSeekable = false }))
        #expect(!DolbyVisionFELPolicy.composes(inputs { $0.samplesAreLengthPrefixed = false }))
        #expect(!DolbyVisionFELPolicy.composes(inputs { $0.hardwareCanCompose = false }))
    }

    @Test("the second open is not paid for a source the policy would refuse anyway")
    func auditIsGated() {
        #expect(!DolbyVisionFELPolicy.worthAuditing(inputs { $0.dvProfile = 8 }))
        #expect(!DolbyVisionFELPolicy.worthAuditing(inputs { $0.displayPresentsDolbyVision = false }))
        #expect(!DolbyVisionFELPolicy.worthAuditing(inputs { $0.hostAllowsComposition = false }))
        #expect(!DolbyVisionFELPolicy.worthAuditing(inputs { $0.isLive = true }))
    }

    @Test("dual-layer playback is opt-in, and changing it is refused on a running session, because it picks the host")
    func optionIsLoadIdentity() {
        var proposed = LoadOptions()
        proposed.preferDualLayerDolbyVision = true
        #expect(SessionOptionCorrection.refusedFields(from: LoadOptions(), to: proposed)
                == ["preferDualLayerDolbyVision"])
        #expect(SessionOptionCorrection.loadIdentityFields.contains("preferDualLayerDolbyVision"))
        // Opt-in (AE#702): the single-layer conversion stays the default.
        #expect(!LoadOptions().preferDualLayerDolbyVision)
    }

    // MARK: - Arithmetic

    private static let identity = DolbyVisionComposerParams(
        blBitDepth: 10, elBitDepth: 10, vdrBitDepth: 12, disableResidual: false,
        curves: [.identity, .identity, .identity], nlq: nil)

    @Test("an identity mapping without a residual hands back every base-layer code exactly")
    func identityIsExact() {
        let p = Self.identity
        for code in 0...1023 {
            let x = Double(code) / 1023
            let y = p.predict(component: 0, y: x, cb: 0.5, cr: 0.5)
            for bayer in [0, 17, 63] {
                #expect(DolbyVisionComposerParams.requantize(y, bayer: bayer) == UInt16(code))
            }
        }
    }

    @Test("the 8x8 dither visits every threshold once")
    func bayerIsAPermutation() {
        var seen = Set<Int>()
        for y in 0..<8 { for x in 0..<8 { seen.insert(DolbyVisionComposerParams.bayer8(x: x, y: y)) } }
        #expect(seen == Set(0..<64))
        #expect(DolbyVisionComposerParams.bayer8(x: 9, y: 3) == DolbyVisionComposerParams.bayer8(x: 1, y: 3))
    }

    @Test("dithered requantization keeps the 12-bit level on average instead of truncating it")
    func ditherPreservesLevel() {
        // A 12-bit level a quarter of the way between two 10-bit codes.
        let v12 = 4 * 500 + 1
        let normalised = Double(v12) / DolbyVisionComposerParams.composedScale
        var sum = 0
        for y in 0..<8 {
            for x in 0..<8 {
                sum += Int(DolbyVisionComposerParams.requantize(
                    normalised, bayer: DolbyVisionComposerParams.bayer8(x: x, y: y)))
            }
        }
        let mean = Double(sum) / 64
        #expect(abs(mean - Double(v12) / 4) < 1.0 / 64 + 1e-9)
    }

    /// The integer dequantization `vs-nlq` implements (from ETSI GS CCM 001), on a 16-bit composed
    /// signal, which is what `residual(code:nlq:elBitDepth:)` is a normalised float form of.
    private func vsNLQ(el: Int64, offset: Int64, slopeFP: Int64, thresholdFP: Int64, inMaxFP: Int64,
                       denom: Int64, elBitDepth: Int64) -> Int64 {
        var tmp = el - offset
        if tmp == 0 { return 0 }
        let sign: Int64 = tmp < 0 ? -1 : 1
        tmp <<= 1
        tmp -= sign
        tmp <<= 10 - elBitDepth
        var dq = tmp * slopeFP
        dq += (thresholdFP << (10 - elBitDepth + 1)) * sign
        let rr = inMaxFP << (10 - elBitDepth + 1)
        dq = min(max(dq, -rr), rr)
        return dq >> (denom - 5 - elBitDepth)
    }

    @Test("the NLQ dead zone matches the integer reference across the code range")
    func nlqMatchesReference() {
        let denom: Int64 = 23
        let scale = Double(Int64(1) << denom)
        let cases: [(offset: Int64, slope: Int64, threshold: Int64, inMax: Int64)] = [
            (512, 2_621, 0, 4_194_304),          // slope ~3.1e-4, no threshold, in_max 0.5
            (511, 9_000, 1_500, 838_861),        // a threshold, in_max 0.1 that clips the tails
            (520, 40_000, 0, 8_388_608),         // steep
        ]
        for c in cases {
            let nlq = DolbyVisionComposerParams.NLQ(
                offset: Double(c.offset), inMax: Double(c.inMax) / scale,
                slope: Double(c.slope) / scale, threshold: Double(c.threshold) / scale)
            for code in stride(from: Int64(0), through: 1023, by: 7) {
                let reference = Double(vsNLQ(el: code, offset: c.offset, slopeFP: c.slope,
                                             thresholdFP: c.threshold, inMaxFP: c.inMax,
                                             denom: denom, elBitDepth: 10)) / 65536
                let ours = DolbyVisionComposerParams.residual(code: Double(code), nlq: nlq, elBitDepth: 10)
                // The reference floors to 16-bit; ours does not.
                #expect(abs(ours - reference) <= 1.0 / 65536 + 1e-12, "code \(code) offset \(c.offset)")
            }
        }
    }

    @Test("a polynomial piece is picked on its pivots and clamped to their range")
    func polynomialPieces() {
        var luma = DolbyVisionComposerParams.Curve.identity
        luma.pivots = [0.1, 0.5, 0.9]
        luma.poly = [[0.0, 2.0, 0.0], [0.5, 0.0, 1.0]]
        luma.mmrOrder = [1, 1]
        luma.mmrConstant = [0, 0]
        luma.mmrCoef = [[[Double]]](repeating: [[Double]](repeating: [Double](repeating: 0, count: 7), count: 3), count: 2)
        var p = Self.identity
        p.curves[0] = luma
        #expect(abs(p.predict(component: 0, y: 0.3, cb: 0, cr: 0) - 0.6) < 1e-12)
        #expect(abs(p.predict(component: 0, y: 0.7, cb: 0, cr: 0) - (0.5 + 0.49)) < 1e-12)
        #expect(abs(p.predict(component: 0, y: 0.0, cb: 0, cr: 0) - 0.2) < 1e-12)        // clamped to 0.1
        #expect(abs(p.predict(component: 0, y: 1.0, cb: 0, cr: 0) - (0.5 + 0.81)) < 1e-12) // clamped to 0.9
    }

    @Test("an MMR piece sums its cross terms to the order the piece carries")
    func mmrOrders() {
        var chroma = DolbyVisionComposerParams.Curve.identity
        chroma.isMMR = true
        chroma.mmrConstant = [0.25]
        chroma.mmrOrder = [2]
        var coef = [[Double]](repeating: [Double](repeating: 0, count: 7), count: 3)
        coef[0][1] = 1.0     // cb
        coef[0][3] = 0.5     // y*cb
        coef[1][2] = 2.0     // cr^2
        coef[2][0] = 100     // order 3, not carried by this piece
        chroma.mmrCoef = [coef]
        var p = Self.identity
        p.curves[1] = chroma
        let (y, cb, cr) = (0.6, 0.4, 0.3)
        let expected = 0.25 + cb + 0.5 * y * cb + 2.0 * cr * cr
        #expect(abs(p.predict(component: 1, y: y, cb: cb, cr: cr) - expected) < 1e-12)
    }

    @Test("the packed layout fits Metal's inline argument limit and lands where the kernel reads it")
    func packedLayout() {
        var p = Self.identity
        p.nlq = Array(repeating: .init(offset: 512, inMax: 0.5, slope: 0.001, threshold: 0.002), count: 3)
        let packed = p.packed()
        #expect(packed.count == DolbyVisionComposerParams.packedCount)
        #expect(packed.count * MemoryLayout<Float>.size <= 4096)
        #expect(packed[0] == 1 && packed[1] == 10)
        let cr = DolbyVisionComposerParams.headerFloats + 2 * DolbyVisionComposerParams.componentStride
        #expect(packed[cr + DolbyVisionComposerParams.Offset.numPivots] == 2)
        #expect(packed[cr + DolbyVisionComposerParams.Offset.pivots + 1] == 1)
        #expect(packed[cr + DolbyVisionComposerParams.Offset.poly + 1] == 1)
        #expect(packed[cr + DolbyVisionComposerParams.Offset.nlq] == 512)
        #expect(packed[cr + DolbyVisionComposerParams.Offset.nlq + 3] == Float(0.002))
        // The last NLQ float is inside the component's block.
        #expect(DolbyVisionComposerParams.Offset.nlq + 4 <= DolbyVisionComposerParams.componentStride)
        p.disableResidual = true
        #expect(p.packed()[0] == 0)
    }

    @Test("the kernel source carries the layout the Swift side packs")
    func kernelUsesTheLayout() {
        let source = DolbyVisionFELComposer.kernelSource
        #expect(source.contains("constant int STRIDE = \(DolbyVisionComposerParams.componentStride);"))
        #expect(source.contains("constant int O_NLQ = \(DolbyVisionComposerParams.Offset.nlq);"))
        #expect(source.contains("kernel void doviFELCompose"))
    }

    // MARK: - Why a Profile 7 keeps the conversion (AE#702)

    @Test("the refusal names the first gate a host can act on, and nothing when it composes")
    func refusalReasons() {
        #expect(DolbyVisionFELPolicy.refusal(inputs()) == nil)
        #expect(DolbyVisionFELPolicy.refusal(inputs { $0.hostAllowsComposition = false })?
                    .contains("preferDualLayerDolbyVision") == true)
        #expect(DolbyVisionFELPolicy.refusal(inputs { $0.displayPresentsDolbyVision = false })
                == "the display does not present Dolby Vision")
        #expect(DolbyVisionFELPolicy.refusal(inputs { $0.enhancementLayerType = "MEL" }) == "enhancement layer is MEL")
        #expect(DolbyVisionFELPolicy.refusal(inputs { $0.hardwareCanCompose = false },
                                             hardwareShortfall: "no hardware Dolby Vision decode")
                == "no hardware Dolby Vision decode")
        #expect(DolbyVisionFELPolicy.refusal(inputs { $0.samplesAreLengthPrefixed = false })?
                    .contains("Annex-B") == true)
    }

    @Test("the device shortfall names every missing piece, and nothing when all are there")
    func deviceShortfall() {
        #expect(DolbyVisionFELDecoder.deviceShortfall(hasMetal: true, decodesHEVC: true, decodesDolbyVision: true) == nil)
        #expect(DolbyVisionFELDecoder.deviceShortfall(hasMetal: true, decodesHEVC: true, decodesDolbyVision: false)
                == "no hardware Dolby Vision decode")
        #expect(DolbyVisionFELDecoder.deviceShortfall(hasMetal: false, decodesHEVC: false, decodesDolbyVision: true)
                == "no Metal GPU, no hardware HEVC decode")
    }

    // MARK: - DoViBaker's resampling

    /// A small deterministic plane of 10-bit codes with structure in both directions.
    private func plane(width: Int, height: Int, seed: Int) -> [[Int]] {
        (0..<height).map { y in (0..<width).map { x in (x * 131 + y * 977 + seed * 61 + (x * y) % 17 * 29) % 1024 } }
    }

    @Test("chroma MMR luma is DoViBaker's [1 2 1] across the left-sited column, edges included")
    func mmrLumaMatchesDoViBaker() {
        let rows = plane(width: 10, height: 2, seed: 3)
        let cw = 5
        for cx in 0..<cw {
            let ours = DolbyVisionComposerParams.mmrLuma(
                row0: { rows[0][min(max($0, 0), 9)] }, row1: { rows[1][min(max($0, 0), 9)] },
                chromaColumn: cx, chromaWidth: cw)
            // DoViBaker applyDovi<true>, restated.
            func line(_ y: [Int]) -> Int {
                if cx == 0 { return (3 * y[0] + y[1] + 2) >> 2 }
                if cx == cw - 1 { return (y[2 * cx - 1] + 3 * y[2 * cx] + 2) >> 2 }
                return (y[2 * cx - 1] + 2 * y[2 * cx] + y[2 * cx + 1] + 2) >> 2
            }
            #expect(ours == ((line(rows[0]) + line(rows[1]) + 1) >> 1), "cx \(cx)")
        }
        // A flat plane stays flat.
        #expect(DolbyVisionComposerParams.mmrLuma(row0: { _ in 600 }, row1: { _ in 600 },
                                                  chromaColumn: 2, chromaWidth: 5) == 600)
    }

    /// DoViBaker's `upscaleEl`, restated from its source: `upsampleVert` into a clipped intermediate,
    /// then `upsampleHorz`, indices clamped at the edges, the active (non-"paper") filters.
    private func doViBakerUpscale(_ src: [[Int]], luma: Bool) -> [[Int]] {
        func clip(_ v: Int) -> Int { min(max(v, 0), 0xFFFF) }
        func even(_ y: (Int) -> Int) -> Int {
            luma ? clip((-3 * y(-2) + 29 * y(-1) + 111 * y(0) - 9 * y(1) + 64) >> 7) : y(0)
        }
        func odd(_ y: (Int) -> Int) -> Int {
            luma ? clip((-9 * y(-1) + 111 * y(0) + 29 * y(1) - 3 * y(2) + 64) >> 7)
                 : clip((-307 * y(-1) + 2355 * y(0) + 2355 * y(1) - 307 * y(2) + 2048) >> 12)
        }
        let h = src.count, w = src[0].count
        var mez = [[Int]](repeating: [Int](repeating: 0, count: w), count: 2 * h)
        for r in 0..<h {
            for x in 0..<w {
                let at: (Int) -> Int = { src[min(max(r + $0, 0), h - 1)][x] }
                mez[2 * r][x] = even(at)
                mez[2 * r + 1][x] = odd(at)
            }
        }
        var out = [[Int]](repeating: [Int](repeating: 0, count: 2 * w), count: 2 * h)
        for r in 0..<(2 * h) {
            for c in 0..<w {
                let at: (Int) -> Int = { mez[r][min(max(c + $0, 0), w - 1)] }
                out[r][2 * c] = even(at)
                out[r][2 * c + 1] = odd(at)
            }
        }
        return out
    }

    @Test("a quarter-resolution enhancement layer is upscaled exactly as DoViBaker does", arguments: [true, false])
    func enhancementUpscaleMatchesDoViBaker(luma: Bool) {
        let src = plane(width: 7, height: 5, seed: luma ? 1 : 2)
        let reference = doViBakerUpscale(src, luma: luma)
        for y in 0..<10 {
            for x in 0..<14 {
                let ours = DolbyVisionComposerParams.upsample2x(
                    plane: { src[$1][$0] }, width: 7, height: 5, x: x, y: y, kind: luma ? .luma : .chroma)
                #expect(ours == reference[y][x], "(\(x), \(y))")
            }
        }
    }

    @Test("upscaling a flat layer keeps it flat, so a zero residual stays zero")
    func flatUpscaleIsFlat() {
        for kind in [DolbyVisionComposerParams.UpsampleKind.luma, .chroma] {
            for (x, y) in [(0, 0), (1, 1), (5, 2), (13, 9)] {
                #expect(DolbyVisionComposerParams.upsample2x(
                    plane: { _, _ in 512 }, width: 7, height: 5, x: x, y: y, kind: kind) == 512)
            }
        }
    }

    // MARK: - Dolby Vision attachments

    private func pixelBuffer() -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, nil, &pb)
        return pb
    }

    @Test("the undocumented Dolby Vision keys are carried over in the mode they were attached in")
    func dolbyVisionAttachmentsCarryOver() throws {
        let base = try #require(pixelBuffer())
        let composed = try #require(pixelBuffer())
        let rpu = Data([0x08, 0x09, 0x0A]) as CFData
        CVBufferSetAttachment(base, DolbyVisionUndocumentedKeys.rpuData as CFString, rpu, .shouldNotPropagate)
        CVBufferSetAttachment(base, DolbyVisionUndocumentedKeys.compatibilityID as CFString, NSNumber(value: 1), .shouldPropagate)

        let copied = DolbyVisionFELDecoder.copyDolbyVisionMetadata(from: base, to: composed)
        #expect(copied.count == 2)
        var mode = CVAttachmentMode.shouldPropagate
        let value = CVBufferCopyAttachment(composed, DolbyVisionUndocumentedKeys.rpuData as CFString, &mode)
        #expect((value as? Data) == Data([0x08, 0x09, 0x0A]))
        #expect(mode == .shouldNotPropagate)
        #expect((CVBufferCopyAttachment(composed, DolbyVisionUndocumentedKeys.compatibilityID as CFString, nil) as? NSNumber)?.intValue == 1)
    }

    @Test("a base picture without the keys copies nothing")
    func missingAttachmentsCopyNothing() throws {
        let base = try #require(pixelBuffer())
        let composed = try #require(pixelBuffer())
        #expect(DolbyVisionFELDecoder.copyDolbyVisionMetadata(from: base, to: composed).isEmpty)
        #expect(CVBufferCopyAttachment(composed, DolbyVisionUndocumentedKeys.rpuData as CFString, nil) == nil)
    }

    @Test("the kernel carries DoViBaker's resampling")
    func kernelUsesDoViBakerResampling() {
        let source = DolbyVisionFELComposer.kernelSource
        #expect(source.contains("int4(-3, 29, 111, -9)"))
        #expect(source.contains("int4(-307, 2355, 2355, -307)"))
        #expect(source.contains("inline int mmrLine("))
    }
}
