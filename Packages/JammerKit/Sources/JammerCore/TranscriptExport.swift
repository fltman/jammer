import Foundation

public enum TranscriptExport: String, CaseIterable, Sendable {
    case txt, json, srt, vtt

    public var contentType: String {
        switch self {
        case .txt: "text/plain; charset=utf-8"
        case .json: "application/json"
        case .srt: "application/x-subrip"
        case .vtt: "text/vtt; charset=utf-8"
        }
    }

    public enum Failure: Error, Equatable, LocalizedError, KeyedFailure {
        case noWords, needsTimes

        public var keyed: KeyedMessage? { said.keyed }
        public var errorDescription: String? { said.text }

        private var said: Said {
            switch self {
            case .noWords: Said("error.transcript.exportEmpty", "There is no transcript to export for those tracks.")
            case .needsTimes: Said("error.transcript.exportTimes", "Subtitle export needs word timestamps. Choose TXT or JSON, or transcribe with a local engine.")
            }
        }
    }

    private struct ExportedWord: Encodable {
        let text: String
        let start: Double?
        let end: Double?
        let partial: Bool
    }

    private struct ExportedTrack: Encodable {
        struct Recognition: Encodable, Hashable { let language: String; let engine: String }
        let id: UUID
        let name: String
        let recognition: [Recognition]
        let text: String
        let words: [ExportedWord]
    }

    private struct Cue {
        var track: Int
        var start: Frame
        var end: Frame
        var words: [String]
    }

    public func data(project: Project, tracks: Set<UUID>? = nil) throws -> Data {
        let words = project.placedWords().filter { tracks?.contains(project.tracks[$0.track].id) ?? true }
        guard !words.isEmpty else { throw Failure.noWords }
        let byTrack = Dictionary(grouping: words, by: \.track)
        let transcripts = Dictionary(project.transcripts.map { ($0.sourceID, $0) }, uniquingKeysWith: { first, _ in first })
        let textOnlyIDs = Set(project.transcripts.filter { $0.textOnly == true }.flatMap { $0.words.map(\.id) })
        func hasTime(_ word: PlacedWord) -> Bool { word.word.untimed != true && !textOnlyIDs.contains(word.word.id) }
        if self == .json {
            let tracks = byTrack.keys.sorted().map { index in
                let track = project.tracks[index]
                let words = byTrack[index, default: []]
                let recognition = Set(track.clips.compactMap { transcripts[$0.sourceID] }.map {
                    ExportedTrack.Recognition(language: $0.language, engine: $0.engine)
                }).sorted { ($0.language, $0.engine) < ($1.language, $1.engine) }
                return ExportedTrack(id: track.id, name: track.name, recognition: recognition,
                                     text: words.map(\.word.text).joined(separator: " "), words: words.map { word in
                    ExportedWord(text: word.word.text, start: hasTime(word) ? project.seconds(word.start) : nil,
                                 end: hasTime(word) ? project.seconds(word.end) : nil, partial: word.isPartial)
                })
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(["tracks": tracks])
        }

        if self != .txt, !words.allSatisfy(hasTime) { throw Failure.needsTimes }
        let cues = Self.cues(words, sampleRate: project.sampleRate)
        var lines: [String] = self == .vtt ? ["WEBVTT", ""] : []
        for (i, cue) in cues.enumerated() {
            let text = cue.words.joined(separator: " ")
            let name = Self.singleLine(project.tracks[cue.track].name)
            let multiple = byTrack.count > 1
            switch self {
            case .txt:
                lines.append(multiple ? "\(name): \(text)" : text)
            case .json: break
            case .srt, .vtt:
                let start = project.seconds(cue.start)
                let end = max(project.seconds(cue.end), start + 0.001)
                if self == .srt { lines.append(String(i + 1)) }
                lines.append("\(timestamp(start)) --> \(timestamp(end))")
                let body = multiple ? "\(name): \(text)" : text
                lines.append(body.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;"))
                lines.append("")
            }
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private static func singleLine(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func cues(_ words: [PlacedWord], sampleRate: Double) -> [Cue] {
        var cues: [Cue] = []
        for word in words {
            let text = singleLine(word.word.text)
            guard !text.isEmpty else { continue }
            if let i = cues.indices.last, cues[i].track == word.track,
               word.start - cues[i].end <= Frame(sampleRate * 0.75),
               word.end - cues[i].start <= Frame(sampleRate * 5),
               cues[i].words.reduce(text.count, { $0 + $1.count + 1 }) <= 76 {
                cues[i].words.append(text)
                cues[i].end = max(cues[i].end, word.end)
            } else {
                cues.append(Cue(track: word.track, start: word.start, end: word.end, words: [text]))
            }
        }
        return cues
    }

    private func timestamp(_ seconds: Double) -> String {
        let ms = Int((max(0, seconds) * 1_000).rounded())
        let separator = self == .srt ? "," : "."
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1_000 % 60, separator, ms % 1_000)
    }
}
