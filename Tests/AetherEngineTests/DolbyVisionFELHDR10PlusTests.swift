import Foundation
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// Profile 7 FEL composed first, then presented as HDR10+ (`preferDualLayerDolbyVision` together with
/// `convertsDolbyVisionToHDR10Plus` on a display without Dolby Vision).
///
/// The enhancement layer can move luma far from the base layer, so everything the display is told about the
/// picture has to describe the composed signal: per-frame HDR10+ from the RPU's L1 (measured on the
/// reconstructed signal), MaxCLL / MaxFALL from its L6 (the composed master's), never the base layer's. These
/// pin the routing, the decision of which HDR10+ a composed picture carries, and the exact bytes of the
/// static metadata attachments. The composition itself is `DolbyVisionFELCompositionTests`' and the GPU's.
@Suite("Dolby Vision Profile 7 FEL, composed then HDR10+")
struct DolbyVisionFELHDR10PlusTests {

    typealias Mapping = DolbyVisionHDR10PlusMapping

    // MARK: - Routing

    private func inputs(_ edit: (inout DolbyVisionFELPolicy.Inputs) -> Void = { _ in }) -> DolbyVisionFELPolicy.Inputs {
        var i = DolbyVisionFELPolicy.Inputs(
            dvProfile: 7, enhancementLayerType: "FEL", displayPresentsDolbyVision: false,
            presentsBaseLayerOnly: false, hostAllowsComposition: true, isLive: false,
            sourceIsSeekable: true, samplesAreLengthPrefixed: true, hardwareCanCompose: true,
            convertsToHDR10Plus: true)
        edit(&i)
        return i
    }

    @Test("on a display without Dolby Vision a FEL composes when the session converts to HDR10+, and outputs it")
    func composesForHDR10Plus() {
        #expect(DolbyVisionFELPolicy.composes(inputs()))
        #expect(DolbyVisionFELPolicy.outputsHDR10Plus(inputs()))
        #expect(DolbyVisionFELPolicy.worthAuditing(inputs()))
        #expect(DolbyVisionFELPolicy.refusal(inputs()) == nil)
    }

    @Test("without the conversion a display lacking Dolby Vision still keeps the single-layer route")
    func needsTheConversion() {
        let plain = inputs { $0.convertsToHDR10Plus = false }
        #expect(!DolbyVisionFELPolicy.composes(plain))
        #expect(!DolbyVisionFELPolicy.worthAuditing(plain))
        #expect(DolbyVisionFELPolicy.refusal(plain)?.contains("does not present Dolby Vision") == true)
    }

    @Test("a Dolby Vision display composes to Dolby Vision, whatever the conversion says")
    func dolbyVisionDisplayKeepsDolbyVision() {
        let dv = inputs { $0.displayPresentsDolbyVision = true; $0.convertsToHDR10Plus = false }
        #expect(DolbyVisionFELPolicy.composes(dv))
        #expect(!DolbyVisionFELPolicy.outputsHDR10Plus(dv))
    }

    @Test("every other gate still holds for the HDR10+ output")
    func otherGatesHold() {
        #expect(!DolbyVisionFELPolicy.composes(inputs { $0.enhancementLayerType = "MEL" }))
        #expect(!DolbyVisionFELPolicy.composes(inputs { $0.hostAllowsComposition = false }))
        #expect(!DolbyVisionFELPolicy.composes(inputs { $0.presentsBaseLayerOnly = true }))
        #expect(!DolbyVisionFELPolicy.composes(inputs { $0.hardwareCanCompose = false }))
        #expect(!DolbyVisionFELPolicy.outputsHDR10Plus(inputs { $0.isLive = true }))
    }

    @Test("HDR10+ output does not need a Dolby Vision decoder; Dolby Vision output does")
    func deviceShortfall() {
        #expect(DolbyVisionFELDecoder.deviceShortfall(
            requiresDolbyVisionDecode: false, hasMetal: true, decodesHEVC: true, decodesDolbyVision: false) == nil)
        #expect(DolbyVisionFELDecoder.deviceShortfall(
            requiresDolbyVisionDecode: true, hasMetal: true, decodesHEVC: true, decodesDolbyVision: false)
            == "no hardware Dolby Vision decode")
    }

    @Test("with dual-layer playback asked for, toggling the conversion in place is refused: it picks the host")
    func reloadRefusesHostChange() {
        var current = LoadOptions()
        current.preferDualLayerDolbyVision = true
        var proposed = current
        proposed.convertsDolbyVisionToHDR10Plus = true
        #expect(SessionOptionCorrection.refusedFields(from: current, to: proposed) == ["convertsDolbyVisionToHDR10Plus"])
        // Without it the conversion stays a tuning field.
        var plain = LoadOptions()
        plain.convertsDolbyVisionToHDR10Plus = true
        #expect(SessionOptionCorrection.refusedFields(from: LoadOptions(), to: plain).isEmpty)
    }

    // MARK: - Which HDR10+ a composed picture carries

    private static let slice: [UInt8] = [0x02, 0x01, 0x80, 0xAA, 0xBB]
    private static let enhancementLayer: [UInt8] = [63 << 1, 0x01, 0x01, 0x02]

    @Test("derived from the access unit's own RPU, the packet left untouched")
    func derivedFromRPU() throws {
        let rpu = DolbyVisionHDR10PlusTests.rpuShotWithL3
        let packet = Self.avccPacket([Self.slice, rpu, Self.enhancementLayer])
        defer { Self.free(packet) }
        let before = Array(UnsafeBufferPointer(start: packet.pointee.data, count: Int(packet.pointee.size)))

        let synthesizer = DolbyVisionHDR10PlusSynthesizer()
        let result = synthesizer.payload(for: packet, framing: .lengthPrefixed(size: 4))
        #expect(result.outcome == .derived)
        let expected = Mapping.t35Payload(Mapping.metadata(for: .init(minPQ: 0, maxPQ: 3031, avgPQ: 1952)))
        #expect(result.t35 == expected)
        #expect(result.t35?.first == 0xB5)    // what kCMSampleAttachmentKey_HDR10PlusPerFrameData requires
        let after = Array(UnsafeBufferPointer(start: packet.pointee.data, count: Int(packet.pointee.size)))
        #expect(after == before)
    }

    @Test("the source's own HDR10+ wins, unescaped and whole, and nothing is derived after it")
    func nativeWins() {
        let payload = Self.hexBytes(DolbyVisionHDR10PlusTests.golden[1].payloadHex)
        let native = Mapping.hevcPrefixSEINAL(t35Payload: payload)
        let packet = Self.avccPacket([native, Self.slice, DolbyVisionHDR10PlusTests.rpuShot])
        defer { Self.free(packet) }
        let synthesizer = DolbyVisionHDR10PlusSynthesizer()
        let result = synthesizer.payload(for: packet, framing: .lengthPrefixed(size: 4))
        #expect(result.outcome == .nativeInBand)
        #expect(result.t35 == payload)

        let next = Self.avccPacket([Self.slice, DolbyVisionHDR10PlusTests.rpuShot])
        defer { Self.free(next) }
        #expect(synthesizer.payload(for: next, framing: .lengthPrefixed(size: 4)).t35 == nil)
        #expect(synthesizer.derivedCount == 0)
    }

    // MARK: - Static metadata of the composed picture

    @Test("L6 is read from the access unit the decoder is fed")
    func staticMetadataFromAccessUnit() throws {
        let bytes = Self.lengthPrefixed([Self.slice, DolbyVisionHDR10PlusTests.rpuShot, Self.enhancementLayer])
        let metadata = try #require(bytes.withUnsafeBufferPointer {
            DolbyVisionFELDecoder.staticMetadata(inAccessUnit: $0.baseAddress!, $0.count, framing: .lengthPrefixed(size: 4))
        })
        #expect(metadata.maxCLL == 1000)
        #expect(metadata.maxFALL == 400)
        #expect(metadata.maxMasteringLuminance == 1000)
    }

    @Test("the CoreVideo attachments are the HEVC SEI payloads, byte for byte")
    func attachmentBytes() throws {
        let metadata = DolbyVisionHDR10PlusAudit.StaticMetadata(
            maxMasteringLuminance: 1000, minMasteringLuminance: 0.0001, maxCLL: 1000, maxFALL: 400,
            primaries: DolbyVisionHDR10PlusAudit.predefinedPrimaries[0])
        // ST 2086 order green, blue, red, white (0.00002 units), then peak and minimum (0.0001 cd/m2).
        let mdcv: [UInt8] = [
            0x33, 0xC2, 0x86, 0xC4,     // green 0.265, 0.690 -> 13250, 34500
            0x1D, 0x4C, 0x0B, 0xB8,     // blue  0.150, 0.060 ->  7500,  3000
            0x84, 0xD0, 0x3E, 0x80,     // red   0.680, 0.320 -> 34000, 16000
            0x3D, 0x13, 0x40, 0x42,     // white 0.3127, 0.329 -> 15635, 16450
            0x00, 0x98, 0x96, 0x80,     // 1000 cd/m2
            0x00, 0x00, 0x00, 0x01,     // 0.0001 cd/m2
        ]
        #expect(try #require(metadata.masteringDisplayColorVolume) == Data(mdcv))
        #expect(metadata.contentLightLevelInfo == Data([0x03, 0xE8, 0x01, 0x90]))   // 1000, 400

        var unknown = metadata
        unknown.maxCLL = 0
        #expect(unknown.contentLightLevelInfo == nil)
    }

    // MARK: - Helpers

    private static func hexBytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    private static func lengthPrefixed(_ nals: [[UInt8]]) -> [UInt8] {
        var bytes: [UInt8] = []
        for nal in nals {
            let n = nal.count
            bytes += [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
            bytes += nal
        }
        return bytes
    }

    private static func avccPacket(_ nals: [[UInt8]]) -> UnsafeMutablePointer<AVPacket> {
        let bytes = lengthPrefixed(nals)
        let pkt = av_packet_alloc()!
        _ = av_new_packet(pkt, Int32(bytes.count))
        bytes.withUnsafeBytes { _ = memcpy(pkt.pointee.data, $0.baseAddress, bytes.count) }
        return pkt
    }

    private static func free(_ pkt: UnsafeMutablePointer<AVPacket>) {
        var p: UnsafeMutablePointer<AVPacket>? = pkt
        av_packet_free(&p)
    }
}
