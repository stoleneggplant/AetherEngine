import Foundation
import CoreVideo
import Metal

/// Reconstructs a Dolby Vision Profile 7 FEL picture on the GPU: the base layer predicts the 12-bit
/// signal through the RPU's reshaping curves, the enhancement layer's residual is dequantized through
/// its NLQ parameters and added, and the sum is requantized to 10 bits with an ordered dither into a
/// P010 (`x420`) buffer that `AVSampleBufferDisplayLayer` presents directly. No re-encode: the buffer
/// is the picture.
///
/// One thread per 2x2 luma block, i.e. per chroma sample. Chroma prediction reads the block's mean
/// luma, which is where a 4:2:0 chroma sample sits. An enhancement layer coarser than the base (a
/// 1080p FEL under a 2160p base) is brought up by dequantizing its four nearest samples and
/// interpolating the residuals bilinearly, so the dead zone around the NLQ offset is never smeared
/// into a step; at equal sizes that is the sample itself.
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

    // Residual at a base-layer position, from an enhancement plane of any size: the four nearest
    // enhancement samples are dequantized and the residuals interpolated.
    inline float residualAt(constant float *P, int c, texture2d<float, access::read> el, int channel,
                            float2 pos, float2 dstSize) {
        float2 elSize = float2(el.get_width(), el.get_height());
        float2 e = (pos + 0.5) * elSize / dstSize - 0.5;
        float2 f = e - floor(e);
        int2 i0 = int2(floor(e));
        int2 maxI = int2(elSize) - 1;
        int2 a = clamp(i0, int2(0), maxI);
        int2 b = clamp(i0 + int2(1, 0), int2(0), maxI);
        int2 cc = clamp(i0 + int2(0, 1), int2(0), maxI);
        int2 d = clamp(i0 + int2(1, 1), int2(0), maxI);
        float r00 = residual(P, c, el.read(uint2(a))[channel] * CODE);
        float r10 = residual(P, c, el.read(uint2(b))[channel] * CODE);
        float r01 = residual(P, c, el.read(uint2(cc))[channel] * CODE);
        float r11 = residual(P, c, el.read(uint2(d))[channel] * CODE);
        return mix(mix(r00, r10, f.x), mix(r01, r11, f.x), f.y);
    }

    kernel void doviFELCompose(texture2d<float, access::read> blY [[texture(0)]],
                               texture2d<float, access::read> blC [[texture(1)]],
                               texture2d<float, access::read> elY [[texture(2)]],
                               texture2d<float, access::read> elC [[texture(3)]],
                               texture2d<float, access::write> outY [[texture(4)]],
                               texture2d<float, access::write> outC [[texture(5)]],
                               constant float *P [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]]) {
        uint cw = outC.get_width();
        uint ch = outC.get_height();
        if (gid.x >= cw || gid.y >= ch) { return; }
        uint w = outY.get_width();
        uint h = outY.get_height();
        bool addResidual = P[0] > 0.5;

        float2 cbcr = blC.read(gid).rg * CODE / BL_MAX;
        float ys[4];
        uint2 lp[4];
        float ysum = 0.0;
        for (int i = 0; i < 4; i++) {
            lp[i] = uint2(min(gid.x * 2 + uint(i & 1), w - 1), min(gid.y * 2 + uint(i >> 1), h - 1));
            ys[i] = blY.read(lp[i]).r * CODE / BL_MAX;
            ysum += ys[i];
        }
        float ymean = ysum * 0.25;

        float2 cDst = float2(cw, ch);
        float cb = predict(P, 1, ymean, cbcr.x, cbcr.y);
        float cr = predict(P, 2, ymean, cbcr.x, cbcr.y);
        if (addResidual) {
            cb += residualAt(P, 1, elC, 0, float2(gid), cDst);
            cr += residualAt(P, 2, elC, 1, float2(gid), cDst);
        }
        // The chroma plane's dither pattern is shifted off the luma one so the two do not correlate.
        uint2 cp = gid + uint2(3, 5);
        outC.write(float4(requantize(cb, cp), requantize(cr, cp), 0.0, 1.0), gid);

        float2 yDst = float2(w, h);
        for (int i = 0; i < 4; i++) {
            float y = predict(P, 0, ys[i], cbcr.x, cbcr.y);
            if (addResidual) {
                y += residualAt(P, 0, elY, 0, float2(lp[i]), yDst);
            }
            outY.write(float4(requantize(y, lp[i]), 0.0, 0.0, 1.0), lp[i]);
        }
    }
    """
}
