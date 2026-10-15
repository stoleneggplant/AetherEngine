import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

/// Enabled only by a healthy head whose IDR offset agrees with the container edit/index axis.
/// Healthy packets stay a zero-hold fast path. A zero-offset IDR opens a sequence whose pictures
/// claim their own display slots as those slots are read, so a picture waits its mini-GOP and the
/// hold never grows with the sequence. DTS never changes, so an already published keyframe index
/// stays valid across a region change.
///
/// Every refusal hands the packets back exactly as they arrived. A repair that later cannot say
/// where a picture belongs still has to deliver it: the judder it was built to remove is a far
/// smaller failure than a session that stops.
final class H264PartialCompositionRepairSession {
    private struct Entry {
        let packet: UnsafeMutablePointer<AVPacket>
        /// nil for a packet of another stream: it holds its place in the container's order and
        /// carries no claim of its own.
        let rank: Int?
        let decodeIndex: Int
    }
    private let streamIndex: Int32
    private let timeBase: AVRational
    private let lead: Int64
    private let reorderDepth: Int
    private var missingHead = false
    private var forwardDepth: Int?
    // Numeric evidence only, capped independently of interleaved packet/byte budgets.
    private var proofDTS: [Int64] = []
    private var proofRanks: [Int] = []
    private var forwardProofs = 0
    private let framing: VideoNALFraming
    private let reader: H264PictureOrderReader
    private var pending: [Entry] = []
    private var ready: [UnsafeMutablePointer<AVPacket>] = []
    private var readyIndex = 0
    private var bytes = 0
    private var ladder = H264PartialCompositionRepair.SlotLadder()
    private var decodeIndex = 0
    private var inSequence = false
    private var sequenceReordered = false
    private var confirmed = false
    private var abandoned = false
    private var repairedCount = 0
    private var abandonedSequences = 0
    private var deepestWait = 0
    private(set) var reason = "composition_offsets_present"

    init?(stream: UnsafeMutablePointer<AVStream>, streamIndex: Int32, presentationLead: Int64) {
        guard presentationLead > 0, let par = stream.pointee.codecpar,
              (1...Int32(H264PartialCompositionRepair.maximumReorderDepth)).contains(par.pointee.video_delay),
              let reader = H264PictureOrderReader(codecParameters: par, timeBase: stream.pointee.time_base)
        else { return nil }
        self.reader = reader
        self.streamIndex = streamIndex
        self.reorderDepth = Int(par.pointee.video_delay)
        lead = presentationLead
        timeBase = stream.pointee.time_base
        framing = A53SEIParser.nalFraming(codec: .h264, extradata: par.pointee.extradata, size: Int(par.pointee.extradata_size))
    }

    deinit { releasePackets() }
    var hasDecision: Bool { missingHead || reason != "composition_offsets_present" }

    /// Only the parent's head proof enables this. Healthy-head behavior is unchanged.
    func enableMissingHead(forwardDepth: Int, firstPacket: UnsafeMutablePointer<AVPacket>) -> Bool {
        precondition(!inSequence && pending.isEmpty && ready.isEmpty)
        guard isIDR(firstPacket) else { return false }
        missingHead = true
        self.forwardDepth = forwardDepth
        reason = "missing_composition_offsets_pending"
        return true
    }

    private var confirmedReason: String {
        missingHead ? "confirmed_missing_composition_offsets" : "confirmed_partial_composition_offsets"
    }

    private func isIDR(_ packet: UnsafeMutablePointer<AVPacket>) -> Bool {
        guard packet.pointee.flags & AV_PKT_FLAG_KEY != 0,
              let data = packet.pointee.data, packet.pointee.size > 0 else { return false }
        var result = false
        A53SEIParser.forEachNAL(data, Int(packet.pointee.size), framing) { nal, size in
            if size > 0, nal[0] & 0x80 == 0, nal[0] & 31 == 5 { result = true }
        }
        return result
    }

    /// Returns true when the packet was taken over and must not be emitted yet.
    func ingest(_ packet: UnsafeMutablePointer<AVPacket>) -> Bool {
        guard packet.pointee.stream_index == streamIndex else {
            guard !pending.isEmpty else { return handBack(packet) }
            append(packet, rank: nil)
            drain()
            enforceBounds()
            return true
        }
        let idr = isIDR(packet)
        if idr, inSequence { closeSequence() }
        // A missing timestamp differs numerically from a valid one but is not evidence of healthy
        // composition offsets, so it takes the same route as an unsupported picture.
        let missing = packet.pointee.pts == Int64.min || packet.pointee.dts == Int64.min
        if !missing, packet.pointee.pts != packet.pointee.dts {
            // Genuine composition offsets always win, and a boundary packet must not overtake
            // packets already held behind it.
            publishPending()
            resetSequence()
            confirmed = false
            reason = "composition_offsets_present"
            return handBack(packet)
        }
        if !inSequence {
            guard idr, !missing else { return handBack(packet) }
            reader.reset()
            inSequence = true
        }
        if abandoned { return handBack(packet) }
        guard !missing, ladder.append(dts: packet.pointee.dts) else { return failOpen(with: packet, cause: "missing_or_nonincreasing_dts") }
        let poc = reader.pictureOrderCount(for: packet)
        // Complete, closed, progressive sequences only. Fields, open-GOP leading pictures and a
        // parser that cannot read an order are not guessed at.
        guard let poc, reader.isFramePicture, poc >= 0, poc % 2 == 0,
              decodeIndex > 0 || poc == 0,
              packet.pointee.flags & AV_PKT_FLAG_KEY == 0 || (idr && poc == 0)
        else { return failOpen(with: packet, cause: "unsupported_picture_order") }
        let rank = Int(poc / 2)
        if rank != decodeIndex { sequenceReordered = true }
        if !missingHead && proofRanks.count < H264PartialCompositionRepair.maximumProofPictures {
            proofDTS.append(packet.pointee.dts)
            proofRanks.append(rank)
        }
        append(packet, rank: rank)
        decodeIndex += 1
        drain()
        enforceBounds()
        return true
    }

    /// The sequence has to show its reordering before a single picture is rewritten: a zero-offset
    /// run that never reorders is not evidence that the offsets were lost.
    private func drain() {
        guard confirmed || sequenceReordered else { return }
        while let first = pending.first {
            guard let rank = first.rank else { promoteFirst(); continue }
            if !missingHead, forwardDepth == nil, rank - first.decodeIndex > reorderDepth {
                // Keep the existing fast path for ordinary mini-GOPs. Only an anchor beyond the
                // old symmetric allowance waits for bounded, complete-prefix evidence.
                if let depth = H264PartialCompositionRepair.provenForwardDepth(
                    dts: proofDTS, ranks: proofRanks, lead: lead, reorderDepth: reorderDepth),
                    rank - first.decodeIndex <= depth {
                    forwardDepth = depth
                    forwardProofs += 1
                    if forwardProofs <= 8 {
                        EngineLog.emit("[Demuxer] H264 slot forward wait proven: rank=\(rank)"
                            + " decode_index=\(first.decodeIndex) samples=\(proofRanks.count)"
                            + " reorder_depth=\(reorderDepth) forward_depth=\(depth)", category: .demux)
                    }
                } else if proofRanks.count < H264PartialCompositionRepair.maximumProofPictures {
                    deepestWait = max(deepestWait, pending.count)
                    return
                } else {
                    failOpen(cause: "forward_prefix_unproven")
                    return
                }
            }
            switch ladder.claim(rank: rank, decodeIndex: first.decodeIndex, lead: lead,
                                reorderDepth: reorderDepth, forwardDepth: forwardDepth) {
            case .wait:
                deepestWait = max(deepestWait, pending.count)
                return
            case .refuse:
                failOpen(cause: ladder.refusalReason)
                return
            case .time(let pts):
                first.packet.pointee.pts = pts
                repairedCount += 1
                if !confirmed {
                    confirmed = true
                    reason = confirmedReason
                    EngineLog.emit(
                        "[Demuxer] H264 slot composition offsets confirmed: kind=\(confirmedReason) reorder_depth=\(reorderDepth)"
                        + " presentation_lead=\(lead) decode_offset=0 time_base=\(timeBase.num)/\(timeBase.den)",
                        category: .demux
                    )
                }
                promoteFirst()
            }
        }
    }

    private func append(_ packet: UnsafeMutablePointer<AVPacket>, rank: Int?) {
        pending.append(Entry(packet: packet, rank: rank, decodeIndex: decodeIndex))
        bytes += Int(max(0, packet.pointee.size))
    }

    private func promoteFirst() {
        let entry = pending.removeFirst()
        bytes -= Int(max(0, entry.packet.pointee.size))
        ready.append(entry.packet)
    }

    /// Interleaving depth, not reordering, is what can still make the wait large. Exceeding it
    /// costs the repair, never the packets.
    private func enforceBounds() {
        if pending.count >= H264PartialCompositionRepair.maximumHeldPackets
            || bytes >= H264PartialCompositionRepair.maximumHeldBytes
            || (!confirmed && !sequenceReordered && decodeIndex > H264PartialCompositionRepair.maximumProofPictures) {
            failOpen(cause: "packet_byte_or_proof_limit")
        }
    }

    /// Hands every held packet back untouched and lets the rest of this sequence stream through.
    /// The next IDR starts a new candidate; nothing about the session is given up.
    @discardableResult
    private func failOpen(with packet: UnsafeMutablePointer<AVPacket>? = nil, cause: String) -> Bool {
        if !abandoned, inSequence {
            abandoned = true
            abandonedSequences += 1
            // One bounded diagnostic per refused sequence; never log payloads or source URLs.
            if abandonedSequences <= 8 {
                EngineLog.emit("[Demuxer] H264 slot repair refused: cause=\(cause)"
                    + " rank=\(pending.first?.rank ?? -1) decode_index=\(pending.first?.decodeIndex ?? decodeIndex)"
                    + " samples=\(decodeIndex) reorder_depth=\(reorderDepth) forward_depth=\(forwardDepth ?? reorderDepth)"
                    + " presentation_lead=\(lead) held_packets=\(pending.count) held_bytes=\(bytes)", category: .demux)
            }
            if reason == confirmedReason {
                reason = "partial_composition_sequence_unproven_after_repair"
            } else {
                reason = "partial_composition_sequence_unproven"
            }
        }
        publishPending()
        guard let packet else { return true }
        return handBack(packet)
    }

    /// A packet this session does not own. It still cannot overtake packets already held.
    private func handBack(_ packet: UnsafeMutablePointer<AVPacket>) -> Bool {
        guard readyIndex < ready.count else { return false }
        ready.append(packet)
        return true
    }

    private func closeSequence() {
        drain()
        // Anything still waiting is waiting for a slot this sequence never carried.
        if !pending.isEmpty { failOpen(cause: "incomplete_sequence") }
        resetSequence()
    }

    private func resetSequence() {
        ladder = H264PartialCompositionRepair.SlotLadder()
        decodeIndex = 0
        inSequence = false
        sequenceReordered = false
        abandoned = false
        proofDTS.removeAll(keepingCapacity: true)
        proofRanks.removeAll(keepingCapacity: true)
        if !missingHead { forwardDepth = nil }
    }

    private func publishPending() {
        ready.append(contentsOf: pending.map(\.packet))
        pending.removeAll(keepingCapacity: true)
        bytes = 0
    }

    func dequeue() -> UnsafeMutablePointer<AVPacket>? {
        guard readyIndex < ready.count else { return nil }
        let packet = ready[readyIndex]; readyIndex += 1
        if readyIndex == ready.count { ready.removeAll(keepingCapacity: true); readyIndex = 0 }
        return packet
    }

    func endOfStream() {
        guard inSequence else { publishPending(); return }
        closeSequence()
    }

    func noteSeek() {
        releasePackets()
        reader.reset()
        resetSequence()
        confirmed = false
        reason = missingHead ? "missing_composition_offsets_pending" : "composition_offsets_present"
    }

    private func releasePackets() {
        for entry in pending { var owned: UnsafeMutablePointer<AVPacket>? = entry.packet; trackedPacketFree(&owned) }
        for packet in ready.dropFirst(readyIndex) { var owned: UnsafeMutablePointer<AVPacket>? = packet; trackedPacketFree(&owned) }
        pending.removeAll(keepingCapacity: true); ready.removeAll(keepingCapacity: true)
        readyIndex = 0; bytes = 0
    }

    var summary: String {
        "reason=\(reason) repaired=\(repairedCount) abandoned_sequences=\(abandonedSequences)"
            + " deepest_wait=\(deepestWait) reorder_depth=\(reorderDepth) forward_proofs=\(forwardProofs)"
            + " presentation_lead=\(lead) decode_offset=0"
    }

}
