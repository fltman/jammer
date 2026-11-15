import Foundation

/// A recognised word, anchored to the **source** it was heard in, in source frames.
/// Edits never touch sources, so these anchors survive every edit as they are;
/// where a word lands on the timeline is worked out from the clips each time.
public struct Word: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    /// Source frames.
    public var start: Frame
    public var end: Frame
    /// 0…1 from the recogniser, when it gives one.
    public var confidence: Double?
    /// Index into the transcript's speakers, once diarised.
    public var speaker: Int?

    public init(id: UUID = UUID(), text: String, start: Frame, end: Frame, confidence: Double? = nil, speaker: Int? = nil) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
        self.speaker = speaker
    }

    public var range: Range<Frame> { start..<max(start, end) }
}

/// Everything recognised in one source.
public struct SourceTranscript: Codable, Hashable, Sendable {
    public var sourceID: UUID
    /// BCP 47, e.g. "sv-SE".
    public var language: String
    /// Which engine and model produced it, e.g. "apple-dictation sv-SE".
    public var engine: String
    /// Sorted by start.
    public var words: [Word]
    public var speakers: [String]

    public init(sourceID: UUID, language: String, engine: String, words: [Word], speakers: [String] = []) {
        self.sourceID = sourceID
        self.language = language
        self.engine = engine
        self.words = words.sorted { $0.start < $1.start }
        self.speakers = speakers
    }
}

/// A word as it plays on the timeline right now.
public struct PlacedWord: Hashable, Sendable {
    public var word: Word
    public var track: Int
    public var clipID: UUID
    /// Timeline frames, clipped to the clip.
    public var start: Frame
    public var end: Frame
    /// True when the clip edge cuts through the word.
    public var isPartial: Bool
    public var range: Range<Frame> { start..<end }
}

public enum TranscriptError: Error, LocalizedError, Equatable {
    case noWords
    case unknownWord

    public var errorDescription: String? {
        switch self {
        case .noWords: "Select some words first."
        case .unknownWord: "That word isn't in the transcript."
        }
    }
}

extension Project {
    /// The transcript as it reads now: every transcribed word that plays, in timeline
    /// order, across all tracks. Computed from the clips, so it can never disagree
    /// with what you hear.
    public func placedWords(in range: Range<Frame>? = nil) -> [PlacedWord] {
        guard !transcripts.isEmpty else { return [] }
        let bySource = Dictionary(transcripts.map { ($0.sourceID, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [PlacedWord] = []
        for (ti, track) in tracks.enumerated() where !track.isMuted {
            for clip in track.clips {
                guard let t = bySource[clip.sourceID] else { continue }
                if let range, clip.end <= range.lowerBound || clip.start >= range.upperBound { continue }
                let srcLo = clip.sourceStart, srcHi = clip.sourceStart + clip.length
                // Words are sorted: find the first that may overlap.
                var i = t.words.partitioningIndex { $0.end > srcLo }
                while i < t.words.count, t.words[i].start < srcHi {
                    let w = t.words[i]
                    i += 1
                    let lo = max(w.start, srcLo), hi = min(w.end, srcHi)
                    guard hi > lo else { continue }
                    let start = clip.start + (lo - srcLo), end = clip.start + (hi - srcLo)
                    if let range, end <= range.lowerBound || start >= range.upperBound { continue }
                    out.append(PlacedWord(word: w, track: ti, clipID: clip.id, start: start, end: end,
                                          isPartial: lo != w.start || hi != w.end))
                }
            }
        }
        // A word whose audio was bounced into a new file (restoration, effects) plays from
        // pieces with the same id, edge to edge: show it once.
        var merged: [PlacedWord] = []
        for w in out.sorted(by: { ($0.track, $0.start) < ($1.track, $1.start) }) {
            if let i = merged.indices.last, merged[i].word.id == w.word.id, merged[i].track == w.track, merged[i].end == w.start {
                merged[i].end = w.end
                merged[i].isPartial = merged[i].end - merged[i].start < w.word.end - w.word.start
            } else {
                merged.append(w)
            }
        }
        return droppingBleed(merged).sorted { ($0.start, $0.track) < ($1.start, $1.track) }
    }

    /// On a multitrack recording every microphone also hears the others, so each track's
    /// transcript repeats what the other people said. Once the speakers are known, a word
    /// that lies outside its own track's turns while someone on another track is talking
    /// is that bleed, and isn't shown. Words nobody's turn covers are kept.
    private func droppingBleed(_ words: [PlacedWord]) -> [PlacedWord] {
        guard tracks.count > 1, !speakerTurns.isEmpty else { return words }
        let turns = placedTurns()
        guard Set(turns.map(\.track)).count > 1 else { return words }
        // The other tracks' turns count with 0.3 s to spare: bleed words sit right at their edges.
        let margin = Frame(0.3 * sampleRate)
        func covered(_ w: PlacedWord, on sameTrack: Bool) -> Bool {
            let mid = (w.start + w.end) / 2, m = sameTrack ? 0 : margin
            return turns.contains { ($0.track == w.track) == sameTrack && $0.start - m <= mid && mid < $0.end + m }
        }
        return words.filter { covered($0, on: true) || !covered($0, on: false) }
    }

    /// The transcript as plain text, words in timeline order.
    public func transcriptText(in range: Range<Frame>? = nil) -> String {
        placedWords(in: range).map(\.word.text).joined(separator: " ")
    }

    /// Timeline ranges covering these words (as placed now), merged where they touch
    /// or where only a short gap (`bridge` frames) separates them, so deleting a run
    /// of words also removes the pauses between them.
    public func ranges(ofWords ids: Set<UUID>, bridge: Frame = 0) -> [Range<Frame>] {
        let placed = placedWords().filter { ids.contains($0.word.id) }.map(\.range).sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Frame>] = []
        for r in placed {
            if let last = merged.last, r.lowerBound <= last.upperBound + bridge {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    /// Text-based editing: removes the words from the timeline with ripple deletes,
    /// on every track, exactly as deleting those ranges by hand would.
    /// `bridge`: pauses up to this long between selected words go too.
    public mutating func deleteWords(_ ids: Set<UUID>, bridge: Frame = 0) throws {
        let ranges = self.ranges(ofWords: ids, bridge: bridge)
        guard !ranges.isEmpty else { throw TranscriptError.noWords }
        // Back to front, so earlier ranges stay where they are.
        for r in ranges.reversed() { try delete(r) }
    }

    /// Corrects a word's text. The audio doesn't change.
    public mutating func correctWord(_ id: UUID, to text: String) throws {
        for t in transcripts.indices {
            if let w = transcripts[t].words.firstIndex(where: { $0.id == id }) {
                transcripts[t].words[w].text = text
                transcripts[t].words[w].confidence = 1
                return
            }
        }
        throw TranscriptError.unknownWord
    }

    /// Where a phrase is spoken, as the transcript reads now: each match is the
    /// word ids in order. Case and punctuation don't count; letters like å, ä, ö do.
    public func findPhrase(_ text: String) -> [[UUID]] {
        let wanted = Self.tokens(text)
        guard !wanted.isEmpty else { return [] }
        let placed = placedWords()
        let have = placed.map { Self.tokens($0.word.text).joined(separator: " ") }
        var out: [[UUID]] = []
        var i = 0
        while i + wanted.count <= placed.count {
            // A word may hold several tokens ("podden." → "podden"); compare joined runs.
            if (0..<wanted.count).allSatisfy({ have[i + $0] == wanted[$0] }) {
                out.append(placed[i..<(i + wanted.count)].map(\.word.id))
                i += wanted.count
            } else {
                i += 1
            }
        }
        return out
    }

    public static func tokens(_ s: String) -> [String] {
        s.lowercased()
            .unicodeScalars.map { CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0) ? " " : String($0) }
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    /// Adds or replaces the transcript of a source.
    public mutating func setTranscript(_ t: SourceTranscript) {
        transcripts.removeAll { $0.sourceID == t.sourceID }
        transcripts.append(t)
        if speakerTurns.contains(where: { $0.sourceID == t.sourceID }) { labelWords() }
    }
}

extension Array {
    /// The first index where `belongs` is true, for an array partitioned false…true.
    func partitioningIndex(where belongs: (Element) -> Bool) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if belongs(self[mid]) { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }
}
