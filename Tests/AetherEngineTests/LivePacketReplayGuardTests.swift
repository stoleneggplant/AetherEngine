import Foundation
import XCTest
@testable import AetherEngine

final class LivePacketReplayGuardTests: XCTestCase {
    func testVerifiedReturningPictureReplacesUnflaggedTruncatedOutgoingCopy() {
        let damaged = packet(.video, 10, payload: 0xFF)
        let intact = packet(.video, 10)
        let audio = packet(.audio, 10)
        let next = packet(.video, 11)
        let signatures = [damaged, audio, next, intact, next]
        let order = LivePacketReplayGuard.verifiedPacketOrder(signatures)
        XCTAssertEqual(order.map { signatures[$0] }.filter { $0.stream == .video }, [intact, next])
        XCTAssertEqual(order.map { signatures[$0] }.filter { $0.stream == .audio }, [audio])
        let summary = LivePacketReplayGuard.videoBoundarySummary([
            (damaged, false, false, false), (intact, false, false, false)
        ])
        XCTAssertEqual(summary.superseded, 1)
    }

    func testVerifiedBatchDoesNotCollapseDifferentPresentationTimesOrAudioPayloads() {
        let first = packet(.video, 10)
        let otherPTS = LivePacketReplayGuard.Signature(stream: .video, dts: first.dts,
            pts: first.pts + 1, payload: Data([0xFF]))
        let audioA = packet(.audio, 10), audioB = packet(.audio, 10, payload: 0xFF)
        let values = [first, audioA, otherPTS, audioB]
        XCTAssertEqual(LivePacketReplayGuard.verifiedPacketOrder(values), [0, 1, 2, 3])
    }

    func testBoundaryEvidenceRequiresAnIntactRetainedReplacement() {
        let summary = LivePacketReplayGuard.videoBoundarySummary([
            (packet(.video, 10), true, false, false),
            (packet(.video, 10, payload: 0xFF), false, false, false),
            (packet(.video, 11), true, false, false),
            (packet(.video, 11), false, true, false), // a discarded copy cannot repair a picture
            (packet(.audio, 12), true, false, false),
            (packet(.video, 12), false, false, true),
            (packet(.video, 12), false, false, true)
        ])
        XCTAssertEqual(summary.damaged, 2)
        XCTAssertEqual(summary.replaced, 1)
        XCTAssertEqual(summary.unreplaced, 1)
        XCTAssertEqual(summary.retained, 2)
        XCTAssertEqual(summary.keyframes, 1)
    }

    func testUntimedDamageCannotCompleteReplayUsingOneMatchPerTrack() {
        var guard_ = LivePacketReplayGuard()
        for stream in [LivePacketReplayGuard.Stream.video, .audio] {
            guard_.record(packet(stream, 0), sourceSeconds: 0)
        }
        _ = guard_.inspect(packet(.video, 0), sourceSeconds: 0, timeBaseSeconds: 1,
            videoFrontier: 40, audioFrontier: 40)
        guard_.noteDamagedPacket()
        _ = guard_.inspect(packet(.audio, 0), sourceSeconds: 0, timeBaseSeconds: 1,
            videoFrontier: 40, audioFrontier: 40)
        _ = guard_.inspect(packet(.video, 41), sourceSeconds: 41, timeBaseSeconds: 1,
            videoFrontier: 40, audioFrontier: 40)
        let result = guard_.inspect(packet(.audio, 41), sourceSeconds: 41, timeBaseSeconds: 1,
            videoFrontier: 40, audioFrontier: 40)
        XCTAssertEqual(result.event, .mismatch(videoPackets: 1, audioPackets: 1))
        XCTAssertNil(guard_.confirmedPrefix)
    }

    func testDamagedFirstPacketOfEitherTrackWaitsForLaterExactEvidence() {
        for leading in [LivePacketReplayGuard.Stream.video, .audio] {
            let trailing: LivePacketReplayGuard.Stream = leading == .video ? .audio : .video
            var guard_ = LivePacketReplayGuard()
            for tick in 0..<600 {
                for stream in [leading, trailing] {
                    guard_.record(packet(stream, Int64(tick)), sourceSeconds: Double(tick) / 25)
                }
            }
            for tick in 0..<3 {
                _ = guard_.inspect(packet(leading, Int64(tick)), sourceSeconds: Double(tick) / 25,
                    timeBaseSeconds: 0.04, videoFrontier: 599, audioFrontier: 599)
            }
            let first = guard_.inspect(packet(trailing, 0, payload: 0xFF), sourceSeconds: 0,
                timeBaseSeconds: 0.04, videoFrontier: 599, audioFrontier: 599)
            XCTAssertEqual(first.event, .quarantined)
            XCTAssertTrue(first.drop)
            XCTAssertNil(guard_.confirmedPrefix, "one track cannot establish a paired replay")
            for tick in 1...600 {
                for stream in [leading, trailing] {
                    if stream == leading && tick < 3 { continue }
                    let result = guard_.inspect(packet(stream, Int64(tick)), sourceSeconds: Double(tick) / 25,
                        timeBaseSeconds: 0.04, videoFrontier: 599, audioFrontier: 599)
                    XCTAssertEqual(result.drop, tick < 600)
                    if tick == 600 && stream == trailing {
                        guard case .finished = result.event else { return XCTFail("must reach unique media") }
                    }
                }
            }
        }
    }

    func testLeadingUnmatchedTrackRemainsBoundedAndCannotCommitWithoutMatching() {
        var guard_ = LivePacketReplayGuard()
        for tick in 0..<40 {
            for stream in [LivePacketReplayGuard.Stream.video, .audio] {
                guard_.record(packet(stream, Int64(tick)), sourceSeconds: Double(tick) / 25)
            }
        }
        _ = guard_.inspect(packet(.video, 0), sourceSeconds: 0,
            timeBaseSeconds: 0.04, videoFrontier: 39, audioFrontier: 39)
        for tick in 0...12 {
            let result = guard_.inspect(packet(.audio, Int64(tick), payload: 0xFF),
                sourceSeconds: Double(tick) / 25, timeBaseSeconds: 0.04,
                videoFrontier: 39, audioFrontier: 39)
            XCTAssertTrue(result.drop)
        }
        var frontier = guard_
        _ = frontier.inspect(packet(.video, 40), sourceSeconds: 1.6,
            timeBaseSeconds: 0.04, videoFrontier: 39, audioFrontier: 39)
        let incomplete = frontier.inspect(packet(.audio, 40), sourceSeconds: 1.6,
            timeBaseSeconds: 0.04, videoFrontier: 39, audioFrontier: 39)
        XCTAssertEqual(incomplete.event, .mismatch(videoPackets: 1, audioPackets: 0))
        let bounded = guard_.inspect(packet(.audio, 13, payload: 0xFF), sourceSeconds: 0.52,
            timeBaseSeconds: 0.04, videoFrontier: 39, audioFrontier: 39)
        XCTAssertEqual(bounded.event, .mismatch(videoPackets: 1, audioPackets: 0))
        XCTAssertNil(guard_.confirmedPrefix)
    }

    func testShortDamagedPacketAfterThreeVideoAndOneAudioMatchesDoesNotReleaseReplay() {
        var guard_ = LivePacketReplayGuard()
        for tick in 0..<600 {
            for stream in [LivePacketReplayGuard.Stream.video, .audio] {
                guard_.record(packet(stream, Int64(tick)), sourceSeconds: Double(tick) / 25)
            }
        }
        for tick in 0..<3 {
            _ = guard_.inspect(packet(.video, Int64(tick)), sourceSeconds: Double(tick) / 25,
                timeBaseSeconds: 0.04, videoFrontier: 599, audioFrontier: 599)
        }
        _ = guard_.inspect(packet(.audio, 0), sourceSeconds: 0,
            timeBaseSeconds: 0.04, videoFrontier: 599, audioFrontier: 599)
        let damaged = guard_.inspect(packet(.video, 3, payload: 0xFF), sourceSeconds: 0.12,
            timeBaseSeconds: 0.04, videoFrontier: 599, audioFrontier: 599)
        XCTAssertTrue(damaged.drop)
        XCTAssertEqual(damaged.event, .quarantined, "the tvOS trace used to flush the whole old interval here")
        for tick in 1..<601 {
            for stream in [LivePacketReplayGuard.Stream.video, .audio] {
                if stream == .video && tick < 4 { continue }
                let result = guard_.inspect(packet(stream, Int64(tick)), sourceSeconds: Double(tick) / 25,
                    timeBaseSeconds: 0.04, videoFrontier: 599, audioFrontier: 599)
                XCTAssertEqual(result.drop, tick < 600)
                if tick == 600 && stream == .audio {
                    guard case .finished = result.event else { return XCTFail("must reach new media") }
                }
            }
        }
        XCTAssertFalse(guard_.isDroppingReplay)
    }

    func testDamagedFrontierPacketDoesNotRequireOpeningTheSameReplayAgain() {
        var guard_ = LivePacketReplayGuard()
        for tick in 0..<600 {
            for stream in [LivePacketReplayGuard.Stream.video, .audio] {
                guard_.record(packet(stream, Int64(tick)), sourceSeconds: Double(tick) / 25)
            }
        }
        for tick in 0..<601 {
            for stream in [LivePacketReplayGuard.Stream.video, .audio] {
                let result = guard_.inspect(packet(stream, Int64(tick), payload: tick == 599 ? 0xFF : nil),
                    sourceSeconds: Double(tick) / 25, timeBaseSeconds: 0.04,
                    videoFrontier: 599, audioFrontier: 599)
                XCTAssertEqual(result.drop, tick < 600)
                if tick < 600 { XCTAssertFalse(result.event == .interrupted(videoPackets: 599, audioPackets: 599)) }
            }
        }
        XCTAssertFalse(guard_.isDroppingReplay)
    }
    func testFreshProducerContinuationRecognizesShortCachedOverlap() {
        var original = LivePacketReplayGuard()
        for tick in 0..<40 {
            original.record(packet(.video, Int64(tick)), sourceSeconds: Double(tick))
            original.record(packet(.audio, Int64(tick)), sourceSeconds: Double(tick))
        }
        var continuation = original.sourceContinuation()
        original.reset() // the retired producer can free its own state independently
        for tick in 37..<39 {
            for stream in [LivePacketReplayGuard.Stream.video, .audio] {
                let decision = continuation.inspect(packet(stream, Int64(tick)), sourceSeconds: Double(tick),
                    timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: 39, hasAudio: true)
                XCTAssertTrue(decision.drop, "cached media must not be appended again after a fresh connection")
            }
        }
        XCTAssertNotNil(continuation.confirmedPrefix)
        let divergence = continuation.inspect(packet(.video, 39, payload: 0xFF), sourceSeconds: 39,
            timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: 39, hasAudio: true)
        XCTAssertEqual(divergence.event, .interrupted(videoPackets: 2, audioPackets: 2))
    }

    func testContinuationResetAllowsIntentionalSeekAndDifferentContent() {
        var original = LivePacketReplayGuard()
        for tick in 0..<40 { original.record(packet(.video, Int64(tick)), sourceSeconds: Double(tick)) }
        var continuation = original.sourceContinuation()
        let newContent = continuation.inspect(packet(.video, 20, payload: 0xFF), sourceSeconds: 20,
            timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: .min)
        XCTAssertTrue(newContent.drop, "a timestamp-only match is provisional")
        let divergent = continuation.inspect(packet(.video, 21, payload: 0xFF), sourceSeconds: 21,
            timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: .min)
        XCTAssertEqual(divergent.event, .mismatch(videoPackets: 0, audioPackets: 0))
        XCTAssertNil(continuation.confirmedPrefix)
        continuation.reset()
        let seekReplay = continuation.inspect(packet(.video, 20), sourceSeconds: 20,
            timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: .min)
        XCTAssertFalse(seekReplay.drop)
        XCTAssertNil(seekReplay.event)
    }

    private func packet(_ stream: LivePacketReplayGuard.Stream, _ tick: Int64,
                        payload: UInt8? = nil) -> LivePacketReplayGuard.Signature {
        .init(stream: stream, dts: tick, pts: tick,
              payload: Data([payload ?? UInt8(truncatingIfNeeded: tick), 0xA5]))
    }

    func testExactVideoAndAudioReplayResumesAtFirstNewPackets() {
        var guard_ = LivePacketReplayGuard()
        for tick in 0..<40 {
            guard_.record(packet(.video, Int64(tick)), sourceSeconds: Double(tick))
            guard_.record(packet(.audio, Int64(tick)), sourceSeconds: Double(tick))
        }

        for tick in 20..<40 {
            let video = guard_.inspect(packet(.video, Int64(tick)), sourceSeconds: Double(tick),
                                       timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: 39)
            XCTAssertTrue(video.drop)
            if tick == 20 { XCTAssertEqual(video.event, .began) }
            let audio = guard_.inspect(packet(.audio, Int64(tick)), sourceSeconds: Double(tick),
                                       timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: 39)
            XCTAssertTrue(audio.drop)
        }

        let newVideo = guard_.inspect(packet(.video, 40), sourceSeconds: 40,
                                      timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: 39)
        XCTAssertFalse(newVideo.drop)
        XCTAssertNil(newVideo.event)
        let newAudio = guard_.inspect(packet(.audio, 40), sourceSeconds: 40,
                                      timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: 39)
        XCTAssertFalse(newAudio.drop)
        XCTAssertEqual(newAudio.event, .finished(videoPackets: 20, audioPackets: 20,
                                                 videoSeconds: 19))
        XCTAssertFalse(guard_.isDroppingReplay)
    }

    func testClockResetWithNewContentRollsBackItsProvisionalCandidate() {
        var guard_ = LivePacketReplayGuard()
        for tick in 0..<40 {
            guard_.record(packet(.video, Int64(tick)), sourceSeconds: Double(tick))
        }
        let result = guard_.inspect(packet(.video, 20, payload: 0xFF), sourceSeconds: 20,
                                    timeBaseSeconds: 1, videoFrontier: 39,
                                    audioFrontier: Int64.min)
        XCTAssertTrue(result.drop)
        XCTAssertEqual(result.event, .quarantined)
        XCTAssertNil(guard_.confirmedPrefix)
        let next = guard_.inspect(packet(.video, 21, payload: 0xFF), sourceSeconds: 21,
                                  timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: .min)
        XCTAssertEqual(next.event, .mismatch(videoPackets: 0, audioPackets: 0))
        XCTAssertFalse(guard_.isDroppingReplay, "the producer must forward the entire candidate")
    }

    func testAudioCanReachTheOverlapBeforeVideo() {
        var guard_ = LivePacketReplayGuard()
        for tick in 0..<40 {
            guard_.record(packet(.video, Int64(tick)), sourceSeconds: Double(tick))
            guard_.record(packet(.audio, Int64(tick)), sourceSeconds: Double(tick))
        }
        let firstAudio = guard_.inspect(packet(.audio, 20), sourceSeconds: 20,
                                        timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: 39)
        XCTAssertTrue(firstAudio.drop)
        XCTAssertEqual(firstAudio.event, .began)
        XCTAssertTrue(guard_.inspect(packet(.video, 20), sourceSeconds: 20,
                                     timeBaseSeconds: 1, videoFrontier: 39,
                                     audioFrontier: 39).drop)
    }

    func testFirstDifferentPacketInsideReplayIsForwarded() {
        var guard_ = LivePacketReplayGuard()
        for tick in 0..<40 {
            guard_.record(packet(.video, Int64(tick)), sourceSeconds: Double(tick))
        }
        XCTAssertTrue(guard_.inspect(packet(.video, 20), sourceSeconds: 20,
                                     timeBaseSeconds: 1, videoFrontier: 39,
                                     audioFrontier: Int64.min).drop)
        let different = guard_.inspect(packet(.video, 21, payload: 0xFF), sourceSeconds: 21,
                                       timeBaseSeconds: 1, videoFrontier: 39,
                                       audioFrontier: Int64.min)
        XCTAssertFalse(different.drop)
        XCTAssertEqual(different.event, .mismatch(videoPackets: 1, audioPackets: 0))
    }

    func testOldHistoryCannotSuppressNewContent() {
        var guard_ = LivePacketReplayGuard()
        for tick in 0..<100 {
            guard_.record(packet(.video, Int64(tick)), sourceSeconds: Double(tick))
        }
        let old = guard_.inspect(packet(.video, 20), sourceSeconds: 20,
                                 timeBaseSeconds: 1, videoFrontier: 99,
                                 audioFrontier: Int64.min)
        XCTAssertFalse(old.drop)
    }

    func testLongPairedOverlapRequiresFreshSourceWhenEitherTrackDiverges() {
        for changedStream in [LivePacketReplayGuard.Stream.video, .audio] {
            var guard_ = LivePacketReplayGuard()
            for tick in 0..<40 {
                for stream in [LivePacketReplayGuard.Stream.video, .audio] {
                    guard_.record(packet(stream, Int64(tick)), sourceSeconds: Double(tick))
                }
            }
            for tick in 20..<24 {
                for stream in [LivePacketReplayGuard.Stream.audio, .video] {
                    XCTAssertTrue(guard_.inspect(packet(stream, Int64(tick)),
                        sourceSeconds: Double(tick), timeBaseSeconds: 1,
                        videoFrontier: 39, audioFrontier: 39).drop)
                }
            }
            let changed = guard_.inspect(packet(changedStream, 24, payload: 0xFF),
                sourceSeconds: 24, timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: 39)
            XCTAssertFalse(changed.drop, "different media is not classified as a duplicate")
            XCTAssertEqual(changed.event, .interrupted(videoPackets: 4, audioPackets: 4))
            XCTAssertNotNil(guard_.confirmedPrefix, "producer must stop rather than remux the prefix")
        }
    }

    func testOneMatchingTrackCannotConfirmAProgrammeBoundary() {
        var guard_ = LivePacketReplayGuard()
        for tick in 0..<40 {
            for stream in [LivePacketReplayGuard.Stream.video, .audio] {
                guard_.record(packet(stream, Int64(tick)), sourceSeconds: Double(tick))
            }
        }
        for tick in 20..<24 {
            _ = guard_.inspect(packet(.video, Int64(tick)), sourceSeconds: Double(tick),
                timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: 39)
        }
        _ = guard_.inspect(packet(.audio, 20), sourceSeconds: 20,
            timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: 39)
        XCTAssertNil(guard_.confirmedPrefix)
        let changed = guard_.inspect(packet(.audio, 21, payload: 0xFF), sourceSeconds: 21,
            timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: 39)
        XCTAssertEqual(changed.event, .mismatch(videoPackets: 4, audioPackets: 1))
        XCTAssertFalse(guard_.isDroppingReplay)
    }

    func testNestedRollbackDoesNotEraseAlreadyConfirmedOverlap() {
        var guard_ = LivePacketReplayGuard()
        for tick in 0..<40 {
            guard_.record(packet(.video, Int64(tick)), sourceSeconds: Double(tick))
        }
        for tick in [20, 21, 22, 23, 20] {
            _ = guard_.inspect(packet(.video, Int64(tick)), sourceSeconds: Double(tick),
                timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: Int64.min)
        }
        XCTAssertNotNil(guard_.confirmedPrefix)
        let changed = guard_.inspect(packet(.video, 21, payload: 0xFF), sourceSeconds: 21,
            timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: Int64.min)
        XCTAssertEqual(changed.event, .interrupted(videoPackets: 5, audioPackets: 0))
        guard_.reset()
        XCTAssertNil(guard_.confirmedPrefix)
        XCTAssertFalse(guard_.isDroppingReplay)
    }

    func testSubthresholdPairedMatchesRemainAmbiguous() {
        var guard_ = LivePacketReplayGuard()
        for tick in 0..<40 {
            for stream in [LivePacketReplayGuard.Stream.video, .audio] {
                guard_.record(packet(stream, Int64(tick)), sourceSeconds: Double(tick))
            }
        }
        for tick in 20..<22 {
            for stream in [LivePacketReplayGuard.Stream.video, .audio] {
                _ = guard_.inspect(packet(stream, Int64(tick)), sourceSeconds: Double(tick),
                    timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: 39)
            }
        }
        XCTAssertNil(guard_.confirmedPrefix)
        let changed = guard_.inspect(packet(.video, 22, payload: 0xFF), sourceSeconds: 22,
            timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: 39)
        XCTAssertEqual(changed.event, .mismatch(videoPackets: 2, audioPackets: 2))
    }

    func testSustainedThirtyFPSAndAACOverlapCannotRollbackAfterDivergence() {
        var guard_ = LivePacketReplayGuard()
        for frame in 0..<1_350 {
            guard_.record(packet(.video, Int64(frame * 3_000)), sourceSeconds: Double(frame) / 30)
        }
        for frame in 0..<2_110 {
            guard_.record(packet(.audio, Int64(frame * 1_024)),
                          sourceSeconds: Double(frame * 1_024) / 48_000)
        }
        var replay: [(LivePacketReplayGuard.Signature, Double, Double)] = []
        for frame in 300..<(300 + 738) {
            replay.append((packet(.video, Int64(frame * 3_000)), Double(frame) / 30, 1 / 90_000))
        }
        for frame in 469..<(469 + 1_147) {
            replay.append((packet(.audio, Int64(frame * 1_024)),
                           Double(frame * 1_024) / 48_000, 1 / 48_000))
        }
        replay.sort { $0.1 < $1.1 }
        for (signature, seconds, timeBase) in replay {
            XCTAssertTrue(guard_.inspect(signature, sourceSeconds: seconds,
                timeBaseSeconds: timeBase, videoFrontier: 1_349 * 3_000,
                audioFrontier: 2_109 * 1_024).drop)
        }
        // One changed AAC packet can be a damaged PES boundary. Sustained different audio
        // beyond the bounded quarantine still requires fresh negotiation.
        let changed = guard_.inspect(packet(.audio, 1_650 * 1_024, payload: 0xFF),
            sourceSeconds: Double(1_650 * 1_024) / 48_000, timeBaseSeconds: 1 / 48_000,
            videoFrontier: 1_349 * 3_000, audioFrontier: 2_109 * 1_024)
        XCTAssertEqual(changed.event, .interrupted(videoPackets: 738, audioPackets: 1_147))
        XCTAssertFalse(changed.drop)
        XCTAssertNotNil(guard_.confirmedPrefix)
    }

    func testConfiguredAudioWithoutAcceptedHistoryCannotVerifyAReplay() {
        var guard_ = LivePacketReplayGuard()
        for tick in 0..<40 {
            guard_.record(packet(.video, Int64(tick)), sourceSeconds: Double(tick))
        }
        for tick in 20..<24 {
            _ = guard_.inspect(packet(.video, Int64(tick)), sourceSeconds: Double(tick),
                timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: Int64.min, hasAudio: true)
        }
        XCTAssertNil(guard_.confirmedPrefix, "configured audio has supplied no evidence yet")
        let firstAudio = guard_.inspect(packet(.audio, 24), sourceSeconds: 24,
            timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: Int64.min, hasAudio: true)
        XCTAssertEqual(firstAudio.event, .mismatch(videoPackets: 4, audioPackets: 0))
        XCTAssertFalse(firstAudio.drop, "the new audio remains on the ordinary programme-boundary path")
        XCTAssertFalse(guard_.isDroppingReplay)
    }
}
