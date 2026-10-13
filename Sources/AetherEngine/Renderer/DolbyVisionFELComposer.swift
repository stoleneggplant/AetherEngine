import Foundation
import CoreVideo
import Metal

/// Reconstructs a Dolby Vision Profile 7 FEL picture on the GPU: the base layer predicts the 12-bit
/// signal through the RPU's reshaping curves, the enhancement layer's residual is dequantized through
/// its NLQ parameters and added, and the sum is requantized to 10 bits with an ordered dither into a
/// P010 (`x420`) buffer that `AVSampleBufferDisplayLayer` presents directly. No re-encode: the buffer
/// is the picture.
///
/// One thread per 2x2 luma block, i.e. per chroma sample: the composition runs at 4:2:0, which is what
/// every Profile 7 RPU declares (`mapping_chroma_format_idc` 0, DM `signal_chroma_format` 0) and what
/// DoViBaker composes at. The resampling follows DoViBaker (AE#702): chroma prediction reads luma
/// through a [1 2 1] filter across the left-sited luma column, and a quarter-resolution enhancement
/// layer is brought to size by its separable 2x upscale (a 4-tap luma filter, copy / spline16 for
/// chroma) BEFORE the NLQ dequantization, in integer codes with its rounding.
final class DolbyVisionFELComposer: @unchecked Sendable {

    /// The composed buffers' pixel format: 10-bit 4:2:0 biplanar, video range, the format VideoToolbox
    /// decodes both layers into and the one the display layer takes HDR in.
    static let outputPixelFormat: OSType = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    private var pool: CVPixelBufferPool?
    private var poolSize: (width: Int, height: Int) = (0, 0)
    private let lock = NSLock()

    /// nil when the device has no Metal GPU or the kernel does not build; the caller keeps the base
    /// layer alone, which is the single-layer conversion's picture.
    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: Self.kernelSource, options: nil)
            guard let function = library.makeFunction(name: "doviFELCompose") else { return nil }
            pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            EngineLog.emit("[DVFEL] composer kernel failed to build: \(error)", category: .swPlayback)
            return nil
        }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        self.device = device
        self.queue = queue
        self.textureCache = cache
    }

    /// Whether this device can run the composer at all, without building it.
    static var deviceHasMetal: Bool { MTLCreateSystemDefaultDevice() != nil }

    /// Compose one frame. `enhancement` nil (or `params[0] == 0`) composes the prediction alone.
    /// Returns nil on any GPU or allocation failure; the caller then presents the base layer.
    func compose(base: CVPixelBuffer, enhancement: CVPixelBuffer?, params: [Float]) -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        guard CVPixelBufferGetPlaneCount(base) == 2,
              params.count == DolbyVisionComposerParams.packedCount else { return nil }
        let width = CVPixelBufferGetWidth(base)
        let height = CVPixelBufferGetHeight(base)
        guard width >= 2, height >= 2, let output = makeOutputBuffer(width: width, height: height) else { return nil }

        let el = enhancement.flatMap { CVPixelBufferGetPlaneCount($0) == 2 ? $0 : nil }
        guard let blY = texture(base, plane: 0, format: .r16Unorm),
              let blC = texture(base, plane: 1, format: .rg16Unorm),
              let outY = texture(output, plane: 0, format: .r16Unorm),
              let outC = texture(output, plane: 1, format: .rg16Unorm) else { return nil }
        let elY = el.flatMap { texture($0, plane: 0, format: .r16Unorm) } ?? blY
        let elC = el.flatMap { texture($0, plane: 1, format: .rg16Unorm) } ?? blC

        var packed = params
        if el == nil { packed[0] = 0 }

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder(),
              let tBLY = CVMetalTextureGetTexture(blY), let tBLC = CVMetalTextureGetTexture(blC),
              let tELY = CVMetalTextureGetTexture(elY), let tELC = CVMetalTextureGetTexture(elC),
              let tOutY = CVMetalTextureGetTexture(outY), let tOutC = CVMetalTextureGetTexture(outC) else {
            return nil
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(tBLY, index: 0)
        encoder.setTexture(tBLC, index: 1)
        encoder.setTexture(tELY, index: 2)
        encoder.setTexture(tELC, index: 3)
        encoder.setTexture(tOutY, index: 4)
        encoder.setTexture(tOutC, index: 5)
        packed.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                encoder.setBytes(base, length: raw.count, index: 0)
            }
        }
        let group = MTLSize(width: 16, height: 16, depth: 1)
        let chromaW = tOutC.width, chromaH = tOutC.height
        let groups = MTLSize(width: (chromaW + 15) / 16, height: (chromaH + 15) / 16, depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: group)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        // The CVMetalTextures (and the buffers under them) are held by the locals above until here.
        withExtendedLifetime((blY, blC, elY, elC, outY, outC)) {}
        CVMetalTextureCacheFlush(textureCache, 0)
        guard commandBuffer.status == .completed else {
            EngineLog.emit("[DVFEL] compose command buffer failed: \(String(describing: commandBuffer.error))",
                           category: .swPlayback)
            return nil
        }
        return output
    }

    private func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        let attrs: NSDictionary = [
            kCVMetalTextureUsage: NSNumber(value: MTLTextureUsage([.shaderRead, .shaderWrite]).rawValue),
        ]
        var out: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, attrs as CFDictionary, format,
            CVPixelBufferGetWidthOfPlane(buffer, plane), CVPixelBufferGetHeightOfPlane(buffer, plane),
            plane, &out)
        return status == kCVReturnSuccess ? out : nil
    }

    private func makeOutputBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolSize.width != width || poolSize.height != height {
            let attrs: NSDictionary = [
                kCVPixelBufferPixelFormatTypeKey: Self.outputPixelFormat,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            var created: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &created) == kCVReturnSuccess,
                  let created else { return nil }
            pool = created
            poolSize = (width, height)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess else {
            return nil
        }
        return buffer
    }

    // MARK: - Kernel

    /// Mirrors `DolbyVisionComposerParams.predict`, `.residual`, `.requantize` and `.bayer8` line for line;
    /// the offsets are `DolbyVisionComposerParams.Offset`.
    static let kernelSource = """
    #include <metal_stdlib>
    using namespace metal;

    constant int HEADER = \(DolbyVisionComposerParams.headerFloats);
    constant int STRIDE = \(DolbyVisionComposerParams.componentStride);
    constant int O_NUM_PIVOTS = \(DolbyVisionComposerParams.Offset.numPivots);
    constant int O_IS_MMR = \(DolbyVisionComposerParams.Offset.isMMR);
    constant int O_PIVOTS = \(DolbyVisionComposerParams.Offset.pivots);
    constant int O_MMR_ORDER = \(DolbyVisionComposerParams.Offset.mmrOrder);
    constant int O_MMR_CONST = \(DolbyVisionComposerParams.Offset.mmrConstant);
    constant int O_POLY = \(DolbyVisionComposerParams.Offset.poly);
    constant int O_MMR_COEF = \(DolbyVisionComposerParams.Offset.mmrCoef);
    constant int O_NLQ = \(DolbyVisionComposerParams.Offset.nlq);
    // P010 stores a 10-bit code in the top bits of 16: unorm * 65535 / 64 is the code.
    constant float CODE = 65535.0 / 64.0;
    constant float BL_MAX = 1023.0;
    constant float COMPOSED_SCALE = \(DolbyVisionComposerParams.composedScale);

    inline float predict(constant float *P, int c, float y, float cb, float cr) {
        constant float *C = P + HEADER + c * STRIDE;
        int n = int(C[O_NUM_PIVOTS]);
        float input = c == 0 ? y : (c == 1 ? cb : cr);
        if (n < 2) { return input; }
        float x = clamp(input, C[O_PIVOTS], C[O_PIVOTS + n - 1]);
        int seg = 0;
        while (seg < n - 2 && x >= C[O_PIVOTS + seg + 1]) { seg += 1; }
        if (C[O_IS_MMR] > 0.5) {
            float base[7] = { y, cb, cr, y * cb, y * cr, cb * cr, y * cb * cr };
            float t[7] = { base[0], base[1], base[2], base[3], base[4], base[5], base[6] };
            float s = C[O_MMR_CONST + seg];
            int order = clamp(int(C[O_MMR_ORDER + seg]), 1, 3);
            for (int o = 0; o < order; o++) {
                for (int k = 0; k < 7; k++) { s += C[O_MMR_COEF + seg * 21 + o * 7 + k] * t[k]; }
                for (int k = 0; k < 7; k++) { t[k] *= base[k]; }
            }
            return s;
        }
        constant float *p = C + O_POLY + seg * 3;
        return p[0] + x * (p[1] + x * p[2]);
    }

    inline float residual(constant float *P, int c, float code) {
        constant float *N = P + HEADER + c * STRIDE + O_NLQ;
        float t = code - N[0];
        float a = fabs(t);
        if (a < 1e-3) { return 0.0; }
        float half_step = exp2(P[1] - 11.0);
        float r = min((a - half_step) * N[2] + N[3], N[1]);
        return t < 0.0 ? -r : r;
    }

    inline uint bayer8(uint2 p) {
        uint u = p.x & 7u;
        uint v = (p.x ^ p.y) & 7u;
        return ((v & 1u) << 5) | ((u & 1u) << 4) | ((v & 2u) << 2) | ((u & 2u) << 1) | ((v & 4u) >> 1) | ((u & 4u) >> 2);
    }

    inline float requantize(float normalised, uint2 p) {
        float v12 = rint(clamp(normalised, 0.0, 1.0) * COMPOSED_SCALE);
        float d = (float(bayer8(p)) + 0.5) / 16.0;
        float v10 = clamp(floor((v12 + d) / 4.0), 0.0, 1023.0);
        return v10 * 64.0 / 65535.0;
    }

    // A 10-bit code from a P010 plane, read at a clamped position.
    inline int codeAt(texture2d<float, access::read> t, int channel, int x, int y) {
        int2 limit = int2(t.get_width(), t.get_height()) - 1;
        return int(rint(t.read(uint2(clamp(int2(x, y), int2(0), limit)))[channel] * CODE));
    }

    // DolbyVisionComposerParams.taps: one 2x step of DoViBaker's enhancement-layer upscaling.
    struct Taps { int start; int4 w; int shift; int round_; };
    inline Taps tapsFor(bool luma, bool odd) {
        Taps t;
        if (luma) {
            t.start = odd ? -1 : -2;
            t.w = odd ? int4(-9, 111, 29, -3) : int4(-3, 29, 111, -9);
            t.shift = 7; t.round_ = 64;
        } else if (odd) {
            t.start = -1; t.w = int4(-307, 2355, 2355, -307); t.shift = 12; t.round_ = 2048;
        } else {
            t.start = 0; t.w = int4(1, 0, 0, 0); t.shift = 0; t.round_ = 0;
        }
        return t;
    }

    // Vertical pass at one enhancement column, rounded and clipped like DoViBaker's intermediate frame.
    inline int upVertical(texture2d<float, access::read> el, int channel, int col, int outY, bool luma) {
        Taps t = tapsFor(luma, (outY & 1) != 0);
        int m = outY >> 1;
        int acc = t.round_;
        for (int k = 0; k < 4; k++) { acc += t.w[k] * codeAt(el, channel, col, m + t.start + k); }
        return clamp(acc >> t.shift, 0, 65535);
    }

    // DolbyVisionComposerParams.upsample2x(plane:...): vertical first, then horizontal.
    inline int upsampled(texture2d<float, access::read> el, int channel, int outX, int outY, bool luma) {
        Taps t = tapsFor(luma, (outX & 1) != 0);
        int m = outX >> 1;
        int lastCol = int(el.get_width()) - 1;
        int acc = t.round_;
        for (int k = 0; k < 4; k++) {
            int col = clamp(m + t.start + k, 0, lastCol);
            acc += t.w[k] * upVertical(el, channel, col, outY, luma);
        }
        return clamp(acc >> t.shift, 0, 65535);
    }

    // The enhancement-layer code at an output position: DoViBaker's 2x upscale for a quarter-resolution
    // layer, the sample itself at equal size, the nearest sample for any other ratio.
    inline int enhancementCode(texture2d<float, access::read> el, int channel, int2 p, int2 dst, bool luma) {
        int2 es = int2(el.get_width(), el.get_height());
        if (all(es * 2 == dst)) { return upsampled(el, channel, p.x, p.y, luma); }
        if (all(es == dst)) { return codeAt(el, channel, p.x, p.y); }
        return codeAt(el, channel, p.x * es.x / dst.x, p.y * es.y / dst.y);
    }

    // DolbyVisionComposerParams.mmrLuma: [1 2 1] across the left-sited luma column of one row.
    inline int mmrLine(texture2d<float, access::read> blY, int row, int cx, int cw) {
        if (cx == 0) { return (3 * codeAt(blY, 0, 0, row) + codeAt(blY, 0, 1, row) + 2) >> 2; }
        if (cx == cw - 1) {
            return (codeAt(blY, 0, 2 * cx - 1, row) + 3 * codeAt(blY, 0, 2 * cx, row) + 2) >> 2;
        }
        return (codeAt(blY, 0, 2 * cx - 1, row) + 2 * codeAt(blY, 0, 2 * cx, row)
                + codeAt(blY, 0, 2 * cx + 1, row) + 2) >> 2;
    }

    kernel void doviFELCompose(texture2d<float, access::read> blY [[texture(0)]],
                               texture2d<float, access::read> blC [[texture(1)]],
                               texture2d<float, access::read> elY [[texture(2)]],
                               texture2d<float, access::read> elC [[texture(3)]],
                               texture2d<float, access::write> outY [[texture(4)]],
                               texture2d<float, access::write> outC [[texture(5)]],
                               constant float *P [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]]) {
        int cw = int(outC.get_width());
        int ch = int(outC.get_height());
        int cx = int(gid.x), cy = int(gid.y);
        if (cx >= cw || cy >= ch) { return; }
        int w = int(outY.get_width());
        int h = int(outY.get_height());
        bool addResidual = P[0] > 0.5;

        float cb0 = float(codeAt(blC, 0, cx, cy)) / BL_MAX;
        float cr0 = float(codeAt(blC, 1, cx, cy)) / BL_MAX;
        int row0 = min(2 * cy, h - 1);
        int row1 = min(2 * cy + 1, h - 1);
        float mmrY = float((mmrLine(blY, row0, cx, cw) + mmrLine(blY, row1, cx, cw) + 1) >> 1) / BL_MAX;

        int2 cDst = int2(cw, ch);
        float cb = predict(P, 1, mmrY, cb0, cr0);
        float cr = predict(P, 2, mmrY, cb0, cr0);
        if (addResidual) {
            cb += residual(P, 1, float(enhancementCode(elC, 0, int2(cx, cy), cDst, false)));
            cr += residual(P, 2, float(enhancementCode(elC, 1, int2(cx, cy), cDst, false)));
        }
        // The chroma plane's dither pattern is shifted off the luma one so the two do not correlate.
        uint2 cp = gid + uint2(3, 5);
        outC.write(float4(requantize(cb, cp), requantize(cr, cp), 0.0, 1.0), gid);

        int2 yDst = int2(w, h);
        for (int i = 0; i < 4; i++) {
            int2 lp = int2(min(2 * cx + (i & 1), w - 1), min(2 * cy + (i >> 1), h - 1));
            float ys = float(codeAt(blY, 0, lp.x, lp.y)) / BL_MAX;
            float y = predict(P, 0, ys, cb0, cr0);
            if (addResidual) {
                y += residual(P, 0, float(enhancementCode(elY, 0, lp, yDst, true)));
            }
            outY.write(float4(requantize(y, uint2(lp)), 0.0, 0.0, 1.0), uint2(lp));
        }
    }
    """
}
