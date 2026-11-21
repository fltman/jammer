import Foundation

/// The portions of one track sent to a recognizer, with a map back to the untouched source files.
public struct TrackSpeech: Sendable {
    public struct Span: Sendable {
        public let source: SourceRef
        public let sourceStart: Frame
        public let timelineStart: Frame
        public let input: Range<Frame>
    }

    public let track: Track
    public let spans: [Span]
    public let speaker: Int?
    public let mayName: Bool

    public static func tracks(in project: Project) -> [UUID] {
        let spoken = Set(project.placedTurns().map(\.track))
        return project.tracks.enumerated().compactMap { i, track in
            guard !track.isMuted, track.frozen == nil, !track.clips.isEmpty, spoken.isEmpty || spoken.contains(i) else { return nil }
            return track.id
        }
    }

    public init(project: Project, index: Int, turns: [PlacedTurn], restrictToSpeech: Bool = false) {
        track = project.tracks[index]
        let groups = Dictionary(grouping: turns.filter { $0.track == index }, by: \.speaker)
        let durations = groups.mapValues { Self.merge($0.map { $0.start..<$0.end }).reduce(Frame(0)) { $0 + Frame($1.count) } }
        let total = durations.values.reduce(0, +)
        let dominant = durations.first { $0.value > total - $0.value && Double($0.value) >= 0.8 * Double(total) }?.key
        speaker = dominant
        mayName = groups.count <= 1 || dominant != nil
        let padding = Frame(project.sampleRate * 0.15)
        let speech = (restrictToSpeech ? dominant : nil).map { speaker in
            Self.merge(groups[speaker, default: []].map { max(0, $0.start - padding)..<($0.end + padding) })
        }

        let sources = Dictionary(project.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var spans: [Span] = []
        var end: Frame = 0
        var previousEnd: Frame?
        for clip in track.clips.sorted(by: { $0.start < $1.start }) {
            guard let source = sources[clip.sourceID] else { continue }
            let ranges = speech.map { ranges in
                let first = ranges.partitioningIndex { $0.upperBound > clip.start }
                return ranges[first...].prefix { $0.lowerBound < clip.end }.map { $0.clamped(to: clip.range) }
            } ?? [clip.range]
            for range in ranges where !range.isEmpty {
                if let previousEnd, previousEnd != range.lowerBound { end += padding * 2 }
                let length = Frame(range.count)
                spans.append(Span(source: source, sourceStart: clip.sourceStart + range.lowerBound - clip.start,
                                  timelineStart: range.lowerBound, input: end..<(end + length)))
                end += length
                previousEnd = range.upperBound
            }
        }
        self.spans = spans
    }

    static func merge(_ ranges: [Range<Frame>]) -> [Range<Frame>] {
        var merged: [Range<Frame>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, last.upperBound >= range.lowerBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private func anchor(_ word: Word) -> (Span, Range<Frame>)? {
        guard word.start < word.end else { return nil }
        let first = spans.partitioningIndex { $0.input.upperBound > word.start }
        let candidates = spans[first...].prefix { $0.input.lowerBound < word.end }
        guard let span = candidates.max(by: { $0.input.clamped(to: word.range).count < $1.input.clamped(to: word.range).count }) else { return nil }
        return (span, span.input.clamped(to: word.range))
    }

    /// Anchor each word in the source span that contains most of its audio.
    public func sourceWords(_ words: [Word]) -> [UUID: [Word]] {
        var bySource: [UUID: [Word]] = [:]
        for word in words {
            guard let (span, overlap) = anchor(word) else { continue }
            var anchored = word
            anchored.start = span.sourceStart + overlap.lowerBound - span.input.lowerBound
            anchored.end = anchored.start + Frame(overlap.count)
            anchored.speaker = speaker
            bySource[span.source.id, default: []].append(anchored)
        }
        return bySource.mapValues { words in
            // The same media range can appear twice on the track.
            var seen: [Range<Frame>: Set<String>] = [:]
            return words.sorted { $0.start < $1.start }.filter { seen[$0.range, default: []].insert($0.text).inserted }
        }
    }

    /// Positions used to find who was speaking directly before this track in the original recording.
    public func timelineWords(_ words: [Word]) -> [Word] {
        words.compactMap { word in
            guard let (span, overlap) = anchor(word) else { return nil }
            var placed = word
            placed.start = span.timelineStart + overlap.lowerBound - span.input.lowerBound
            placed.end = placed.start + Frame(overlap.count)
            return placed
        }
    }

    /// Give the track its own transcript anchors, while its clips still read the exact same audio.
    public func apply(_ transcript: SourceTranscript, name: String?, to project: inout Project) -> Int {
        guard let index = project.tracks.firstIndex(where: { $0.id == track.id }),
              project.tracks[index].clips == track.clips else { return 0 }
        let words = sourceWords(transcript.words)
        guard !words.isEmpty else { return 0 }
        let sourceIDs = Set(track.clips.map(\.sourceID))
        var aliases: [UUID: UUID] = [:]
        for sourceID in sourceIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard var source = project.source(sourceID) else { continue }
            let shared = project.tracks.contains { $0.id != track.id && $0.clips.contains { $0.sourceID == sourceID } }
            if shared {
                source.id = UUID()
                project.sources.append(source)
                if var turns = project.speakerTurns.first(where: { $0.sourceID == sourceID }) {
                    turns.sourceID = source.id
                    if let speaker { turns.turns.removeAll { $0.speaker != speaker } }
                    project.speakerTurns.append(turns)
                }
            }
            aliases[sourceID] = source.id
            project.setTranscript(SourceTranscript(sourceID: source.id, language: transcript.language, engine: transcript.engine,
                                                   words: words[sourceID] ?? [], speakers: transcript.speakers, textOnly: transcript.textOnly))
        }
        for i in project.tracks[index].clips.indices {
            let sourceID = project.tracks[index].clips[i].sourceID
            if let alias = aliases[sourceID] { project.tracks[index].clips[i].sourceID = alias }
        }
        if let name, project.tracks[index].name == track.name { project.tracks[index].name = name }
        return words.values.reduce(0) { $0 + $1.count }
    }
}
