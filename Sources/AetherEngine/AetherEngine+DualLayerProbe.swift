import Foundation
import CoreMedia
import CoreVideo
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

/// Result of `AetherEngine.dualLayerDolbyVisionProbe`, the offline harness of the dual-layer Profile 7
/// FEL path (`aetherctl felcompose`).
public struct DualLayerDolbyVisionProbeResult: Sendable {
    /// Dolby Vision profile from the container record; nil when the source carries none.
    public let dvProfile: Int?
    /// "FEL" / "MEL" from the first RPU, nil when no Profile 7 RPU could be read.
    public let enhancementLayerType: String?
    /// What the device lacks for the route (`no Metal GPU`, `no hardware Dolby Vision decode`, ...), nil
    /// when it has it all. The probe composes regardless, as far as the device allows: on a Mac the
    /// Dolby Vision decode check typically fails while the composition itself still runs.
    public let deviceShortfall: String?
    /// Whether the Metal composer was built. Without it every frame is the base picture alone.
    public let composerAvailable: Bool
    /// Whether the enhancement layer was dropped on purpose (`residual: false`), the A/B leg.
    public let residualApplied: Bool
    public let baseWidth: Int
    public let baseHeight: Int
    /// The enhancement layer's coded size as decoded; 0 when no enhancement picture reached the composer.
    public let enhancementWidth: Int
    public let enhancementHeight: Int
    public let videoPacketsFed: Int
    public let framesDelivered: Int
    /// Frames the Metal kernel produced, with and without an enhancement picture.
    public let framesComposed: Int
    public let framesComposedWithEnhancement: Int
    /// Frames delivered as the decoded base picture, uncomposed.
    public let framesBaseOnly: Int
    /// Per undocumented Dolby Vision key (`DolbyVisionRPUData`, `DolbyCompatibilityID`): whether the
    /// first delivered frame carried it. Absent keys mean the panel would get no per-frame Dolby Vision.
    public let dolbyVisionAttachments: [String: Bool]
    /// The first delivered frame's pixel format as a FourCC, e.g. `x420`.
    public let pixelFormat: String?
    /// Raw frames written, `yuv420p10le`, one file each.
    public let dumpedFiles: [String]
}

extension AetherEngine {

    /// TEST-ONLY harness for the dual-layer Dolby Vision Profile 7 FEL path, behind `aetherctl felcompose`.
    /// Runs the same decoder the software host uses (`DolbyVisionFELDecoder`: both layers on VideoToolbox,
    /// paired by presentation time, composed in Metal) over the first `frames` pictures of `url`, or from
    /// `startSeconds`, with no display and none of the routing gates, and reports what came out:
    /// how many frames composed with an enhancement picture, the layers' sizes, and whether the delivered
    /// frames carry the Dolby Vision attachments the display layer reads.
    ///
    /// `dumpDirectory` writes the first `dumpFrames` delivered pictures as raw `yuv420p10le`, one file
    /// each, for `ffmpeg -f rawvideo -pix_fmt yuv420p10le -s WxH -i frame.yuv` or a byte diff against
    /// DoViBaker. `residual: false` composes the prediction alone, so a second run's dump differs from
    /// the first by exactly the residual the enhancement layer adds.
    public nonisolated static func dualLayerDolbyVisionProbe(
        url: URL,
        frames: Int = 48,
        startSeconds: Double? = nil,
        residual: Bool = true,
        dumpDirectory: URL? = nil,
        dumpFrames: Int = 3,
        options: LoadOptions = .init()
    ) throws -> DualLayerDolbyVisionProbeResult {
        let elType = DolbyVisionRecordAudit.enhancementLayerTypeOfSource(url: url, extraHeaders: options.httpHeaders)

        let demuxer = Demuxer()
        try demuxer.open(url: url, extraHeaders: options.httpHeaders)
        defer { demuxer.close() }
        let videoIdx = demuxer.videoStreamIndex
        guard videoIdx >= 0, let stream = demuxer.stream(at: videoIdx) else {
            throw AetherEngineError.noVideoStream
        }
        if let startSeconds, startSeconds > 0 { _ = demuxer.seek(to: startSeconds) }

        final class Accum: @unchecked Sendable {
            let lock = NSLock()
            var delivered = 0
            var attachments: [String: Bool] = [:]
            var pixelFormat: String?
            var dumped: [String] = []
        }
        let accum = Accum()
        let wanted = max(1, frames)
        let dumpLimit = dumpDirectory == nil ? 0 : max(0, dumpFrames)
        if let dumpDirectory {
            try FileManager.default.createDirectory(at: dumpDirectory, withIntermediateDirectories: true)
        }

        let decoder = DolbyVisionFELDecoder(appliesResidual: residual)
        defer { decoder.close() }
        try decoder.open(stream: stream) { pixelBuffer, pts, _ in
            accum.lock.lock()
            let index = accum.delivered
            accum.delivered += 1
            if index == 0 {
                var found: [String: Bool] = [:]
                for key in DolbyVisionUndocumentedKeys.perFrameMetadata {
                    found[key] = CVBufferCopyAttachment(pixelBuffer, key as CFString, nil) != nil
                }
                accum.attachments = found
                accum.pixelFormat = DecodedVideoFormat.fourCC(CVPixelBufferGetPixelFormatType(pixelBuffer))
            }
            accum.lock.unlock()
            guard index < dumpLimit, let dumpDirectory else { return }
            let name = String(format: "frame_%04d_%.3fs.yuv", index, pts.seconds)
            let file = dumpDirectory.appendingPathComponent(name)
            if Self.writeYUV420P10LE(pixelBuffer, to: file) {
                accum.lock.lock()
                accum.dumped.append(file.path)
                accum.lock.unlock()
            }
        }

        var fed = 0
        let packetCap = wanted * 8 + 240
        var readSinceFed = 0
        while fed < packetCap {
            accum.lock.lock()
            let enough = accum.delivered >= wanted
            accum.lock.unlock()
            if enough { break }
            guard let packet = try demuxer.readPacket() else { break }
            defer {
                av_packet_unref(packet)
                av_packet_free_safe(packet)
            }
            guard packet.pointee.stream_index == videoIdx else {
                readSinceFed += 1
                if readSinceFed > 4096 { break }
                continue
            }
            readSinceFed = 0
            decoder.decode(packet: packet, epoch: nil)
            fed += 1
        }
        decoder.finishDelivering()
        let stats = decoder.statistics

        let codecpar = stream.pointee.codecpar
        accum.lock.lock()
        defer { accum.lock.unlock() }
        return DualLayerDolbyVisionProbeResult(
            dvProfile: Self.dvProfile(stream: stream),
            enhancementLayerType: elType,
            deviceShortfall: DolbyVisionFELDecoder.deviceShortfall(),
            composerAvailable: stats.hasComposer,
            residualApplied: residual,
            baseWidth: Int(codecpar?.pointee.width ?? 0),
            baseHeight: Int(codecpar?.pointee.height ?? 0),
            enhancementWidth: stats.enhancementWidth,
            enhancementHeight: stats.enhancementHeight,
            videoPacketsFed: fed,
            framesDelivered: accum.delivered,
            framesComposed: stats.composed,
            framesComposedWithEnhancement: stats.withEnhancement,
            framesBaseOnly: stats.baseOnly,
            dolbyVisionAttachments: accum.attachments,
            pixelFormat: accum.pixelFormat,
            dumpedFiles: accum.dumped)
    }

    /// One P010 / x420 picture as planar `yuv420p10le`: the 10-bit codes (P010 keeps them in the top
    /// bits of 16) in a Y plane, then U, then V, little-endian 16-bit samples. False on any other
    /// layout or a write error.
    nonisolated static func writeYUV420P10LE(_ buffer: CVPixelBuffer, to file: URL) -> Bool {
        guard CVPixelBufferGetPlaneCount(buffer) == 2,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let cw = CVPixelBufferGetWidthOfPlane(buffer, 1)
        let ch = CVPixelBufferGetHeightOfPlane(buffer, 1)
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return false }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)

        var out = [UInt16]()
        out.reserveCapacity(width * height + 2 * cw * ch)
        for row in 0..<height {
            let line = (yBase + row * yStride).assumingMemoryBound(to: UInt16.self)
            for x in 0..<width { out.append((line[x] >> 6).littleEndian) }
        }
        for plane in 0..<2 {
            for row in 0..<ch {
                let line = (cBase + row * cStride).assumingMemoryBound(to: UInt16.self)
                for x in 0..<cw { out.append((line[2 * x + plane] >> 6).littleEndian) }
            }
        }
        let data = out.withUnsafeBufferPointer { Data(buffer: $0) }
        return (try? data.write(to: file)) != nil
    }
}
