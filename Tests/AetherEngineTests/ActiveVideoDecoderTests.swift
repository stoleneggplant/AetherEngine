import Foundation
import Testing
import VideoToolbox
@testable import AetherEngine

/// AE#753: the software playback host can use VideoToolbox. Exercise the public label after
/// both initial load and a session rebuild, rather than testing the label formatter alone.
/// These synthetic clips are local-only; generate them with Scripts/fetch-fixtures.sh.
@Suite("Active video decoder identity", .serialized)
@MainActor
struct ActiveVideoDecoderTests {
    private nonisolated static func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
    }

    private nonisolated static func hasFixture(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: fixture(name).path)
    }

    private func checkLoadAndReload(_ name: String, label: String) async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        var options = LoadOptions()
        options.preferredDecodePath = .software
        options.suppressDisplayCriteria = true
        // A seekable custom source makes reloadAtCurrentPosition exercise the separate
        // reloadWithAudioOverride path, rather than calling the initial URL load again.
        let reader = DataIOReader(data: try Data(contentsOf: Self.fixture(name)))
        _ = try await engine.load(source: .custom(reader), options: options)
        engine.pause()
        #expect(engine.playbackBackend == .software)
        #expect(engine.activeVideoDecoder == label, "initial load must name the actual decoder")

        _ = try await engine.reloadAtCurrentPosition()
        #expect(engine.playbackBackend == .software)
        #expect(engine.activeVideoDecoder == label, "reload must name the newly opened decoder")
    }

    @Test("HEVC decoded by VideoToolbox on the software path (#753)",
          .enabled(if: hasFixture("hdr10-hevc.mp4") && VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)),
          .timeLimit(.minutes(1)))
    func hardwareHEVC() async throws {
        try await checkLoadAndReload("hdr10-hevc.mp4", label: "VideoToolbox HEVC (HW)")
    }

    @Test("HEVC with in-band parameter sets still reports libavcodec",
          .enabled(if: hasFixture("hev1-inband-xps.mp4")), .timeLimit(.minutes(1)))
    func softwareHEVC() async throws {
        try await checkLoadAndReload("hev1-inband-xps.mp4", label: "libavcodec HEVC (SW)")
    }

    @Test("VP9 still reports libavcodec",
          .enabled(if: hasFixture("vp9.webm")), .timeLimit(.minutes(1)))
    func softwareVP9() async throws {
        try await checkLoadAndReload("vp9.webm", label: "libavcodec VP9 (SW)")
    }

    @Test("AV1 still reports dav1d",
          .enabled(if: hasFixture("av1.mp4")), .timeLimit(.minutes(1)))
    func softwareAV1() async throws {
        try await checkLoadAndReload("av1.mp4", label: "dav1d AV1 (SW)")
    }
}
