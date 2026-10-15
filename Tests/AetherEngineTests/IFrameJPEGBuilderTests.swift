// Tests/AetherEngineTests/IFrameJPEGBuilderTests.swift
import Foundation
import Testing
import ImageIO
@testable import AetherEngine

private func fixtureExists(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name)").path)
}

@Suite("I-frame JPEG builder", .serialized)
struct IFrameJPEGBuilderTests {
    private func stagingDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iframe-jpeg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sampleEntryType(_ initSegment: Data) -> String? {
        guard let stsd = IFrameTestBoxes.find(["moov", "trak", "mdia", "minf", "stbl", "stsd"], in: initSegment)
        else { return nil }
        let at = stsd.lowerBound + 12
        return String(bytes: initSegment[at..<(at + 4)], encoding: .isoLatin1)
    }

    private func jpegPayload(_ fragment: Data) -> Data? {
        guard let mdat = IFrameTestBoxes.find(["mdat"], in: fragment) else { return nil }
        return fragment.subdata(in: mdat)
    }

    @Test("the still keeps the display aspect, at most the requested width, even on both axes")
    func size() {
        #expect(IFrameJPEGBuilder.size(codedWidth: 3840, codedHeight: 2160, sarNum: 1, sarDen: 1)! == (640, 360))
        #expect(IFrameJPEGBuilder.size(codedWidth: 3840, codedHeight: 1714, sarNum: 0, sarDen: 0)! == (640, 286))
        // Anamorphic DVD: 720x576 at 64:45 displays 1024 wide.
        #expect(IFrameJPEGBuilder.size(codedWidth: 720, codedHeight: 576, sarNum: 64, sarDen: 45)! == (640, 360))
        #expect(IFrameJPEGBuilder.size(codedWidth: 320, codedHeight: 180, sarNum: 1, sarDen: 1)! == (320, 180))
        #expect(IFrameJPEGBuilder.size(codedWidth: 0, codedHeight: 180, sarNum: 1, sarDen: 1) == nil)
    }

    @Test("the declared bandwidth covers the largest still over the shortest segment")
    func bandwidth() {
        let declared = IFrameJPEGBuilder.bandwidth(shortestSegmentSeconds: 2.0)
        #expect(Double(declared) >= Double(IFrameJPEGBuilder.maxFrameBytes) * 8 / 2.0)
        #expect(IFrameJPEGBuilder.bandwidth(shortestSegmentSeconds: 0) > declared)
    }

    @Test("the init carries one mjpg track of the declared size")
    func initSegment() {
        let initSegment = IFrameJPEGBuilder.makeInit(width: 640, height: 286)
        #expect(IFrameTestBoxes.topLevelTypes(initSegment) == ["ftyp", "moov"])
        #expect(sampleEntryType(initSegment) == "mjpg")
        #expect(IFrameTestBoxes.timescale(initSegment: initSegment) == 90_000)
        let tkhd = IFrameTestBoxes.find(["moov", "trak", "tkhd"], in: initSegment)!
        #expect(IFrameTestBoxes.u32(initSegment, tkhd.upperBound - 8) == 640 << 16)
        #expect(IFrameTestBoxes.u32(initSegment, tkhd.upperBound - 4) == 286 << 16)
    }

    @Test("a fragment holds one sample at the plan time, its data offset on the JPEG")
    func fragment() {
        let jpeg = Data([0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9])
        let fragment = IFrameJPEGBuilder.makeFragment(jpeg: jpeg, sequence: 8, startSeconds: 28.5,
                                                      durationSeconds: 4)
        #expect(IFrameTestBoxes.topLevelTypes(fragment) == ["moof", "mdat"])
        #expect(IFrameTestBoxes.sampleCount(fragment: fragment) == 1)
        #expect(IFrameTestBoxes.baseDecodeTime(fragment: fragment) == 2_565_000)
        let trun = IFrameTestBoxes.find(["moof", "traf", "trun"], in: fragment)!
        let offset = Int(IFrameTestBoxes.u32(fragment, trun.lowerBound + 8))
        #expect(fragment.subdata(in: offset..<(offset + jpeg.count)) == jpeg)
    }

    @Test("an HDR10 keyframe becomes an SDR JPEG of the declared size",
          .enabled(if: fixtureExists("hdr10-hevc.mp4")))
    func hdrKeyframe() throws {
        let fx = try IFrameFixture("hdr10-hevc.mp4", codecTag: "hvc1")
        defer { fx.demuxer.close() }
        let dir = try stagingDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let builder = IFrameJPEGBuilder(keyframe: IFrameFragmentBuilder(video: fx.config, stagingDir: dir),
                                        width: 640, height: 360)

        let out = try #require(builder.build(payload: fx.keyframe, index: 3, startSeconds: 12,
                                             durationSeconds: 4))
        #expect(out.initSegment == builder.initSegment)
        #expect(IFrameTestBoxes.baseDecodeTime(fragment: out.fragment) == 1_080_000)
        let jpeg = try #require(jpegPayload(out.fragment))
        #expect(jpeg.prefix(2) == Data([0xFF, 0xD8]))
        #expect(jpeg.count <= IFrameJPEGBuilder.maxFrameBytes)
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 640 && image.height == 360)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test("a still asked for again is answered from memory without the payload",
          .enabled(if: fixtureExists("hdr10-hevc.mp4")))
    func repeatsFromMemory() throws {
        let fx = try IFrameFixture("hdr10-hevc.mp4", codecTag: "hvc1")
        defer { fx.demuxer.close() }
        let dir = try stagingDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let builder = IFrameJPEGBuilder(keyframe: IFrameFragmentBuilder(video: fx.config, stagingDir: dir),
                                        width: 640, height: 360)
        let first = try #require(builder.build(payload: fx.keyframe, index: 5, startSeconds: 20,
                                               durationSeconds: 4))
        let again = try #require(builder.build(payload: Data([0, 0, 0, 1]), index: 5, startSeconds: 20,
                                               durationSeconds: 4))
        #expect(again.fragment == first.fragment)
    }

    @Test("a payload that does not decode builds nothing", .enabled(if: fixtureExists("hdr10-hevc.mp4")))
    func undecodable() throws {
        let fx = try IFrameFixture("hdr10-hevc.mp4", codecTag: "hvc1")
        defer { fx.demuxer.close() }
        let dir = try stagingDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let builder = IFrameJPEGBuilder(keyframe: IFrameFragmentBuilder(video: fx.config, stagingDir: dir),
                                        width: 640, height: 360)
        #expect(builder.build(payload: Data([0, 0, 0, 4, 1, 2, 3, 4]), index: 0, startSeconds: 0,
                              durationSeconds: 4) == nil)
    }
}
