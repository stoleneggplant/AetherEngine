import Foundation
import Testing
import AetherLibavcodec
@testable import AetherEngine

struct LiveReplayPacketReaderTests {
    struct Sample {
        var stream: Int32
        var time: Int64
        var byte: UInt8 = 1
        var corrupt = false
    }
    private func packets(_ range: Range<Int64>, byte: UInt8 = 1) -> [Sample] {
        range.flatMap { [Sample(stream: 0, time: $0, byte: byte), Sample(stream: 1, time: $0, byte: byte)] }
    }
    private func reader() -> LiveReplayPacketReader {
        .init(videoIndex: 0, audioIndex: 1, videoTimeBase: 0.1, audioTimeBase: 0.1)
    }
    private func read(_ input: [Sample], reader: LiveReplayPacketReader) throws -> [Sample] {
        var index = 0
        var result: [Sample] = []
        while let packet = try reader.read(from: {
            guard index < input.count else { return nil }
            let sample = input[index]; index += 1
            let packet = try #require(av_packet_alloc())
            #expect(av_new_packet(packet, 1) == 0)
            packet.pointee.stream_index = sample.stream
            packet.pointee.pts = sample.time; packet.pointee.dts = sample.time
            packet.pointee.data[0] = sample.byte
            if sample.corrupt { packet.pointee.flags |= AV_PKT_FLAG_CORRUPT }
            return packet
        }) {
            result.append(.init(stream: packet.pointee.stream_index, time: packet.pointee.dts,
                                byte: packet.pointee.data[0]))
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&owned)
        }
        return result
    }

    @Test("repeated source reconnects do not advance the software DVR timeline twice")
    func repeatedReplay() throws {
        let input = packets(0..<40) + packets(0..<60) + packets(20..<80)
        let output = try read(input, reader: reader())
        #expect(output.map(\.time) == packets(0..<80).map(\.time))
        #expect(output.map(\.stream) == packets(0..<80).map(\.stream))
    }

    @Test("a final duplicate PES released after paired verification is still removed")
    func duplicateAtCompletedSeam() throws {
        let input = packets(0..<40) + packets(0..<41)
            + [Sample(stream: 0, time: 40)] + packets(41..<60)
        let output = try read(input, reader: reader())
        #expect(output.map(\.time) == packets(0..<60).map(\.time))
    }

    @Test("a new programme with reset timestamps keeps every packet")
    func timestampResetIsNotReplay() throws {
        let input = packets(0..<40) + packets(0..<50, byte: 2)
        let output = try read(input, reader: reader())
        #expect(output.count == input.count)
        #expect(output.map(\.byte) == input.map(\.byte))
    }

    @Test("timed corrupt audio beyond the old frontier stays out of a verified replay commit")
    func damagedBoundary() throws {
        let input = packets(0..<40)
            + packets(0..<30)
            + [Sample(stream: 1, time: 41, byte: 9, corrupt: true)]
            + packets(30..<50)
        let output = try read(input, reader: reader())
        #expect(!output.contains { $0.byte == 9 })
        #expect(output.count == packets(0..<50).count)
    }

    @Test("a truncated last video PES is replaced by its intact returning copy")
    func damagedFrontierBeforeReplay() throws {
        let input = packets(0..<40)
            + [Sample(stream: 0, time: 40, byte: 9, corrupt: true)]
            + packets(0..<50)
        let output = try read(input, reader: reader())
        #expect(output.map(\.time) == packets(0..<50).map(\.time))
        #expect(output.map(\.stream) == packets(0..<50).map(\.stream))
        #expect(output.allSatisfy { $0.byte == 1 }, "the damaged frontier must not poison the retained history")
    }

    @Test("a flagged video packet followed by fresh media is preserved without proof of replay")
    func ambiguousDamageKeepsFreshMedia() throws {
        let input = packets(0..<40)
            + [Sample(stream: 0, time: 40, byte: 9, corrupt: true)]
            + packets(41..<50)
        let output = try read(input, reader: reader())
        for stream: Int32 in [0, 1] {
            #expect(output.filter { $0.stream == stream }.map(\.time) == input.filter { $0.stream == stream }.map(\.time))
            #expect(output.filter { $0.stream == stream }.map(\.byte) == input.filter { $0.stream == stream }.map(\.byte))
        }
    }

    @Test("untimed fragments stay behind the damaged boundary until replay is proven", arguments: [false, true])
    func untimedOutgoingFragment(verified: Bool) throws {
        let damaged = [Sample(stream: 0, time: 40, byte: 9, corrupt: true),
                       Sample(stream: 0, time: .min, byte: 8)]
        let input = packets(0..<40) + damaged + packets(verified ? 0..<50 : 41..<50)
        let output = try read(input, reader: reader())
        if verified {
            #expect(output.map(\.time) == packets(0..<50).map(\.time))
            #expect(output.map(\.stream) == packets(0..<50).map(\.stream))
            #expect(output.allSatisfy { $0.byte == 1 })
        } else {
            // No rollback proof: preserve every packet, including the untimed one.
            #expect(output.count == input.count)
            #expect(output.filter { $0.stream == 0 }.map(\.time)
                == input.filter { $0.stream == 0 }.map(\.time))
        }
    }

    @Test("an outgoing good picture arriving after audio rollback is kept once in decode order")
    func outgoingPictureDuringDamagedBoundary() throws {
        let input = packets(0..<40)
            + [Sample(stream: 0, time: 40, byte: 9, corrupt: true),
               Sample(stream: 1, time: 0), Sample(stream: 0, time: 41)]
            + packets(0..<50)
        let output = try read(input, reader: reader())
        #expect(output.filter { $0.stream == 0 }.map(\.time) == Array(0..<50).map(Int64.init))
        #expect(output.allSatisfy { $0.byte == 1 })
    }

    @Test("an outgoing good picture before rollback cannot release a damaged video boundary")
    func outgoingPictureBeforeRollback() throws {
        let input = packets(0..<40)
            + [Sample(stream: 0, time: 40, byte: 9, corrupt: true),
               Sample(stream: 0, time: 41)]
            + packets(0..<50)
        let output = try read(input, reader: reader())
        #expect(output.filter { $0.stream == 0 }.map(\.time) == Array(0..<50).map(Int64.init))
        #expect(output.allSatisfy { $0.byte == 1 }, "a clean outgoing straggler must not release the damaged frontier before rollback")
    }

    @Test("an unverified damaged tail at EOF preserves the original media")
    func damagedTailAtEOF() throws {
        let input = packets(0..<40) + [Sample(stream: 0, time: 40, byte: 9, corrupt: true)]
        let output = try read(input, reader: reader())
        #expect(output.map(\.time) == input.map(\.time))
        #expect(output.map(\.byte) == input.map(\.byte))
    }

    @Test("interrupted verified replay is never admitted as new media")
    func interrupted() throws {
        #expect(throws: LiveReplayPacketReader.Failure.self) {
            try read(packets(0..<40) + packets(0..<30), reader: reader())
        }
    }

    @Test("explicit positioning resets history, cancellation releases quarantine")
    func resetAndCancel() throws {
        let source = reader()
        _ = try read(packets(0..<40), reader: source)
        source.reset()
        #expect(try read(packets(0..<20), reader: source).count == 40)
        #expect(try source.read(isCurrent: { false }, from: { nil }) == nil)
        #expect(try read(packets(0..<20), reader: source).count == 40)
    }
}
