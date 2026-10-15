// Sources/AetherEngine/Video/IFrameJPEGBuilder.swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// AE#682: turns one keyframe into one Motion JPEG fragment, for sources whose own keyframes AVKit
/// will not show as scrub thumbnails.
///
/// Measured on an Apple TV 4K (tvOS 27, 2026-10-14): the stock scrubber fetches the init and one
/// I-frame of a PQ rendition and then gives up, whether the keyframes are Dolby Vision or plain HDR10,
/// 4K or 1080p. The same keyframes declared and boxed as BT.709 SDR are shown. So an HDR source gets an
/// SDR picture instead, from the still pipeline the engine already has (tone map for PQ/HLG, RPU
/// reshaping for Dolby Vision profile 5), as JPEG in the shape of Apple's own `mjpg` trick-play tier.
final class IFrameJPEGBuilder {
    static let defaultWidth = 640
    /// A JPEG above this is encoded again at lower quality, so the master's BANDWIDTH stays honest.
    static let maxFrameBytes = 192 * 1024
    private static let qualities: [CGFloat] = [0.8, 0.6, 0.4, 0.25]
    private static let timescale: UInt32 = 90_000

    /// Built fragments kept in memory (about 50 KB each): AVKit asks for the same still several times,
    /// and each build is a full decode of the keyframe.
    static let cachedFragments = 128

    let width: Int
    let height: Int
    let initSegment: Data
    private let keyframe: IFrameFragmentBuilder
    private let lock = NSLock()
    private var built: [Int: Data] = [:]
    private var builtOrder: [Int] = []

    init(keyframe: IFrameFragmentBuilder, width: Int, height: Int) {
        self.keyframe = keyframe
        self.width = width
        self.height = height
        self.initSegment = Self.makeInit(width: width, height: height)
    }

    /// Output size for a source of `codedWidth` x `codedHeight` with sample aspect `sar`, even on both
    /// axes so every JPEG decoder takes it.
    static func size(codedWidth: Int, codedHeight: Int, sarNum: Int32, sarDen: Int32,
                     maxWidth: Int = defaultWidth) -> (width: Int, height: Int)? {
        guard codedWidth > 0, codedHeight > 0 else { return nil }
        let num = sarNum > 0 ? Double(sarNum) : 1
        let den = sarDen > 0 ? Double(sarDen) : 1
        let displayWidth = Double(codedWidth) * num / den
        let w = min(maxWidth, Int(displayWidth.rounded()))
        let h = Double(w) * Double(codedHeight) / displayWidth
        let even = { (v: Double) in max(2, Int((v / 2).rounded()) * 2) }
        return (even(Double(w)), even(h))
    }

    /// Highest declared bitrate a fragment can reach: the byte cap over the shortest segment.
    static func bandwidth(shortestSegmentSeconds: Double) -> Int {
        let seconds = max(shortestSegmentSeconds, 0.1)
        return Int((Double(maxFrameBytes + 256) * 8 / seconds).rounded(.up))
    }

    func build(payload: Data, index: Int, startSeconds: Double,
               durationSeconds: Double) -> IFrameFragmentBuilder.Output? {
        if let hit = lock.withLock({ built[index] }) {
            return IFrameFragmentBuilder.Output(initSegment: initSegment, fragment: hit)
        }
        guard let source = keyframe.build(payload: payload, index: index, startSeconds: startSeconds,
                                          durationSeconds: durationSeconds),
              let picture = Self.decode(source),
              let jpeg = Self.encode(picture, width: width, height: height) else { return nil }
        let fragment = Self.makeFragment(jpeg: jpeg, sequence: UInt32(truncatingIfNeeded: index + 1),
                                         startSeconds: startSeconds, durationSeconds: durationSeconds)
        lock.withLock {
            if built.updateValue(fragment, forKey: index) == nil { builtOrder.append(index) }
            if builtOrder.count > Self.cachedFragments { built[builtOrder.removeFirst()] = nil }
        }
        return IFrameFragmentBuilder.Output(initSegment: initSegment, fragment: fragment)
    }

    private static func decode(_ source: IFrameFragmentBuilder.Output) -> CGImage? {
        let context = FrameDecodeContext(reader: DataIOReader(parts: [source.initSegment, source.fragment]),
                                         formatHint: "mp4")
        defer { context.close() }
        do { try context.ensureOpen() } catch { return nil }
        return context.decodeFrame(at: 0, mode: .thumbnail, targetWidth: defaultWidth,
                                   maxSize: nil, isCancelled: { false })
    }

    static func encode(_ image: CGImage, width: Int, height: Int) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = ctx.makeImage() else { return nil }
        var last: Data?
        for quality in qualities {
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return nil }
            last = out as Data
            if out.length <= maxFrameBytes { return last }
        }
        return last.flatMap { $0.count <= maxFrameBytes ? $0 : nil }
    }

    // MARK: - ISO BMFF

    private static func box(_ type: String, _ body: Data) -> Data {
        var out = Data()
        out.append(be32(UInt32(8 + body.count)))
        out.append(contentsOf: Array(type.utf8))
        out.append(body)
        return out
    }
    private static func fullBox(_ type: String, version: UInt8, flags: UInt32, _ body: Data) -> Data {
        var head = be32(flags & 0x00FF_FFFF)
        head[head.startIndex] = version
        return box(type, cat([head, body]))
    }
    private static func be16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
    private static func be32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
    private static func be64(_ v: UInt64) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
    private static func zeros(_ n: Int) -> Data { Data(count: n) }
    private static let unityMatrix: Data = [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000]
        .reduce(into: Data()) { $0.append(be32($1)) }

    private static func cat(_ parts: [Data]) -> Data { parts.reduce(into: Data()) { $0.append($1) } }

    /// The layout of Apple's `adv_dv_atmos` motion JPEG tier: an `mjpg` sample entry with BT.709 `colr`.
    static func makeInit(width: Int, height: Int) -> Data {
        let ftyp = box("ftyp", cat([Data("iso6".utf8), be32(0), Data("iso6mp41".utf8)]))
        let mvhd = fullBox("mvhd", version: 0, flags: 0, cat([
            be32(0), be32(0), be32(timescale), be32(0), be32(0x0001_0000), be16(0x0100),
            zeros(10), unityMatrix, zeros(24), be32(2)]))
        let tkhd = fullBox("tkhd", version: 0, flags: 3, cat([
            be32(0), be32(0), be32(1), be32(0), be32(0), zeros(8), zeros(8), unityMatrix,
            be32(UInt32(width) << 16), be32(UInt32(height) << 16)]))
        let mdhd = fullBox("mdhd", version: 0, flags: 0, cat([
            be32(0), be32(0), be32(timescale), be32(0), be16(0x55C4), be16(0)]))
        let hdlr = fullBox("hdlr", version: 0, flags: 0, cat([
            be32(0), Data("vide".utf8), zeros(12), Data("VideoHandler\0".utf8)]))
        let vmhd = fullBox("vmhd", version: 0, flags: 1, zeros(8))
        let dref = fullBox("dref", version: 0, flags: 0, cat([be32(1), fullBox("url ", version: 0, flags: 1, Data())]))
        let dinf = box("dinf", dref)
        let colr = box("colr", cat([Data("nclx".utf8), be16(1), be16(1), be16(1), Data([0x00])]))
        let pasp = box("pasp", cat([be32(1), be32(1)]))
        let entry = box("mjpg", cat([
            zeros(6), be16(1), zeros(16), be16(UInt16(width)), be16(UInt16(height)),
            be32(0x0048_0000), be32(0x0048_0000), be32(0), be16(1), zeros(32),
            be16(0x0018), be16(0xFFFF), colr, pasp]))
        let stsd = fullBox("stsd", version: 0, flags: 0, cat([be32(1), entry]))
        let stts = fullBox("stts", version: 0, flags: 0, be32(0))
        let stsc = fullBox("stsc", version: 0, flags: 0, be32(0))
        let stsz = fullBox("stsz", version: 0, flags: 0, cat([be32(0), be32(0)]))
        let stco = fullBox("stco", version: 0, flags: 0, be32(0))
        let stbl = box("stbl", cat([stsd, stts, stsc, stsz, stco]))
        let minf = box("minf", cat([vmhd, dinf, stbl]))
        let trak = box("trak", cat([tkhd, box("mdia", cat([mdhd, hdlr, minf]))]))
        let trex = fullBox("trex", version: 0, flags: 0, cat([be32(1), be32(1), be32(0), be32(0), be32(0)]))
        return cat([ftyp, box("moov", cat([mvhd, trak, box("mvex", trex)]))])
    }

    static func makeFragment(jpeg: Data, sequence: UInt32, startSeconds: Double,
                             durationSeconds: Double) -> Data {
        let start = UInt64(max(0, (startSeconds * Double(timescale)).rounded()))
        let duration = UInt32(max(1, (durationSeconds * Double(timescale)).rounded()))
        // default-base-is-moof, default duration, default size; trun carries only the data offset.
        let tfhd = fullBox("tfhd", version: 0, flags: 0x02_0018,
                           cat([be32(1), be32(duration), be32(UInt32(jpeg.count))]))
        let tfdt = fullBox("tfdt", version: 1, flags: 0, be64(start))
        let mfhd = fullBox("mfhd", version: 0, flags: 0, be32(sequence))
        func moof(dataOffset: UInt32) -> Data {
            let trun = fullBox("trun", version: 0, flags: 0x00_0001, cat([be32(1), be32(dataOffset)]))
            return box("moof", cat([mfhd, box("traf", cat([tfhd, tfdt, trun]))]))
        }
        let sized = moof(dataOffset: 0)
        return cat([moof(dataOffset: UInt32(sized.count + 8)), box("mdat", jpeg)])
    }
}
