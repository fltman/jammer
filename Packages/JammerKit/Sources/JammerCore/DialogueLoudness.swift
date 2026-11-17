import Foundation

/// Dialogue-gated loudness: BS.1770 loudness measured only where there is speech. Film and television
/// delivery often asks for it, because a film is set by how loud the talking is, not by its explosions.
///
/// This is Jämmer's own measurement and is never called anything else. Where speech is comes from what
/// the document already knows from this Mac's own speech tools: who speaks when (Find Speakers), or
/// else the words of a transcript. A meter with another speech detector (Dolby's Dialogue Intelligence
/// is the one most specifications name) will not put the speech in exactly the same places, and its
/// number will differ; how much is in the manual, measured.
public struct DialogueLoudness: Sendable, Equatable {
    public enum Source: String, Sendable, Codable {
        /// From who speaks when (the diarisation's turns).
        case speakers
        /// From the words of a transcript.
        case words
        /// The document has neither.
        case none
    }
    /// Loudness over the speech, in LKFS: K-weighted, every 100 ms of speech above −70 LKFS, no
    /// relative gate. nil when no speech was found in the range.
    public var dialogue: Double?
    /// The part of the measured time that is speech, 0 to 1.
    public var speechShare: Double
    public var speechSeconds: Double
    /// The same range measured in the ordinary way (integrated loudness, true peak).
    public var programme: LoudnessResult
    public var source: Source

    public var json: [String: Any] {
        ["dialogueLKFS": dialogue.map { ($0 * 100).rounded() / 100 as Any } ?? NSNull(),
         "speechShare": (speechShare * 1_000).rounded() / 1_000, "speechSeconds": (speechSeconds * 100).rounded() / 100,
         "speechFrom": source.rawValue, "program": programme.json,
         "note": "dialogueLKFS is Jämmer's own dialogue-gated measurement (BS.1770 K-weighting over the 100 ms blocks that are speech, by this document's own speech detection). It is not Dolby's Dialogue Intelligence, and a meter that finds the speech in other places gives another number."]
    }

    /// The loudness over the blocks that are speech. `energies` are the meter's 100 ms blocks from the
    /// start of the measured range, `block` their length in frames; a block is speech when at least half
    /// of it lies in a speech range (`speech` in frames from the start of the measured range, sorted and
    /// not overlapping).
    public static func gated(energies: [Double], block: Int, speech: [Range<Frame>]) -> (dialogue: Double?, speechBlocks: Int) {
        guard block > 0 else { return (nil, 0) }
        let absolute = pow(10, (-70 + 0.691) / 10)
        var sum = 0.0, counted = 0, speechBlocks = 0, next = 0
        for (i, e) in energies.enumerated() {
            let lo = Frame(i * block), hi = lo + Frame(block)
            while next < speech.count, speech[next].upperBound <= lo { next += 1 }
            var inside: Frame = 0, k = next
            while k < speech.count, speech[k].lowerBound < hi {
                inside += max(0, min(hi, speech[k].upperBound) - max(lo, speech[k].lowerBound))
                k += 1
            }
            guard inside * 2 >= Frame(block) else { continue }
            speechBlocks += 1
            if e > absolute { sum += e; counted += 1 }
        }
        return (counted > 0 ? -0.691 + 10 * log10(sum / Double(counted)) : nil, speechBlocks)
    }

    /// Measures a range of a rendered plan against speech ranges on the timeline.
    public static func measure(_ plan: RenderPlan, _ range: Range<Frame>, speech: [Range<Frame>], source: Source) -> DialogueLoudness {
        var meter = LoudnessMeter(sampleRate: plan.sampleRate, channels: plan.channels)
        plan.render(range) { meter.process($0) }
        let block = Int((plan.sampleRate * 0.1).rounded())
        let local = speech.compactMap { r -> Range<Frame>? in
            let lo = max(r.lowerBound, range.lowerBound) - range.lowerBound, hi = min(r.upperBound, range.upperBound) - range.lowerBound
            return hi > lo ? lo..<hi : nil
        }
        let energies = meter.blockEnergies
        let g = gated(energies: energies, block: block, speech: local)
        return DialogueLoudness(dialogue: g.dialogue, speechShare: energies.isEmpty ? 0 : Double(g.speechBlocks) / Double(energies.count),
                                speechSeconds: Double(g.speechBlocks) * 0.1, programme: meter.result, source: local.isEmpty ? (source == .none ? .none : source) : source)
    }
}

extension Project {
    /// Where there is speech on the timeline, as the document knows it: the turns of who speaks when on
    /// the tracks that are heard, or, when there are none, the transcript's words (words less than 0.3 s
    /// apart are one stretch of speech). Sorted, not overlapping.
    public func speechRanges(in range: Range<Frame>? = nil) -> (ranges: [Range<Frame>], source: DialogueLoudness.Source) {
        func merged(_ list: [Range<Frame>], gap: Frame) -> [Range<Frame>] {
            var out: [Range<Frame>] = []
            for r in list.sorted(by: { $0.lowerBound < $1.lowerBound }) where !r.isEmpty {
                if let last = out.last, r.lowerBound <= last.upperBound + gap {
                    out[out.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
                } else { out.append(r) }
            }
            return out
        }
        let turns = placedTurns(in: range).filter { tracks.indices.contains($0.track) && !tracks[$0.track].isMuted }
        if !turns.isEmpty { return (merged(turns.map { $0.start..<$0.end }, gap: 0), .speakers) }
        let words = placedWords(in: range)
        if !words.isEmpty { return (merged(words.map { $0.start..<$0.end }, gap: frames(0.3)), .words) }
        return ([], .none)
    }
}

/// A delivery target that is set by the loudness of the dialogue. Each says where its numbers were read
/// and when: specifications change, and one that could not be read at its source says so.
public enum DialogueProfile: String, Sendable, CaseIterable, Codable {
    case atscA85 = "atsc_a85_dialogue", netflix

    public struct Spec: Sendable, Equatable {
        public var title: String
        /// Dialogue-gated target and tolerance, LKFS and LU.
        public var target: Double, tolerance: Double
        public var truePeakCeiling: Double
        /// Below this share of speech the dialogue is not what the programme is set by.
        public var minimumSpeechShare: Double
        /// What is measured then: the whole programme in the ordinary way, against this target.
        public var programmeTarget: Double, programmeTolerance: Double
        public var source: String
        /// The day the source was read (ISO date).
        public var read: String
        /// false: the specification's own page could not be read, and the numbers are from someone else's account of it.
        public var readAtSource: Bool
    }

    public var spec: Spec {
        switch self {
        case .atscA85:
            // ATSC A/85:2026-07, §5.1.1, §5.2.2, §5.2.5, §6: dialogue-gated BS.1770 without the relative gate over
            // the whole content; −24 LKFS, about ±2; true peak below −2 dBTP; 8 % speech as an example minimum
            // for automated processes; without dialogue a full-programme measurement "can be considered".
            Spec(title: "ATSC A/85, long-form (−24 LKFS dialogue, −2 dBTP)", target: -24, tolerance: 2, truePeakCeiling: -2,
                 minimumSpeechShare: 0.08, programmeTarget: -24, programmeTolerance: 2,
                 source: "ATSC A/85:2026-07 (8 July 2026), https://www.atsc.org/wp-content/uploads/2026/07/A85-2026-07.pdf", read: "2026-11-17", readAtSource: true)
        case .netflix:
            // Netflix's own page is an application that could not be read on 2026-11-17. The numbers are from
            // MeterPlugs' account of it (deliveryqc.com/netflix-delivery-specs): −27 LKFS ±2 dialogue-gated,
            // −2 dBTP, and under 15 % dialogue the programme at −24 ±2.
            Spec(title: "Netflix, 5.1 and 2.0 (−27 LKFS dialogue, −2 dBTP)", target: -27, tolerance: 2, truePeakCeiling: -2,
                 minimumSpeechShare: 0.15, programmeTarget: -24, programmeTolerance: 2,
                 source: "Netflix Sound Mix Specifications, as given by https://deliveryqc.com/netflix-delivery-specs (Netflix's own page could not be read)", read: "2026-11-17", readAtSource: false)
        }
    }

    /// A measurement set beside the profile: which of the two measurements the profile goes by, and how far
    /// each number is from the profile's. No verdict: the numbers are Jämmer's own until they have been
    /// set beside a reference meter's.
    public struct Reading: Sendable, Equatable {
        public enum Basis: String, Sendable { case dialogue, programme = "program" }
        public var basis: Basis
        public var measured: Double?
        public var target: Double, tolerance: Double
        /// measured − target; nil when nothing could be measured (silence).
        public var fromTarget: Double?
        public var truePeak: Double, truePeakCeiling: Double
    }

    public func reading(_ m: DialogueLoudness) -> Reading {
        let s = spec
        let byDialogue = m.dialogue != nil && m.speechShare >= s.minimumSpeechShare
        let measured = byDialogue ? m.dialogue : m.programme.integrated
        let target = byDialogue ? s.target : s.programmeTarget
        return Reading(basis: byDialogue ? .dialogue : .programme, measured: measured, target: target, tolerance: byDialogue ? s.tolerance : s.programmeTolerance,
                       fromTarget: measured.map { $0 - target }, truePeak: m.programme.truePeak, truePeakCeiling: s.truePeakCeiling)
    }

    public func json(_ m: DialogueLoudness) -> [String: Any] {
        let s = spec, r = reading(m)
        func r2(_ v: Double?) -> Any { v.map { $0.isFinite ? ($0 * 100).rounded() / 100 as Any : NSNull() } ?? NSNull() }
        return ["profile": rawValue, "title": s.title, "basis": r.basis.rawValue, "measured": r2(r.measured), "target": r.target, "tolerance": r.tolerance,
                "fromTarget": r2(r.fromTarget), "truePeak": r2(r.truePeak), "truePeakCeiling": r.truePeakCeiling, "minimumSpeechShare": s.minimumSpeechShare,
                "source": s.source, "read": s.read, "readAtSource": s.readAtSource,
                "note": "basis says which measurement the profile goes by here: dialogue, or program (the whole of it, measured the ordinary way) when the share of speech is under minimumSpeechShare. No verdict is given: these are Jämmer's own numbers, not yet set beside a reference meter's."]
    }
}
