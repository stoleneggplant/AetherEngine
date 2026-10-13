import Testing
@testable import AetherEngine

struct VideoProgressTests {
    @Test("audio progress with a missing video presentation repairs twice, without an endless reload loop")
    func presentationRecovery() {
        var monitor = VideoPresentationProgress()
        var actions: [VideoPresentationProgress.Action] = []
        for tick in 0..<200 {
            let t = Double(tick) / 10
            if let action = monitor.observe(clock: 400 + t, now: t, eligible: true,
                missingVideo: true, frameDuration: 0.04) { actions.append(action) }
        }
        #expect(actions == [.nudge, .reload])
        // Only a sustained healthy presentation rearms repairs; an item swap's short rise doesn't.
        for tick in 200..<260 {
            let t = Double(tick) / 10
            #expect(monitor.observe(clock: 400 + t, now: t, eligible: true,
                missingVideo: false, frameDuration: 0.04) == nil)
        }
        #expect(monitor.attempts == 0)
    }

    @Test("short video glitches, a stopped clock and ineligible presentation do not seek")
    func presentationExclusions() {
        for mode in 0..<3 {
            var monitor = VideoPresentationProgress()
            for tick in 0..<100 {
                let t = Double(tick) / 10
                #expect(monitor.observe(clock: mode == 0 ? 100 : 100 + t, now: t,
                    eligible: mode != 1, missingVideo: mode != 2 || tick.isMultiple(of: 10),
                    frameDuration: 0.04) == nil)
            }
        }
    }

    @Test("seeks, delayed observations and low frame rates restart the video repair grace")
    func presentationDiscontinuities() {
        var monitor = VideoPresentationProgress()
        for tick in 0..<20 {
            let t = Double(tick) / 10
            #expect(monitor.observe(clock: t, now: t, eligible: true,
                missingVideo: true, frameDuration: 0.04) == nil)
        }
        #expect(monitor.observe(clock: 100, now: 5, eligible: true,
            missingVideo: true, frameDuration: 0.04) == nil)
        #expect(monitor.observe(clock: 100.1, now: 5.1, eligible: true,
            missingVideo: true, frameDuration: 0.04) == nil)
        monitor = VideoPresentationProgress()
        for tick in 0..<50 {
            let t = Double(tick) / 10
            #expect(monitor.observe(clock: t, now: t, eligible: true,
                missingVideo: true, frameDuration: 1) == nil)
        }
    }

    @Test("ready layers with sustained decoded-output stalls repair; short device gaps do not")
    func readyButStalled() {
        // Durations observed on the four-device run: only sustained gaps warrant disruption.
        for gap in [0.53, 0.69, 1.0, 1.18, 4.28, 5.17, 9.55] {
            var frames = warmed()
            var presentation = VideoPresentationProgress()
            var actions: [VideoPresentationProgress.Action] = []
            for tick in 5...Int((gap + 0.2) * 20) {
                let t = Double(tick) / 20
                _ = frames.observe(frame: nil, clock: t, now: t, eligible: true, frameDuration: 0.04)
                let stalled = frames.isStalled(at: t, lastSampleAt: t, frameDuration: 0.04)
                if let action = presentation.observe(clock: t, now: t, eligible: true,
                    missingVideo: stalled, frameDuration: 0.04, hasHealthyVideo: !stalled) {
                    actions.append(action)
                }
            }
            #expect(actions == (gap < 3 ? [] : gap < 7 ? [.nudge] : [.nudge, .reload]))
        }
    }

    @Test("unavailable or delayed video output cannot trigger repair or rearm spent attempts")
    func staleOutputAndUnknownHealth() {
        var frames = warmed()
        _ = frames.observe(frame: nil, clock: 0.8, now: 0.8, eligible: true, frameDuration: 0.04)
        #expect(frames.isStalled(at: 0.8, lastSampleAt: 0.8, frameDuration: 0.04))
        #expect(!frames.isStalled(at: 1.2, lastSampleAt: 0.8, frameDuration: 0.04))
        #expect(!frames.isStalled(at: 0.8, lastSampleAt: nil, frameDuration: 0.04))
        frames.reset()
        #expect(!frames.isStalled(at: 20, lastSampleAt: 20, frameDuration: 0.04))
        var monitor = VideoPresentationProgress()
        for tick in 0..<200 {
            let t = Double(tick) / 10
            _ = monitor.observe(clock: t, now: t, eligible: true,
                missingVideo: tick < 80, frameDuration: 0.04, hasHealthyVideo: false)
        }
        #expect(monitor.attempts == 2, "a ready flag or detached output alone never rearms repairs")
    }

    @Test("an unsuccessful internal repair keeps evidence through its temporary transport wait")
    func pendingRepairSurvivesWaitingButNotUserTransitions() {
        var frames = warmed()
        frames.beginRecovery()
        frames.reset(preservingRecovery: true)
        #expect(frames.recoveryPending)
        #expect(!frames.isStalled(at: 10, lastSampleAt: nil, frameDuration: 0.04))
        _ = frames.observe(frame: nil, clock: 1, now: 10, eligible: true, frameDuration: 0.04)
        #expect(!frames.isStalled(at: 10, lastSampleAt: 10, frameDuration: 0.04))
        _ = frames.observe(frame: nil, clock: 1.5, now: 10.5, eligible: true, frameDuration: 0.04)
        #expect(frames.isStalled(at: 10.5, lastSampleAt: 10.5, frameDuration: 0.04))
        _ = frames.observe(frame: 1.6, clock: 1.6, now: 10.6, eligible: true, frameDuration: 0.04)
        #expect(!frames.recoveryPending)
        frames = warmed(); frames.beginRecovery(); frames.reset()
        #expect(!frames.recoveryPending, "PiP, pause, seek and a new session discard stale repair evidence")
    }

    private func warmed() -> VideoFrameProgress {
        var monitor = VideoFrameProgress()
        for time in [0.0, 0.1, 0.2] {
            _ = monitor.observe(frame: time, clock: time, now: time, eligible: true, frameDuration: 0.04)
        }
        return monitor
    }

    @Test("video output stops while the item clock advances, then resumes once")
    func shortVideoOnlyGap() {
        var monitor = warmed()
        let began = monitor.observe(frame: nil, clock: 0.6, now: 0.6, eligible: true, frameDuration: 0.04)
        guard case .began(let age, let advance) = began else { Issue.record("missing output gap"); return }
        #expect(abs(age - 0.4) < 0.000001 && abs(advance - 0.4) < 0.000001)
        #expect(monitor.observe(frame: nil, clock: 0.7, now: 0.7, eligible: true, frameDuration: 0.04) == nil)
        let ended = monitor.observe(frame: 0.8, clock: 0.8, now: 0.8, eligible: true, frameDuration: 0.04)
        guard case .ended(let age) = ended else { Issue.record("missing output recovery"); return }
        #expect(abs(age - 0.6) < 0.000001)
    }

    @Test("a paused clock, unavailable output, seek or inactive rendering cannot report a freeze")
    func exclusions() {
        var monitor = warmed()
        #expect(monitor.observe(frame: nil, clock: 0.2, now: 0.7, eligible: true, frameDuration: 0.04) == nil)
        _ = monitor.observe(frame: nil, clock: 0.2, now: 0.8, eligible: false, frameDuration: 0.04)
        #expect(monitor.samples == 0)
        #expect(monitor.observe(frame: nil, clock: 20, now: 1, eligible: true, frameDuration: 0.04) == nil)
        monitor = warmed()
        #expect(monitor.observe(frame: nil, clock: 10, now: 0.7, eligible: true, frameDuration: 0.04) == nil)
        #expect(monitor.samples == 0)
    }

    @Test("low-frame-rate content gets its own observation allowance")
    func lowFrameRate() {
        var monitor = warmed()
        #expect(monitor.observe(frame: nil, clock: 0.8, now: 0.8, eligible: true, frameDuration: 0.5) == nil)
    }

    @Test("compressed timestamp gaps and source clock resets are separate")
    func packetGaps() {
        var monitor = VideoPacketProgress()
        for index in 0..<8 { #expect(monitor.observe(Double(index) * 0.04) == nil) }
        let gap = monitor.observe(0.8)
        #expect(gap != nil)
        #expect(abs((gap?.seconds ?? 0) - 0.52) < 0.000001)
        #expect(monitor.observe(0) == nil)
        #expect(monitor.observe(0.04) == nil)
        #expect(monitor.observe(.nan) == nil)
    }
}
