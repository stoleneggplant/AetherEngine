// Shared CLI argument helpers for every aetherctl subcommand.

import Foundation

/// Remove a boolean flag from `rest` in place; returns whether it was present.
func takeFlag(_ name: String, from rest: inout [String]) -> Bool {
    guard let idx = rest.firstIndex(of: name) else { return false }
    rest.remove(at: idx)
    return true
}

/// Remove `--key value` from `rest`, returning the Int value. Exits 64 if the flag is present but the value is missing or non-integer.
func takeIntFlag(_ name: String, from rest: inout [String]) -> Int? {
    guard let idx = rest.firstIndex(of: name) else { return nil }
    guard idx + 1 < rest.count, let value = Int(rest[idx + 1]) else {
        let got = idx + 1 < rest.count ? "'\(rest[idx + 1])'" : "nothing"
        print("ERROR: \(name) expects an integer value, got \(got)")
        exit(64)
    }
    rest.removeSubrange(idx...(idx + 1))
    return value
}

/// Remove `--key value` from `rest`, returning the String value. Returns nil if absent.
func takeStringFlag(_ name: String, from rest: inout [String]) -> String? {
    guard let idx = rest.firstIndex(of: name),
          idx + 1 < rest.count else { return nil }
    let value = rest[idx + 1]
    rest.removeSubrange(idx...(idx + 1))
    return value
}

/// Remove `--key value` from `rest`, returning the Double value. Exits 64 if present but non-finite or missing.
func takeDoubleFlag(_ name: String, from rest: inout [String]) -> Double? {
    guard let idx = rest.firstIndex(of: name) else { return nil }
    guard idx + 1 < rest.count, let value = Double(rest[idx + 1]), value.isFinite else {
        // isFinite rejects "nan"/"inf" that parse as Double but trap in downstream Int(Double).
        let got = idx + 1 < rest.count ? "'\(rest[idx + 1])'" : "nothing"
        print("ERROR: \(name) expects a finite numeric value, got \(got)")
        exit(64)
    }
    rest.removeSubrange(idx...(idx + 1))
    return value
}

/// Longest run a duration flag accepts: a week. `isFinite` alone let `--seconds 1e30` through to the
/// run loop's `Int(_:)`, which trapped after the session was up (audit OPS-110).
let maxRunSeconds: Double = 7 * 24 * 3600

/// `takeDoubleFlag`, and the value must lie in `range`. Exits 64 otherwise.
func takeDoubleFlag(_ name: String, in range: ClosedRange<Double>, from rest: inout [String]) -> Double? {
    guard let value = takeDoubleFlag(name, from: &rest) else { return nil }
    guard range.contains(value) else {
        print("ERROR: \(name) expects a value in \(range.lowerBound)...\(range.upperBound), got \(value)")
        exit(64)
    }
    return value
}

/// `takeIntFlag`, and the value must lie in `range`. Exits 64 otherwise: a negative count reached
/// `0..<n` and trapped (audit OPS-110).
func takeIntFlag(_ name: String, in range: ClosedRange<Int>, from rest: inout [String]) -> Int? {
    guard let value = takeIntFlag(name, from: &rest) else { return nil }
    guard range.contains(value) else {
        print("ERROR: \(name) expects an integer in \(range.lowerBound)...\(range.upperBound), got \(value)")
        exit(64)
    }
    return value
}

/// A host-call delay in milliseconds as a sleep, saturating: `UInt64(ms) * 1_000_000` overflowed past
/// about 1.8e13 ms (audit OPS-110).
func sleepNanoseconds(milliseconds: Int) -> UInt64 {
    let (nanoseconds, overflow) = UInt64(max(0, milliseconds)).multipliedReportingOverflow(by: 1_000_000)
    return overflow ? .max : nanoseconds
}

/// Exit 64 with an error message if any `--flag` remains in `rest` after plucking known flags (typos would silently become the URL positional otherwise).
func rejectStrayFlags(_ rest: [String], subcommand: String) {
    if let stray = rest.first(where: { $0.hasPrefix("--") }) {
        print("ERROR: unknown flag '\(stray)' for subcommand '\(subcommand)'")
        print("")
        printUsage()
        exit(64)
    }
}
