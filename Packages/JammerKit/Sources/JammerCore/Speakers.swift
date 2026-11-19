import Foundation

/// A stretch where one speaker talks, in **source** frames (like words, so it survives
/// every edit). `speaker` indexes `Project.speakers`.
public struct SpeakerTurn: Codable, Hashable, Sendable {
    public var speaker: Int
    public var start: Frame
    public var end: Frame

    public init(speaker: Int, start: Frame, end: Frame) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

/// Everyone heard in one source, and what found them ("by-track", "pyannote-community-1").
public struct SourceSpeakers: Codable, Hashable, Sendable {
    public var sourceID: UUID
    public var engine: String
    /// Sorted by start; turns of different speakers may overlap.
    public var turns: [SpeakerTurn]

    public init(sourceID: UUID, engine: String, turns: [SpeakerTurn]) {
        self.sourceID = sourceID
        self.engine = engine
        self.turns = turns.sorted { ($0.start, $0.speaker) < ($1.start, $1.speaker) }
    }
}

/// A turn as it plays on the timeline right now.
public struct PlacedTurn: Hashable, Sendable {
    public var speaker: Int
    public var track: Int
    public var start: Frame
    public var end: Frame
}

/// What a diarisation found on one track: its own speakers (indices into `names`) and
/// their turns in timeline frames.
public struct TrackDiarization: Sendable, Equatable {
    public var track: UUID
    public var names: [String]
    public var turns: [Turn]
    /// Each speaker's voiceprint by name, when asked for (`Diarization.model(voiceprints:)`): kept in memory for
    /// voice profiles, never saved in the document.
    public var prints: [String: [Float]] = [:]

    public struct Turn: Sendable, Equatable {
        public var speaker: Int
        public var range: Range<Frame>
        public init(speaker: Int, range: Range<Frame>) {
            self.speaker = speaker
            self.range = range
        }
    }

    public init(track: UUID, names: [String], turns: [Turn]) {
        self.track = track
        self.names = names
        self.turns = turns
    }
}

extension Project {
    /// Speaker turns as they play now, in timeline order (computed from the clips).
    public func placedTurns(in range: Range<Frame>? = nil) -> [PlacedTurn] {
        guard !speakerTurns.isEmpty else { return [] }
        let bySource = Dictionary(speakerTurns.map { ($0.sourceID, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [PlacedTurn] = []
        for (ti, track) in tracks.enumerated() {
            for clip in track.clips {
                guard let s = bySource[clip.sourceID] else { continue }
                let srcLo = clip.sourceStart, srcHi = clip.sourceStart + clip.length
                for t in s.turns where t.end > srcLo && t.start < srcHi {
                    var start = clip.start + (max(t.start, srcLo) - srcLo), end = clip.start + (min(t.end, srcHi) - srcLo)
                    if let range {
                        start = max(start, range.lowerBound)
                        end = min(end, range.upperBound)
                    }
                    if end > start { out.append(PlacedTurn(speaker: t.speaker, track: ti, start: start, end: end)) }
                }
            }
        }
        return out.sorted { ($0.start, $0.track, $0.speaker) < ($1.start, $1.track, $1.speaker) }
    }

    /// Seconds each speaker talks in `range` (overlaps between a speaker's own turns counted once).
    public func speakerSeconds(in range: Range<Frame>? = nil) -> [Int: Double] {
        var bySpeaker: [Int: [Range<Frame>]] = [:]
        for t in placedTurns(in: range) { bySpeaker[t.speaker, default: []].append(t.start..<t.end) }
        return bySpeaker.mapValues { rs in
            var total: Frame = 0, reach: Frame = .min
            for r in rs.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                let lo = max(r.lowerBound, reach)
                if r.upperBound > lo { total += r.upperBound - lo }
                reach = max(reach, r.upperBound)
            }
            return seconds(total)
        }
    }

    /// Gives every transcribed word the speaker whose turn overlaps it most, in sources
    /// with speaker turns. Words in sources without turns keep what they have.
    public mutating func labelWords() {
        let bySource = Dictionary(speakerTurns.map { ($0.sourceID, $0.turns) }, uniquingKeysWith: { a, _ in a })
        for ti in transcripts.indices {
            guard let turns = bySource[transcripts[ti].sourceID] else { continue }
            for wi in transcripts[ti].words.indices {
                let w = transcripts[ti].words[wi]
                var best: (speaker: Int, overlap: Frame)?
                for t in turns where t.end > w.start && t.start < w.end {
                    let o = min(t.end, w.end) - max(t.start, w.start)
                    if best == nil || o > best!.overlap { best = (t.speaker, o) }
                }
                transcripts[ti].words[wi].speaker = best?.speaker
            }
            transcripts[ti].speakers = speakers
        }
    }

    /// Stores diarisation results: replaces the turns in the sources of each result's
    /// track, adds its speakers, drops names no turn uses any more, and labels the words.
    public mutating func applyDiarization(_ results: [TrackDiarization], engine: String) {
        for r in results {
            guard let t = tracks.firstIndex(where: { $0.id == r.track }) else { continue }
            let sources = Set(tracks[t].clips.map(\.sourceID))
            speakerTurns.removeAll { sources.contains($0.sourceID) }
            let base = speakers.count
            speakers += r.names
            var bySource: [UUID: [SpeakerTurn]] = [:]
            for turn in r.turns {
                for clip in tracks[t].clips where clip.end > turn.range.lowerBound && clip.start < turn.range.upperBound {
                    let lo = max(clip.start, turn.range.lowerBound), hi = min(clip.end, turn.range.upperBound)
                    bySource[clip.sourceID, default: []].append(
                        SpeakerTurn(speaker: base + turn.speaker, start: clip.sourceStart + (lo - clip.start), end: clip.sourceStart + (hi - clip.start)))
                }
            }
            for (id, turns) in bySource { speakerTurns.append(SourceSpeakers(sourceID: id, engine: engine, turns: turns)) }
        }
        compactSpeakers()
        labelWords()
    }

    /// Removes speaker names no turn refers to, renumbering the rest in order.
    public mutating func compactSpeakers() {
        let used = Set(speakerTurns.flatMap { $0.turns.map(\.speaker) })
        var map: [Int: Int] = [:]
        var names: [String] = []
        for (i, n) in speakers.enumerated() where used.contains(i) {
            map[i] = names.count
            names.append(n)
        }
        speakers = names
        for s in speakerTurns.indices {
            for t in speakerTurns[s].turns.indices { speakerTurns[s].turns[t].speaker = map[speakerTurns[s].turns[t].speaker] ?? 0 }
        }
    }

    /// The speaker turns of track `t` heard in `range`, in the frames of a new source whose
    /// frame 0 plays at `range.lowerBound` (stretched by `scale` for a resampled one). For
    /// effects that bounce a stretch into a new file: the turns go with it, like the words.
    public func turnsForBounce(track t: Int, range: Range<Frame>, scale: Double = 1) -> [SpeakerTurn] {
        placedTurns(in: range).filter { $0.track == t }.map {
            SpeakerTurn(speaker: $0.speaker, start: Frame((Double($0.start - range.lowerBound) * scale).rounded()),
                        end: Frame((Double($0.end - range.lowerBound) * scale).rounded()))
        }
    }

    /// The turns in `segment` of `source` (source frames), shifted to start at 0 and cut to `length`.
    public func turns(of source: UUID, in segment: Range<Frame>, length: Frame) -> [SpeakerTurn] {
        (speakerTurns.first { $0.sourceID == source }?.turns ?? []).compactMap { t in
            let lo = max(0, t.start - segment.lowerBound), hi = min(length, t.end - segment.lowerBound)
            return hi > lo ? SpeakerTurn(speaker: t.speaker, start: lo, end: hi) : nil
        }
    }

    /// Stores carried turns for a new source.
    public mutating func addCarriedTurns(_ turns: [SpeakerTurn], to source: UUID) {
        guard !turns.isEmpty else { return }
        let engine = speakerTurns.first?.engine ?? "carried"
        speakerTurns.removeAll { $0.sourceID == source }
        speakerTurns.append(SourceSpeakers(sourceID: source, engine: engine, turns: turns))
    }

    /// Renames a speaker given by index or by its current name.
    public mutating func renameSpeaker(_ key: String, to name: String) throws {
        let i: Int
        if let n = Int(key), speakers.indices.contains(n) {
            i = n
        } else if let n = speakers.firstIndex(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
            i = n
        } else {
            throw SpeakerError.unknown(key)
        }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw SpeakerError.emptyName }
        speakers[i] = clean
        for t in transcripts.indices where !transcripts[t].speakers.isEmpty { transcripts[t].speakers = speakers }
    }

    /// Several tracks that sound at the same time: a double-ender, where each track can
    /// simply be its speaker.
    public var hasOverlappingTracks: Bool {
        let active = tracks.filter { !$0.isMuted && !$0.clips.isEmpty }
        guard active.count >= 2 else { return false }
        for i in active.indices {
            for j in active.indices where j > i {
                let a = active[i].clips.map(\.range), b = active[j].clips.map(\.range)
                let overlap = a.reduce(Frame(0)) { acc, r in acc + b.reduce(Frame(0)) { $0 + max(0, min(r.upperBound, $1.upperBound) - max(r.lowerBound, $1.lowerBound)) } }
                let shorter = min(a.reduce(0) { $0 + $1.count }, b.reduce(0) { $0 + $1.count })
                if shorter > 0, Double(overlap) >= 0.5 * Double(shorter) { return true }
            }
        }
        return false
    }
}

public enum SpeakerError: Error, LocalizedError, Equatable {
    case unknown(String)
    case emptyName

    public var errorDescription: String? {
        switch self {
        case .unknown(let k): "There's no speaker \(k)."
        case .emptyName: "A speaker needs a name."
        }
    }
    /// The same message by its key in the app's string catalogue (see `KeyedMessage`).
    public var keyed: KeyedMessage? {
        switch self {
        case .unknown(let k): KeyedMessage("error.speaker.unknown", ["\(k)"])
        case .emptyName: KeyedMessage("error.speaker.emptyName")
        }
    }
}

extension SpeakerError: KeyedFailure {}
