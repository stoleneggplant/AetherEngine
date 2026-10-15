// Tests/AetherEngineTests/IFramePlaylistTextTests.swift
import Testing
import Foundation
@testable import AetherEngine

private final class IFrameMockProvider: HLSSegmentProvider, @unchecked Sendable {
    let served: Bool
    let durations: [Double]
    let supplemental: String?
    let format: IFrameRenditionFormat?
    init(served: Bool, durations: [Double] = [4.0, 4.0, 2.5], supplemental: String? = nil,
         format: IFrameRenditionFormat? = nil) {
        self.served = served; self.durations = durations; self.supplemental = supplemental
        self.format = format
    }
    func initSegment() -> Data? { Data([0x00]) }
    func mediaSegment(at index: Int) -> Data? { Data([0x00]) }
    var segmentCount: Int { durations.count }
    func segmentDuration(at index: Int) -> Double { durations[index] }
    var playlistType: HLSPlaylistType { .vod }
    var masterCodecs: String? { "hvc1.2.4.L150.B0,ec-3" }
    var masterSupplementalCodecs: String? { supplemental }
    var masterResolution: (width: Int, height: Int)? { (3840, 2160) }
    var masterVideoRange: HLSVideoRange? { .pq }
    var masterBandwidth: Int? { 12_000_000 }
    var masterFrameRate: Double? { 23.976 }
    var iFrameRenditionServed: Bool { served }
    var iFrameRenditionFormat: IFrameRenditionFormat? { format }
}

struct IFramePlaylistTextTests {
    @Test("master carries one I-frame line, after the variant, with the video codec only")
    func masterLine() {
        let m = HLSLocalServer.buildMasterPlaylistText(provider: IFrameMockProvider(served: true))
        let lines = m.split(separator: "\n").map(String.init)
        let tag = lines.filter { $0.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") }
        #expect(tag.count == 1)
        #expect(tag[0] == "#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=12000000,CODECS=\"hvc1.2.4.L150.B0\","
                + "RESOLUTION=3840x2160,VIDEO-RANGE=PQ,URI=\"iframe.m3u8\"")
        let variantURI = try! #require(lines.firstIndex(of: "media.m3u8"))
        #expect(lines.firstIndex(of: tag[0])! > variantURI)
    }

    @Test("a JPEG rendition is declared as SDR motion JPEG, whatever the variant carries")
    func masterLineForJPEG() {
        let p = IFrameMockProvider(served: true, supplemental: "dvh1.08.06/db1p",
                                   format: .jpeg(width: 640, height: 360, bandwidth: 790_000))
        let tag = HLSLocalServer.buildMasterPlaylistText(provider: p)
            .split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") }
        #expect(tag == ["#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=790000,CODECS=\"mjpg\","
                        + "RESOLUTION=640x360,VIDEO-RANGE=SDR,URI=\"iframe.m3u8\""])
    }

    @Test("master is untouched when the rendition is not served")
    func masterWithout() {
        let m = HLSLocalServer.buildMasterPlaylistText(provider: IFrameMockProvider(served: false))
        #expect(!m.contains("I-FRAME"))
        #expect(m.hasSuffix("media.m3u8\n"))
    }

    @Test("SUPPLEMENTAL-CODECS rides on the primary master and is dropped on the reduced one")
    func supplementalFollowsVariant() {
        let p = IFrameMockProvider(served: true, supplemental: "dvh1.08.06/db1p")
        let primary = HLSLocalServer.buildMasterPlaylistText(provider: p)
        let reduced = HLSLocalServer.buildMasterPlaylistText(provider: p, variant: .reducedHDR)
        let tag: (String) -> String = { text in
            text.split(separator: "\n").map(String.init).first { $0.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") }!
        }
        #expect(tag(primary).contains("SUPPLEMENTAL-CODECS=\"dvh1.08.06/db1p\""))
        #expect(!tag(reduced).contains("SUPPLEMENTAL-CODECS"))
        #expect(tag(reduced).contains("URI=\"iframe.m3u8\""))
    }

    @Test("I-frame playlist mirrors the plan one entry per segment")
    func playlist() {
        let p = IFrameMockProvider(served: true)
        let text = HLSLocalServer.buildIFramePlaylistText(provider: p)
        #expect(text == """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-I-FRAMES-ONLY
        #EXT-X-TARGETDURATION:4
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-MAP:URI="iframe_init.mp4"
        #EXTINF:4.000,
        iframe0.mp4
        #EXTINF:4.000,
        iframe1.mp4
        #EXTINF:2.500,
        iframe2.mp4
        #EXT-X-ENDLIST

        """)
    }

    @Test("I-frame playlist TARGETDURATION equals the media playlist's")
    func targetDurationMatchesMedia() {
        let p = IFrameMockProvider(served: true, durations: [4.0, 9.6, 4.0])
        let media = HLSLocalServer.buildMediaPlaylistText(provider: p)
        let iframe = HLSLocalServer.buildIFramePlaylistText(provider: p)
        let td: (String) -> String? = { t in
            t.split(separator: "\n").map(String.init).first { $0.hasPrefix("#EXT-X-TARGETDURATION:") }
        }
        #expect(td(media) != nil)
        #expect(td(media) == td(iframe))
    }

    @Test("absolute sub-resource base is honoured like in the media playlist")
    func absoluteBase() {
        let p = IFrameMockProvider(served: true, durations: [4.0])
        let text = HLSLocalServer.buildIFramePlaylistText(
            provider: p, subResourceBaseURL: URL(string: "aether-hls://session/")!)
        #expect(text.contains("#EXT-X-MAP:URI=\"aether-hls://session/iframe_init.mp4\""))
        #expect(text.contains("\naether-hls://session/iframe0.mp4\n"))
    }

    @Test("I-frame segment paths parse to their index, and nothing else does",
          arguments: [("/iframe0.mp4", 0), ("/iframe17.mp4", 17), ("/iframe_init.mp4", nil),
                      ("/iframe-1.mp4", nil), ("/iframeX.mp4", nil), ("/iframe.mp4", nil),
                      ("/iframe3.m4s", nil), ("/seg3.mp4", nil)] as [(String, Int?)])
    func parsePath(path: String, expected: Int?) {
        #expect(HLSLocalServer.parseIFramePath(path) == expected)
    }

    @Test("video codec extraction keeps the video entry and falls back to the whole string",
          arguments: [("hvc1.2.4.L150.B0,ec-3", "hvc1.2.4.L150.B0"), ("mp4a.40.2,avc1.640028", "avc1.640028"),
                      ("dvh1.05.06,ec-3", "dvh1.05.06"), ("av01.0.12M.10", "av01.0.12M.10"),
                      ("xyz1.1", "xyz1.1")])
    func videoCodecs(codecs: String, expected: String) {
        #expect(HLSLocalServer.videoCodecs(of: codecs) == expected)
    }
}
