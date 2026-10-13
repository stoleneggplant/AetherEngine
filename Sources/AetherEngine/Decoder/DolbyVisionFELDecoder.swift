import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

/// Dual-layer Dolby Vision Profile 7 FEL decode for the software host: both layers decoded by
/// VideoToolbox, paired by presentation time, composed on the GPU (`DolbyVisionFELComposer`) and handed
/// on as P010 pixel buffers carrying per-frame Profile 8.1 Dolby Vision metadata, so the display layer
/// and the system's display management present them as Dolby Vision.
///
/// How the metadata gets there: the base layer is decoded as the single-layer Profile 8.1 stream the
/// native path already serves (each access unit through `DoviRpuConverter`, the format description
/// carrying a Profile 8.1 `dvvC`), with `PropagatePerFrameHDRDisplayMetadata` on. VideoToolbox then
/// attaches the frame's Dolby Vision metadata to the base picture as the undocumented
/// `DolbyVisionUndocumentedKeys`, and the composed buffer takes those by name, in the mode they were
/// attached in, with the rest of the base picture's propagatable attachments. The engine never builds
/// the values. The converted RPU's mapping is the identity, which is correct for the composed picture:
/// it already IS the mapped signal.
///
/// Degrades rather than fails. No composer (no Metal, kernel did not build), an RPU the kernel does not
/// implement, a missing or failed enhancement picture, a GPU error: the base picture goes out as it is,
/// which is the single-layer Profile 8.1 picture the engine showed before this path existed. A session
/// this decoder cannot open at all is the host's to fall back on (`SoftwarePlaybackHost.load`).
final class DolbyVisionFELDecoder: VideoDecodingPipeline, @unchecked Sendable {

    // MARK: - VideoDecodingPipeline

    var onFrame: DecodedFrameHandler? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _onFrame }
        set { stateLock.lock(); _onFrame = newValue; stateLock.unlock() }
    }
    private var _onFrame: DecodedFrameHandler?
    var onFirstHDR10PlusDetected: (@Sendable () -> Void)?
    var onA53Captions: (@Sendable ([CCDataParser.CCTriplet], Double) -> Void)?
    var onDecodedFormat: (@Sendable (DecodedVideoFormat) -> Void)?

    var skipUntilPTS: CMTime? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _skipUntilPTS }
        set { stateLock.lock(); _skipUntilPTS = newValue; stateLock.unlock() }
    }
    private var _skipUntilPTS: CMTime?

    var feedEpoch: UInt64 {
        lock.lock(); defer { lock.unlock() }; return _feedEpoch
    }
    private var _feedEpoch: UInt64 = 0

    // MARK: - State

    typealias Key = DolbyVisionFramePairing<CVPixelBuffer>.Key

    /// Guards the sessions, the formats and the feed epoch. Never taken from a VT callback.
    private let lock = NSLock()
    /// Guards the pairing, the per-frame parameters and the small callback-visible state. Taken from
    /// both VT callbacks; never held across a VT or GPU call.
    private let stateLock = NSLock()

    private var baseSession: VTDecompressionSession?
    private var baseFormat: CMVideoFormatDescription?
    private var enhancementSession: VTDecompressionSession?
    private var enhancementFormat: CMVideoFormatDescription?
    private var enhancementParameterSets: DolbyVisionEnhancementLayer.ParameterSets?

    private var pairing = DolbyVisionFramePairing<CVPixelBuffer>()
    private var paramsByKey: [Key: [Float]] = [:]
    private var paramsOrder: [Key] = []
    /// True while `flush()` drains VideoToolbox: pictures that arrive then are from before the seek.
    private var draining = false
    /// Bumped by `flush()`; a compose job queued before it is dropped.
    private var deliveryGeneration: UInt64 = 0

    private let composer: DolbyVisionFELComposer?
    private let composeQueue = DispatchQueue(label: "aether.dv.fel.compose", qos: .userInteractive)

    private var timeBase = AVRational(num: 1, den: 90000)
    private var framing: VideoNALFraming = .lengthPrefixed(size: 4)
    private var streamColor = ColorDescription.unspecified
    private var pixelAspectRatio: AVRational?
    private var reportedFormat = false
    private var loggedFirstComposition = false
    private var loggedMetadataPresence = false
    private var composedCount = 0
    private var baseOnlyCount = 0

    private var baseBox: Unmanaged<RefConBox>?
    private var enhancementBox: Unmanaged<RefConBox>?

    fileprivate final class RefConBox {
        weak var decoder: DolbyVisionFELDecoder?
        let isBase: Bool
        init(_ decoder: DolbyVisionFELDecoder, isBase: Bool) {
            self.decoder = decoder
            self.isBase = isBase
        }
    }

    init(composer: DolbyVisionFELComposer? = DolbyVisionFELComposer()) {
        self.composer = composer
    }

    /// What this device lacks for the path, or nil when it has it all: a Metal GPU for the composer,
    /// hardware HEVC decode for the enhancement layer, and hardware Dolby Vision HEVC decode for the base
    /// layer, which is what attaches the per-frame metadata the display layer presents with. Whether the
    /// display presents Dolby Vision is the routing's question, not this one.
    static func deviceShortfall(
        hasMetal: Bool = DolbyVisionFELComposer.deviceHasMetal,
        decodesHEVC: Bool = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
        decodesDolbyVision: Bool = VTIsHardwareDecodeSupported(kCMVideoCodecType_DolbyVisionHEVC)
    ) -> String? {
        var missing: [String] = []
        if !hasMetal { missing.append("no Metal GPU") }
        if !decodesHEVC { missing.append("no hardware HEVC decode") }
        if !decodesDolbyVision { missing.append("no hardware Dolby Vision decode") }
        return missing.isEmpty ? nil : missing.joined(separator: ", ")
    }

    // MARK: - Lifecycle

    func open(stream: UnsafeMutablePointer<AVStream>, onFrame: @escaping DecodedFrameHandler) throws {
        self.onFrame = onFrame
        guard let codecpar = stream.pointee.codecpar else { throw VideoDecoderError.noCodecParameters }
        guard codecpar.pointee.codec_id == AV_CODEC_ID_HEVC else {
            throw VideoDecoderError.unsupportedCodec(id: codecpar.pointee.codec_id.rawValue)
        }
        guard let extradata = codecpar.pointee.extradata, codecpar.pointee.extradata_size > 0 else {
            throw VideoDecoderError.noExtradata
        }
        timeBase = stream.pointee.time_base
        framing = A53SEIParser.nalFraming(
            codec: .hevc, extradata: extradata, size: Int(codecpar.pointee.extradata_size))
        streamColor = ColorDescription(codecpar: codecpar)
        pixelAspectRatio = PixelAspectPolicy.declaredPixelAspect(
            bitstream: codecpar.pointee.sample_aspect_ratio,
            container: stream.pointee.sample_aspect_ratio,
            width: codecpar.pointee.width, height: codecpar.pointee.height)

        let level = Self.dolbyVisionLevel(codecpar: codecpar) ?? 6
        let atoms: NSDictionary = [
            "hvcC": Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size)),
            "dvvC": Data(DolbyVisionEnhancementLayer.profile81ConfigurationRecord(level: level)),
        ]
        let extensions: NSDictionary = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms]
        let width = codecpar.pointee.width, height = codecpar.pointee.height

        // `dvh1` first: that is what makes VideoToolbox read the stream as Dolby Vision. A decoder that
        // refuses it still decodes the base layer as `hvc1`, with the `dvvC` next to it.
        var lastStatus: OSStatus = noErr
        for codecType in [kCMVideoCodecType_DolbyVisionHEVC, kCMVideoCodecType_HEVC] {
            var fd: CMVideoFormatDescription?
            lastStatus = CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, codecType: codecType, width: width, height: height,
                extensions: extensions, formatDescriptionOut: &fd)
            guard lastStatus == noErr, let fd else { continue }
            do {
                let (session, box) = try makeSession(format: fd, isBase: true)
                lock.lock()
                baseSession = session
                baseFormat = fd
                lock.unlock()
                baseBox = box
                EngineLog.emit(
                    "[DVFEL] base layer session open as \(DecodedVideoFormat.fourCC(codecType)) "
                    + "\(width)x\(height), Profile 8.1 level \(level); composer "
                    + (composer == nil ? "UNAVAILABLE (base layer alone)" : "ready"),
                    category: .swPlayback)
                return
            } catch let VideoDecoderError.sessionCreationFailed(status) {
                lastStatus = status
            }
        }
        throw VideoDecoderError.sessionCreationFailed(status: lastStatus)
    }

    private func makeSession(format: CMVideoFormatDescription, isBase: Bool) throws
        -> (VTDecompressionSession, Unmanaged<RefConBox>) {
        let spec: NSDictionary = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true]
        let attrs: NSDictionary = [
            kCVPixelBufferPixelFormatTypeKey: DolbyVisionFELComposer.outputPixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let box = Unmanaged.passRetained(RefConBox(self, isBase: isBase))
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: felDecoderOutputCallback,
            decompressionOutputRefCon: box.toOpaque())
        var out: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: spec, imageBufferAttributes: attrs,
            outputCallback: &callback, decompressionSessionOut: &out)
        guard status == noErr, let session = out else {
            box.release()
            throw VideoDecoderError.sessionCreationFailed(status: status)
        }
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata,
                             value: kCFBooleanTrue)
        return (session, box)
    }

    private static func dolbyVisionLevel(codecpar: UnsafeMutablePointer<AVCodecParameters>) -> Int? {
        let nb = Int(codecpar.pointee.nb_coded_side_data)
        guard nb > 0, let side = codecpar.pointee.coded_side_data else { return nil }
        for i in 0..<nb where side[i].type == AV_PKT_DATA_DOVI_CONF {
            guard let raw = side[i].data, side[i].size >= 8 else { continue }
            let level = raw.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) {
                Int($0.pointee.dv_level)
            }
            return level > 0 ? level : nil
        }
        return nil
    }

    // MARK: - Decode

    func decode(packet: UnsafeMutablePointer<AVPacket>, epoch: UInt64?) {
        lock.lock()
        if let epoch, epoch != _feedEpoch { lock.unlock(); return }
        guard baseSession != nil else { lock.unlock(); return }
        lock.unlock()
        guard let data = packet.pointee.data, packet.pointee.size > 0 else { return }
        let size = Int(packet.pointee.size)

        let pts = SourceTimestampBounds.cmTime(ticks: packet.pointee.pts, timeBase: timeBase)
        let dts = SourceTimestampBounds.cmTime(ticks: packet.pointee.dts, timeBase: timeBase)
        let duration = packet.pointee.duration > 0
            ? SourceTimestampBounds.cmTime(ticks: packet.pointee.duration, timeBase: timeBase)
            : CMTime.invalid
        let key = Key(value: pts.value, timescale: pts.timescale)
        let isKey = (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0

        // Both read from the source packet, before the conversion below drops the layer and rewrites
        // the RPU they come from.
        let elNALs = DolbyVisionEnhancementLayer.nalUnits(data, size, framing: framing)
        let params = composer == nil
            ? nil
            : DolbyVisionComposerParams.fromAccessUnit(data, size, framing: framing)?.packed()

        // The base access unit as the single-layer Profile 8.1 the session was opened for. A clone,
        // because the packet is the demux loop's and may be stored for a later seek.
        guard let clone = av_packet_clone(packet) else { return }
        defer {
            var doomed: UnsafeMutablePointer<AVPacket>? = clone
            av_packet_free(&doomed)
        }
        _ = DoviRpuConverter.convertPacketToProfile81(clone, framing: framing)
        guard let baseData = clone.pointee.data, clone.pointee.size > 0 else { return }
        let baseBytes = [UInt8](UnsafeBufferPointer(start: baseData, count: Int(clone.pointee.size)))

        let enhancementReady = params != nil && !elNALs.isEmpty && prepareEnhancementSession(for: elNALs)

        stateLock.lock()
        if let params {
            paramsByKey[key] = params
            paramsOrder.append(key)
            while paramsOrder.count > 64 { paramsByKey.removeValue(forKey: paramsOrder.removeFirst()) }
        }
        if enhancementReady { pairing.expectEnhancement(key) }
        stateLock.unlock()

        lock.lock()
        if let epoch, epoch != _feedEpoch { lock.unlock(); return }
        let baseSession = self.baseSession, baseFormat = self.baseFormat
        let enhancementSession = self.enhancementSession, enhancementFormat = self.enhancementFormat
        lock.unlock()
        guard let baseSession, let baseFormat else { return }

        let baseStatus = submit(baseBytes, to: baseSession, format: baseFormat,
                                pts: pts, dts: dts, duration: duration, isKey: isKey)
        if baseStatus != noErr {
            EngineLog.emit("[DVFEL] base layer decode error \(baseStatus) at pts=\(packet.pointee.pts)",
                           category: .swPlayback)
        }
        guard enhancementReady else { return }
        var enhancementStatus: OSStatus = kVTInvalidSessionErr
        if let enhancementSession, let enhancementFormat {
            enhancementStatus = submit(DolbyVisionEnhancementLayer.lengthPrefixed(elNALs), to: enhancementSession,
                                       format: enhancementFormat, pts: pts, dts: dts, duration: duration,
                                       isKey: isKey)
        }
        if enhancementStatus != noErr {
            enhancementFailed(key)
        }
    }

    /// Open (or reopen, on new parameter sets) the enhancement layer's session. False while the layer
    /// has not yet shown its parameter sets, which after a seek is until its first IRAP.
    private func prepareEnhancementSession(for nals: [[UInt8]]) -> Bool {
        let sets = DolbyVisionEnhancementLayer.parameterSets(in: nals)
        lock.lock()
        let current = enhancementParameterSets, hasSession = enhancementSession != nil
        lock.unlock()
        guard let sets, sets != current else { return hasSession }

        var format: CMVideoFormatDescription?
        let status: OSStatus = sets.vps.withUnsafeBufferPointer { vps in
            sets.sps.withUnsafeBufferPointer { sps in
                sets.pps.withUnsafeBufferPointer { pps in
                    let pointers: [UnsafePointer<UInt8>] = [vps.baseAddress!, sps.baseAddress!, pps.baseAddress!]
                    let sizes = [vps.count, sps.count, pps.count]
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: 3,
                        parameterSetPointers: pointers, parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
                }
            }
        }
        guard status == noErr, let format else {
            EngineLog.emit("[DVFEL] enhancement layer parameter sets rejected (\(status)); base layer alone",
                           category: .swPlayback)
            return hasSession
        }

        lock.lock()
        let old = enhancementSession
        let oldBox = enhancementBox
        if let old, VTDecompressionSessionCanAcceptFormatDescription(old, formatDescription: format) {
            enhancementFormat = format
            enhancementParameterSets = sets
            lock.unlock()
            return true
        }
        lock.unlock()

        if let old {
            VTDecompressionSessionWaitForAsynchronousFrames(old)
            VTDecompressionSessionInvalidate(old)
        }
        oldBox?.release()
        do {
            let (session, box) = try makeSession(format: format, isBase: false)
            lock.lock()
            enhancementSession = session
            enhancementFormat = format
            enhancementParameterSets = sets
            enhancementBox = box
            lock.unlock()
            let dims = CMVideoFormatDescriptionGetDimensions(format)
            EngineLog.emit("[DVFEL] enhancement layer session open \(dims.width)x\(dims.height)", category: .swPlayback)
            return true
        } catch {
            lock.lock()
            enhancementSession = nil
            enhancementFormat = nil
            enhancementParameterSets = sets
            enhancementBox = nil
            lock.unlock()
            EngineLog.emit("[DVFEL] enhancement layer session failed (\(error)); base layer alone",
                           category: .swPlayback)
            return false
        }
    }

    private func submit(_ bytes: [UInt8], to session: VTDecompressionSession, format: CMVideoFormatDescription,
                        pts: CMTime, dts: CMTime, duration: CMTime, isKey: Bool) -> OSStatus {
        let size = bytes.count
        guard size > 0 else { return kVTParameterErr }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 1)
        bytes.withUnsafeBytes { memory.copyMemory(from: $0.baseAddress!, byteCount: size) }
        var block: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: memory, blockLength: size,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: size, flags: 0, blockBufferOut: &block)
        guard blockStatus == kCMBlockBufferNoErr, let block else {
            memory.deallocate()
            return blockStatus
        }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: dts)
        var sampleSize = size
        var sample: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample)
        guard sampleStatus == noErr, let sample else { return sampleStatus }
        if !isKey,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DependsOnOthers).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        var info = VTDecodeInfoFlags()
        return VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample,
            flags: [._EnableAsynchronousDecompression, ._EnableTemporalProcessing],
            frameRefcon: nil, infoFlagsOut: &info)
    }

    // MARK: - Flush / close

    func flush() {
        lock.lock()
        _feedEpoch &+= 1
        let base = baseSession, enhancement = enhancementSession
        lock.unlock()

        stateLock.lock()
        draining = true
        deliveryGeneration &+= 1
        stateLock.unlock()
        for session in [base, enhancement].compactMap({ $0 }) {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionFinishDelayedFrames(session)
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
        composeQueue.sync {}
        stateLock.lock()
        draining = false
        pairing.reset()
        paramsByKey.removeAll()
        paramsOrder.removeAll()
        stateLock.unlock()
    }

    func close() {
        lock.lock()
        let base = baseSession, enhancement = enhancementSession
        baseSession = nil
        enhancementSession = nil
        baseFormat = nil
        enhancementFormat = nil
        enhancementParameterSets = nil
        lock.unlock()

        stateLock.lock()
        draining = true
        deliveryGeneration &+= 1
        stateLock.unlock()
        for session in [base, enhancement].compactMap({ $0 }) {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        composeQueue.sync {}
        stateLock.lock()
        pairing.reset()
        paramsByKey.removeAll()
        paramsOrder.removeAll()
        _onFrame = nil
        stateLock.unlock()

        baseBox?.release()
        baseBox = nil
        enhancementBox?.release()
        enhancementBox = nil
        if composedCount + baseOnlyCount > 0 {
            EngineLog.emit("[DVFEL] closed: \(composedCount) composed, \(baseOnlyCount) base layer alone",
                           category: .swPlayback)
        }
    }

    deinit {
        close()
    }

    // MARK: - VT output (VideoToolbox's threads)

    fileprivate func handleOutput(isBase: Bool, status: OSStatus, image: CVImageBuffer?, pts: CMTime) {
        let key = Key(value: pts.value, timescale: pts.timescale)
        stateLock.lock()
        if draining { stateLock.unlock(); return }
        let ready: [DolbyVisionFramePairing<CVPixelBuffer>.Pair]
        if let image, status == noErr {
            ready = isBase ? pairing.addBase(key, image) : pairing.addEnhancement(key, image)
        } else if !isBase, pts.isValid {
            ready = pairing.enhancementFailed(key)
        } else {
            ready = []
        }
        // Queued under the lock so the queue sees pictures in the order the pairing released them.
        enqueueLocked(ready)
        stateLock.unlock()
    }

    fileprivate func enhancementFailed(_ key: Key) {
        stateLock.lock()
        enqueueLocked(pairing.enhancementFailed(key))
        stateLock.unlock()
    }

    /// One released picture and the composer parameters of its access unit, handed to the compose queue.
    private struct ComposeJob: @unchecked Sendable {
        let pair: DolbyVisionFramePairing<CVPixelBuffer>.Pair
        let params: [Float]?
    }

    /// `stateLock` held.
    private func enqueueLocked(_ ready: [DolbyVisionFramePairing<CVPixelBuffer>.Pair]) {
        guard !ready.isEmpty else { return }
        let generation = deliveryGeneration
        let jobs = ready.map { ComposeJob(pair: $0, params: paramsByKey.removeValue(forKey: $0.key)) }
        composeQueue.async { [weak self] in
            for job in jobs { self?.deliver(job.pair, params: job.params, generation: generation) }
        }
    }

    /// Compose queue only.
    private func deliver(_ pair: DolbyVisionFramePairing<CVPixelBuffer>.Pair, params: [Float]?, generation: UInt64) {
        stateLock.lock()
        let current = generation == deliveryGeneration
        let threshold = _skipUntilPTS
        let handler = _onFrame
        stateLock.unlock()
        guard current, let handler else { return }
        let pts = CMTime(value: pair.key.value, timescale: pair.key.timescale)
        if let threshold {
            if CMTimeCompare(pts, threshold) < 0 { return }
            stateLock.lock()
            if let now = _skipUntilPTS, CMTimeCompare(now, threshold) == 0 { _skipUntilPTS = nil }
            stateLock.unlock()
        }

        logDolbyVisionMetadataOnce(pair.base)
        var picture: CVPixelBuffer = pair.base
        if let composer, let params,
           let composed = composer.compose(base: pair.base, enhancement: pair.enhancement, params: params) {
            // The base picture's attachments are the frame's: its colour and the rest of what
            // VideoToolbox propagates, then the Dolby Vision metadata by name, in whatever mode it was
            // attached, so a key VideoToolbox marks non-propagating is not lost on the copy.
            if let attachments = CVBufferCopyAttachments(pair.base, .shouldPropagate) {
                CVBufferSetAttachments(composed, attachments, .shouldPropagate)
            }
            Self.copyDolbyVisionMetadata(from: pair.base, to: composed)
            picture = composed
            composedCount += 1
            if !loggedFirstComposition {
                loggedFirstComposition = true
                EngineLog.emit(
                    "[DVFEL] first composed frame \(CVPixelBufferGetWidth(composed))x\(CVPixelBufferGetHeight(composed))"
                    + (pair.enhancement.map {
                        " (enhancement \(CVPixelBufferGetWidth($0))x\(CVPixelBufferGetHeight($0)))"
                    } ?? " (no enhancement picture, prediction only)"),
                    category: .swPlayback)
            }
        } else {
            baseOnlyCount += 1
        }
        attachColour(picture)
        reportFormat(picture)
        handler(picture, pts, nil)
    }

    /// Carry the frame's undocumented Dolby Vision attachments (`DolbyVisionUndocumentedKeys`) from the
    /// decoded base picture to the composed one, each in the mode it was attached in. Returns the keys
    /// that were present.
    @discardableResult
    static func copyDolbyVisionMetadata(from base: CVBuffer, to composed: CVBuffer) -> [String] {
        var present: [String] = []
        for key in DolbyVisionUndocumentedKeys.perFrameMetadata {
            var mode = CVAttachmentMode.shouldPropagate
            guard let value = CVBufferCopyAttachment(base, key as CFString, &mode) else { continue }
            CVBufferSetAttachment(composed, key as CFString, value, mode)
            present.append(key)
        }
        return present
    }

    /// Once per session: whether VideoToolbox attached the frame's Dolby Vision metadata to the base
    /// picture at all. Without it the composed picture still presents, as PQ HDR10 with the residual,
    /// but the panel gets no per-frame Dolby Vision, and this line is how a capture says so.
    private func logDolbyVisionMetadataOnce(_ base: CVBuffer) {
        guard !loggedMetadataPresence else { return }
        loggedMetadataPresence = true
        let present = DolbyVisionUndocumentedKeys.perFrameMetadata.map { key -> String in
            "\(key)=" + (CVBufferCopyAttachment(base, key as CFString, nil) == nil ? "absent" : "present")
        }
        EngineLog.emit("[DVFEL] base picture Dolby Vision attachments: " + present.joined(separator: " "),
                       category: .swPlayback)
    }

    private func attachColour(_ buffer: CVPixelBuffer) {
        let tags = ColorAttachments.presented(streamColor)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, tags.primaries, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, tags.transfer, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, tags.matrix, .shouldPropagate)
        if let sar = pixelAspectRatio {
            let aspect: NSDictionary = [
                kCVImageBufferPixelAspectRatioHorizontalSpacingKey: Int(sar.num),
                kCVImageBufferPixelAspectRatioVerticalSpacingKey: Int(sar.den),
            ]
            CVBufferSetAttachment(buffer, kCVImageBufferPixelAspectRatioKey, aspect, .shouldPropagate)
        } else {
            CVBufferRemoveAttachment(buffer, kCVImageBufferPixelAspectRatioKey)
        }
    }

    private func reportFormat(_ buffer: CVPixelBuffer) {
        guard !reportedFormat, let onDecodedFormat else { return }
        reportedFormat = true
        let type = CVPixelBufferGetPixelFormatType(buffer)
        onDecodedFormat(DecodedVideoFormat(
            frame: VideoStreamFormat(
                pixelFormat: DecodedVideoFormat.libavPixelFormat(forPixelBufferType: type),
                declaredBitDepth: 0,
                color: streamColor,
                codecID: AV_CODEC_ID_HEVC,
                profile: AV_PROFILE_HEVC_MAIN_10),
            pixelBufferFormat: DecodedVideoFormat.fourCC(type)))
    }
}

// MARK: - C callback

private func felDecoderOutputCallback(
    decompressionOutputRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTDecodeInfoFlags,
    imageBuffer: CVImageBuffer?,
    presentationTimeStamp: CMTime,
    presentationDuration: CMTime
) {
    guard let refCon = decompressionOutputRefCon else { return }
    let box = Unmanaged<DolbyVisionFELDecoder.RefConBox>.fromOpaque(refCon).takeUnretainedValue()
    box.decoder?.handleOutput(isBase: box.isBase, status: status, image: imageBuffer, pts: presentationTimeStamp)
}
