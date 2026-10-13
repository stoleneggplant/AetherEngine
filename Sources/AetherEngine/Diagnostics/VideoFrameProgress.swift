import Foundation

/// A progressing audio/item clock is not proof of a progressing video presentation.
/// The caller excludes PiP (its inline layer may legitimately be unready), external
/// playback, seeks, hidden surfaces and source starvation before offering an observation.
struct VideoPresentationProgress {
    enum Action: String { case nudge, reload }
    private var suspectClock: Double?
    private var suspectAt: Double?
    private var healthyAt: Double?
    private var lastClock: Double?
    private var lastObservation: Double?
    private(set) var attempts = 0

    mutating func observe(clock: Double, now: Double, eligible: Bool,
                          missingVideo: Bool, frameDuration: Double?,
                          hasHealthyVideo: Bool = true) -> Action? {
        defer { lastClock = clock; lastObservation = now }
        guard eligible, clock.isFinite, now.isFinite else {
            suspectClock = nil; suspectAt = nil; healthyAt = nil
            return nil
        }
        if let lastClock, let lastObservation,
           clock < lastClock || clock - lastClock > 1 || now - lastObservation > 1 {
            suspectClock = nil; suspectAt = nil; healthyAt = nil
        }
        guard missingVideo else {
            suspectClock = nil; suspectAt = nil
            guard hasHealthyVideo else { healthyAt = nil; return nil }
            if healthyAt == nil { healthyAt = now }
            // A momentary ready flag after a seek does not buy unlimited repair attempts.
            if now - (healthyAt ?? now) >= 5 { attempts = 0 }
            return nil
        }
        healthyAt = nil
        if suspectAt == nil { suspectAt = now; suspectClock = clock }
        let duration = frameDuration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
        let threshold = Swift.max(3, 6 * duration)
        guard attempts < 2, now - (suspectAt ?? now) >= threshold,
              clock - (suspectClock ?? clock) >= threshold * 0.8 else { return nil }
        attempts += 1
        suspectAt = nil; suspectClock = nil
        return attempts == 1 ? .nudge : .reload
    }
}

/// Decoded-output observations, not a count of frames physically displayed by AVPlayerLayer.
struct VideoFrameProgress {
    enum Event: Equatable {
        case began(age: Double, clockAdvance: Double)
        case ended(age: Double)
    }
    private(set) var samples = 0
    private(set) var frameTime: Double?
    private var changedAt: Double?
    private var clockAtChange: Double?
    private var lastClock: Double?
    private var gapReported = false
    private(set) var recoveryPending = false

    mutating func beginRecovery() { recoveryPending = samples >= 3 || recoveryPending }

    mutating func reset(preservingRecovery: Bool = false) {
        let pending = preservingRecovery && recoveryPending
        self = Self()
        recoveryPending = pending
    }

    func age(at now: Double) -> Double? { changedAt.map { Swift.max(0, now - $0) } }

    /// Require both a progressing clock and fresh observations. A suspended sampler
    /// or an output which never produced pictures cannot diagnose a stalled decoder.
    func isStalled(at now: Double, lastSampleAt: Double?, frameDuration: Double?) -> Bool {
        guard samples >= 3 || recoveryPending, let lastSampleAt, now >= lastSampleAt,
              now - lastSampleAt <= 0.25, let changedAt, let clockAtChange, let lastClock else { return false }
        let duration = frameDuration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
        let threshold = Swift.max(0.35, 3 * duration)
        return now - changedAt >= threshold && lastClock - clockAtChange >= threshold * 0.8
    }

    mutating func observe(frame: Double?, clock: Double, now: Double,
                          eligible: Bool, frameDuration: Double?) -> Event? {
        guard eligible, clock.isFinite, now.isFinite else { reset(); return nil }
        if let lastClock, clock < lastClock || clock - lastClock > 1 {
            reset() // seek/item swap or a delayed sampling task, never a decoder verdict
        }
        lastClock = clock
        if let frame, frame.isFinite, frame != frameTime {
            let age = changedAt.map { Swift.max(0, now - $0) }
            let recovered = gapReported
            recoveryPending = false
            samples += 1; frameTime = frame; changedAt = now; clockAtChange = clock
            gapReported = false
            return recovered ? .ended(age: age ?? 0) : nil
        }
        // An internal repair can briefly pause/detach the output. Preserve its verified
        // stall, but start a fresh grace period on resumed observation, never while waiting.
        if recoveryPending, changedAt == nil { changedAt = now; clockAtChange = clock }
        guard samples >= 3 || recoveryPending, let changedAt, let clockAtChange else { return nil }
        let age = Swift.max(0, now - changedAt)
        let advance = clock - clockAtChange
        let duration = frameDuration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
        let threshold = Swift.max(0.35, 3 * duration)
        guard !gapReported, age >= threshold, advance >= threshold * 0.8 else { return nil }
        gapReported = true
        return .began(age: age, clockAdvance: advance)
    }
}

/// Compressed packet cadence after replay admission. A gap is evidence, not a playback command.
struct VideoPacketProgress {
    struct Gap {
        let previous: Double
        let seconds: Double
        let cadence: Double
    }
    private var last: Double?
    private var intervals: [Double] = []

    var cadence: Double? {
        let ordered = intervals.sorted()
        return ordered.isEmpty ? nil : ordered[ordered.count / 2]
    }

    mutating func observe(_ seconds: Double) -> Gap? {
        guard seconds.isFinite else { return nil }
        defer { last = seconds }
        guard let previous = last else { return nil }
        let delta = seconds - previous
        guard delta > 0 else {
            if delta < 0 { intervals.removeAll(keepingCapacity: true) }
            return nil
        }
        let cadence = self.cadence
        if intervals.count >= 4, let cadence, delta > Swift.max(0.25, 5 * cadence) {
            return Gap(previous: previous, seconds: delta, cadence: cadence)
        }
        intervals.append(delta)
        if intervals.count > 8 { intervals.removeFirst() }
        return nil
    }
}
