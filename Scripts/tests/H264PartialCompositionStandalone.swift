import Foundation

/// The ladder and the picture order come from @orut34iop's PR #513 measurement: a closed sequence
/// carrying a 25 -> 29.97 transition and its rounding ticks. Those numbers are the fixture here.
@main
struct H264PartialCompositionTests {
    typealias Policy = H264PartialCompositionRepair
    static let slots: [Int64] = [0, 3600, 7200, 10800, 14400, 18000, 21600, 25200, 28800, 32400,
                                 36000, 39600, 42603, 45607, 48610]
    static let pocs: [Int64] = [0, 8, 2, 4, 6, 16, 10, 12, 14, 24, 18, 20, 22, 28, 26]
    static let lead: Int64 = 6006

    /// Feeds the sequence one packet at a time, exactly as the demuxer does, and returns the
    /// presentation times in the order they leave, plus the deepest wait any picture cost.
    static func run(slots: [Int64] = slots, pocs: [Int64] = pocs, lead: Int64 = lead,
                    reorderDepth: Int = 4) -> (times: [Int64], deepestWait: Int, refused: Bool) {
        var ladder = Policy.SlotLadder()
        var queue: [(rank: Int, index: Int)] = []
        var times: [Int64] = []
        var deepest = 0
        for (index, slot) in slots.enumerated() {
            guard ladder.append(dts: slot) else { return (times, deepest, true) }
            queue.append((Int(pocs[index] / 2), index))
            drain: while let first = queue.first {
                switch ladder.claim(rank: first.rank, decodeIndex: first.index, lead: lead, reorderDepth: reorderDepth) {
                case .wait: deepest = max(deepest, queue.count); break drain
                case .refuse: return (times, deepest, true)
                case .time(let pts): times.append(pts); queue.removeFirst()
                }
            }
        }
        return (times, deepest, !queue.isEmpty)
    }

    static func missingHeadChecks() {
        let ticks: [Int64] = [-48000, 0, 48000, 96000, 144000, 192000, 240000, 288000, 336000, 384000, 424040, 464080]
        let order: [Int64] = [0, 6, 2, 4, 12, 8, 10, 18, 14, 16, 22, 20]
        let keys = [true] + Array(repeating: false, count: 11)
        func proof(_ dts: [Int64] = ticks, pts: [Int64]? = nil, pocs: [Int64] = order,
                   start: Int64 = 0, origin: Int64 = -48000, depth: Int = 1) -> Int? {
            Policy.missingHeadForwardDepth(dts: dts, pts: pts ?? dts, pocs: pocs, keys: keys,
                streamStart: start, ladderStart: origin, reorderDepth: depth)
        }
        precondition(proof() == 2) // Forward-coded P differs from backward reorder lead.
        precondition(proof(start: -48000) == nil)
        precondition(proof(start: 1) == nil)
        precondition(proof(origin: 0) == nil)
        precondition(proof(depth: 0) == nil)
        precondition(proof(depth: 17) == nil)
        precondition(proof(pocs: Array(stride(from: Int64(0), to: 24, by: 2))) == nil)
        for bad: Int64 in [-1, 3, 6, 1000, Int64.max] {
            var changed = order; changed[4] = bad
            precondition(proof(pocs: changed) == nil)
        }
        var offset = ticks; offset[3] += 1
        precondition(proof(pts: offset) == nil)
        var flat = ticks; flat[3] = flat[2]
        precondition(proof(flat) == nil)
        var missing = ticks; missing[3] = Int64.min
        precondition(proof(missing) == nil)
        precondition(proof(Array(ticks.prefix(11))) == nil)
        print("PASS missing head: corroborated lead, variable slots, bounded forward reorder; invalid/ambiguous evidence refused")
    }

    static func forwardProofChecks() {
        let ranks = [0, 4, 2, 1, 3, 8, 6, 5, 7, 12, 10, 9]
        let dts = (0..<12).map { Int64($0) * 3600 }
        func proof(_ order: [Int] = ranks, slots: [Int64] = dts, lead: Int64 = 7200,
                   depth: Int = 2) -> Int? {
            Policy.provenForwardDepth(dts: slots, ranks: order, lead: lead, reorderDepth: depth)
        }
        precondition(proof() == 3)
        precondition(proof(slots: dts.map { $0 + 63_000_000 }) == 3)
        precondition(proof(lead: 3600) == nil)
        precondition(proof(depth: 1) == nil)
        precondition(proof(Array(ranks.prefix(11)), slots: Array(dts.prefix(11))) == nil)
        precondition(proof(Array(0..<12)) == nil)
        for bad in [-1, 0, 1000, Int.max] {
            var order = ranks; order[4] = bad
            precondition(proof(order) == nil)
        }
        // Unique bounded ranks can still omit a display slot: no complete prefix, no proof.
        precondition(proof([0, 5, 3, 2, 4, 9, 7, 6, 8, 13, 11, 10]) == nil)
        var repeated = dts; repeated[4] = repeated[3]
        precondition(proof(slots: repeated) == nil)
        var missing = dts; missing[4] = Int64.min
        precondition(proof(slots: missing) == nil)
        precondition(proof(slots: dts.map { Int64.max - 40000 + $0 }) == nil)
        var ladder = Policy.SlotLadder()
        for value in dts { precondition(ladder.append(dts: value)) }
        precondition(ladder.claim(rank: 4, decodeIndex: 1, lead: 7200, reorderDepth: 2) == .refuse)
        precondition(ladder.refusalReason == "forward_wait_depth_exceeded")
        precondition(ladder.claim(rank: 4, decodeIndex: 1, lead: 7200, reorderDepth: 2, forwardDepth: 3) == .time(21600))
        precondition(ladder.claim(rank: 4, decodeIndex: 1, lead: 7200, reorderDepth: 2, forwardDepth: 3) == .refuse)
        precondition(ladder.refusalReason == "duplicate_display_rank")
        print("PASS partial forward proof: complete prefix, asymmetric depth, exact slot, invalid evidence refused")
    }

    static func main() {
        missingHeadChecks()
        forwardProofChecks()
        let expected = pocs.map { slots[Int($0 / 2)] + lead }
        let plain = run()
        precondition(!plain.refused)
        // Delivery stays in the container's own decode order; only the times move.
        precondition(plain.times == expected)
        precondition(expected.sorted() == slots.map { $0 + lead })
        // A slot is a packet away, never a plan away: the deepest wait is the mini-GOP the
        // reorder created, not the length of the sequence.
        precondition(plain.deepestWait == 3, "deepest wait was \(plain.deepestWait)")
        precondition(slots.count == 15)

        // A far seek moves the whole ladder and nothing else.
        let shifted = run(slots: slots.map { $0 + 63_000_000 })
        precondition(shifted.times == expected.map { $0 + 63_000_000 })

        // A lead too small to cover the reorder would place a picture before its own decode time.
        precondition(run(lead: 3000).refused)
        precondition(run(lead: 0).refused)
        precondition(run(lead: -1).refused)
        // A wait no reorder delay explains is not a wait this policy takes.
        precondition(run(reorderDepth: 2).refused)
        precondition(run(reorderDepth: 3).times == expected)

        // A ladder that does not rise is not a decode ladder.
        var flat = slots; flat[4] = flat[3]
        precondition(run(slots: flat).refused)
        var missing = slots; missing[4] = Int64.min
        precondition(run(slots: missing).refused)

        // Incomplete, field, duplicate and out-of-range picture order.
        for bad: Int64 in [-2, 1, 30, Int64.max] {
            var invalid = pocs; invalid[4] = bad
            precondition(run(pocs: invalid).refused, "poc \(bad) must refuse")
        }
        var duplicate = pocs; duplicate[6] = pocs[2]
        precondition(run(pocs: duplicate).refused)

        // Arithmetic overflow at the top of the axis.
        precondition(run(slots: slots.map { Int64.max - 48610 + $0 }, lead: 6006).refused)

        // A ladder longer than a GOP is not a GOP.
        var long = Policy.SlotLadder()
        for i in 0..<Policy.maximumPictures { precondition(long.append(dts: Int64(i) * 3003)) }
        precondition(!long.append(dts: Int64(Policy.maximumPictures) * 3003))

        print("PASS partial ctts: exact slots across a cadence change, mini-GOP wait depth 3,"
            + " seek translation, unchanged decode axis; insufficient lead, unexplained wait,"
            + " non-rising and missing slots, incomplete/field/duplicate/out-of-range POC,"
            + " overflow and ladder ceiling all refused")
    }
}
