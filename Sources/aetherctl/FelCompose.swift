import Foundation
import AetherEngine

// MARK: - felcompose

/// AE#702: run the dual-layer Dolby Vision Profile 7 FEL decoder over a source with no display and none
/// of the routing gates, and report whether both layers decode, pair and compose, and whether the
/// composed frames carry the Dolby Vision attachments the display layer reads. `--dump DIR` writes the
/// first frames as raw yuv420p10le; `--no-residual` composes the prediction alone, so the two dumps
/// differ by exactly the enhancement layer's residual.
func runFelCompose(url: URL, frames: Int, startSeconds: Double?, residual: Bool,
                   dumpDirectory: String?, dumpFrames: Int) -> Int32 {
    EngineLog.handler = { print($0) }
    let dumpURL = dumpDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
    print(EngineLog.redacted("aetherctl felcompose: \(url.absoluteString)"))
    print("frames=\(frames) start=\(startSeconds.map { String($0) } ?? "0") residual=\(residual)"
          + (dumpURL.map { " dump=\($0.path) (first \(dumpFrames))" } ?? ""))
    print("")

    let result: DualLayerDolbyVisionProbeResult
    do {
        result = try AetherEngine.dualLayerDolbyVisionProbe(
            url: url, frames: frames, startSeconds: startSeconds, residual: residual,
            dumpDirectory: dumpURL, dumpFrames: dumpFrames)
    } catch {
        print("ERROR: \(error)")
        return 1
    }

    let attachments = result.dolbyVisionAttachments.keys.sorted()
        .map { "\($0)=\(result.dolbyVisionAttachments[$0] == true ? "present" : "ABSENT")" }
        .joined(separator: " ")
    print("")
    print("=== DUAL-LAYER DOLBY VISION ===")
    print("DV profile:            \(result.dvProfile.map(String.init) ?? "none")")
    print("Enhancement layer:     \(result.enhancementLayerType ?? "unread")")
    print("Device shortfall:      \(result.deviceShortfall ?? "none")")
    print("Composer (Metal):      \(result.composerAvailable ? "ready" : "UNAVAILABLE")")
    print("Base layer:            \(result.baseWidth)x\(result.baseHeight)")
    print("Enhancement layer:     "
          + (result.enhancementWidth > 0 ? "\(result.enhancementWidth)x\(result.enhancementHeight)" : "none decoded"))
    print("Video packets fed:     \(result.videoPacketsFed)")
    print("Frames delivered:      \(result.framesDelivered)")
    print("  composed:            \(result.framesComposed) (with enhancement: \(result.framesComposedWithEnhancement))")
    print("  base picture only:   \(result.framesBaseOnly)")
    print("Pixel format:          \(result.pixelFormat ?? "-")")
    print("DV attachments:        \(attachments.isEmpty ? "-" : attachments)")
    for file in result.dumpedFiles { print("Dumped:                \(file)") }
    print("===============================")
    print("")
    if let first = result.dumpedFiles.first {
        print("View a dump: ffmpeg -f rawvideo -pix_fmt yuv420p10le -s \(result.baseWidth)x\(result.baseHeight) "
              + "-i '\(first)' -frames:v 1 frame.png")
        print("")
    }

    guard result.dvProfile == 7 else {
        print("VERDICT: not a Dolby Vision Profile 7 source; nothing to compose.")
        return 2
    }
    guard result.composerAvailable else {
        print("VERDICT: the Metal composer did not build; every frame is the base picture alone.")
        return 3
    }
    guard result.framesComposed > 0 else {
        print("VERDICT: no frame composed (\(result.framesDelivered) delivered). See the [DVFEL] lines above.")
        return 4
    }
    if residual, result.framesComposedWithEnhancement == 0 {
        print("VERDICT: frames composed on the prediction alone; no enhancement picture was paired.")
        print("         Check the [DVFEL] enhancement-session lines (parameter sets, session errors).")
        return 5
    }
    if result.dolbyVisionAttachments.values.contains(false) {
        print("VERDICT: composition works, but the frames lack Dolby Vision attachments, so a panel would")
        print("         show PQ HDR10 with the residual and no per-frame Dolby Vision. Expected on a Mac,")
        print("         which has no Dolby Vision decoder to attach them; the device test decides it.")
        return 0
    }
    print("VERDICT: both layers decoded, paired and composed; the frames carry the Dolby Vision attachments.")
    return 0
}
