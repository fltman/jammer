import Foundation

/// A speaker whose name came from a voice profile on this Mac: that it did, and how alike (0–1). The document
/// carries only this and the name, never a voiceprint (SIBLINGS, "Röstprofiler och andra biometriska avtryck").
public struct SpeakerSuggestion: Codable, Hashable, Sendable {
    public var speaker: Int
    public var score: Double
    public init(speaker: Int, score: Double) {
        self.speaker = speaker
        self.score = score
    }
}

/// Naming speakers after saved voice profiles. The threshold was measured before the feature was shown
/// (docs/DIARISATION.md, "Voice profiles"): 0.60, no false match among 40 real readers in any condition.
public enum VoiceMatch {
    public static let threshold = 0.60

    public struct Profile: Sendable, Equatable {
        public var id: UUID
        public var name: String
        public var print: [Float]
        public init(id: UUID, name: String, print: [Float]) {
            self.id = id
            self.name = name
            self.print = print
        }
    }
    public struct Match: Sendable, Equatable {
        public var profile: UUID
        public var name: String
        public var score: Double
    }

    /// The speakers that may be named after a profile, each profile used at most once, by the best total
    /// likeness (every pairing is tried for up to 7 speakers, else the best pairs first). A speaker below the
    /// threshold, or one whose name the user set (`protected`), keeps its name; a speaker that lost its best
    /// profile to another speaker gets it as an alternative.
    public static func assign(prints: [Int: [Float]], profiles: [Profile], protected: Set<Int> = [], threshold: Double = threshold)
        -> (matches: [Int: Match], alternatives: [Int: Match]) {
        let speakers = prints.keys.filter { !protected.contains($0) }.sorted()
        guard !speakers.isEmpty, !profiles.isEmpty else { return ([:], [:]) }
        var score: [Int: [Double]] = [:]
        for s in speakers { score[s] = profiles.map { VoicePrint.similarity(prints[s]!, $0.print) } }
        func usable(_ s: Int, _ p: Int) -> Bool { score[s]![p] >= threshold }
        var best: [Int: Int] = [:], bestTotal = -1.0
        if speakers.count <= 7 {
            // Every pairing of speakers with profiles (or with none).
            func walk(_ i: Int, _ used: Set<Int>, _ chosen: [Int: Int], _ total: Double) {
                if i == speakers.count {
                    if total > bestTotal + 1e-12 { bestTotal = total; best = chosen }
                    return
                }
                let s = speakers[i]
                walk(i + 1, used, chosen, total)
                for p in profiles.indices where !used.contains(p) && usable(s, p) {
                    var c = chosen; c[s] = p
                    walk(i + 1, used.union([p]), c, total + score[s]![p])
                }
            }
            walk(0, [], [:], 0)
        } else {
            var pairs: [(Int, Int, Double)] = []
            for s in speakers { for p in profiles.indices where usable(s, p) { pairs.append((s, p, score[s]![p])) } }
            var usedS = Set<Int>(), usedP = Set<Int>()
            for (s, p, _) in pairs.sorted(by: { $0.2 > $1.2 }) where !usedS.contains(s) && !usedP.contains(p) { best[s] = p; usedS.insert(s); usedP.insert(p) }
        }
        var matches: [Int: Match] = [:], alternatives: [Int: Match] = [:]
        for (s, p) in best { matches[s] = Match(profile: profiles[p].id, name: profiles[p].name, score: score[s]![p]) }
        for s in speakers where matches[s] == nil {
            if let p = profiles.indices.max(by: { score[s]![$0] < score[s]![$1] }), usable(s, p) {
                alternatives[s] = Match(profile: profiles[p].id, name: profiles[p].name, score: score[s]![p])
            }
        }
        return (matches, alternatives)
    }

    /// A name the diarisation gave ("Speaker 3"), which a profile may replace; any other name the user set.
    public static func isGiven(_ name: String) -> Bool { name.range(of: #"^Speaker \d+$"#, options: .regularExpression) != nil }
}

public enum SplitSpeakersError: Error, LocalizedError, Equatable, KeyedFailure {
    case noTrack(String)
    case noSpeakers(String)
    case oneSpeaker(String)
    public var reason: String {
        switch self {
        case .noTrack: "not_found"
        case .noSpeakers: "no_speakers"
        case .oneSpeaker: "one_speaker"
        }
    }
    var said: Said {
        switch self {
        case .noTrack(let t): Said("split.noTrack", "There is no track %@.", t)
        case .noSpeakers(let t): Said("split.noSpeakers", "%@ has no speakers yet: find the speakers first (Audio › Find Speakers).", t)
        case .oneSpeaker(let t): Said("split.oneSpeaker", "Only one speaker was found on %@, so there is nothing to split.", t)
        }
    }
    public var errorDescription: String? { said.text }
    public var keyed: KeyedMessage? { said.keyed }
}

extension Project {
    /// Splits a track into one track per speaker found on it (diarize first). Every frame of its clips goes to
    /// exactly one new track, so that together they play exactly what the track did: a speaker's turns to that
    /// speaker; where two talk at once, to the one whose turn is longer; a pause between turns to the nearer
    /// speaker (split at its middle); before the first turn and after the last, to that turn's speaker. Clips are
    /// cut, never changed, and no file is touched. The new tracks take the track's level, pan, plugins and
    /// output; the original is muted and kept (`keepOriginal`) or removed. Returns the new tracks' ids, in the
    /// order of the speakers' first turns.
    @discardableResult
    public mutating func splitSpeakers(track id: UUID, keepOriginal: Bool = true) throws -> [UUID] {
        guard let ti = tracks.firstIndex(where: { $0.id == id }) else { throw SplitSpeakersError.noTrack(id.uuidString) }
        let track = tracks[ti]
        let turns = placedTurns().filter { $0.track == ti }
        guard !turns.isEmpty else { throw SplitSpeakersError.noSpeakers(track.name) }
        guard Set(turns.map(\.speaker)).count > 1 else { throw SplitSpeakersError.oneSpeaker(track.name) }
        // Who owns each stretch of the track's timeline.
        let points = Array(Set(turns.flatMap { [$0.start, $0.end] } + track.clips.flatMap { [$0.start, $0.end] })).sorted()
        var owned: [(range: Range<Frame>, speaker: Int)] = []
        for (a, b) in zip(points, points.dropFirst()) where b > a {
            let covering = turns.filter { $0.start <= a && $0.end >= b }
            let owner: Int
            if let longest = covering.max(by: { ($0.end - $0.start, -$0.speaker) < ($1.end - $1.start, -$1.speaker) }) {
                owner = longest.speaker
            } else {
                let before = turns.filter { $0.end <= a }.max { $0.end < $1.end }, after = turns.filter { $0.start >= b }.min { $0.start < $1.start }
                switch (before, after) {
                case let (x?, y?):
                    // The pause between them, split at its middle.
                    let mid = x.end + (y.start - x.end) / 2
                    if b <= mid { owner = x.speaker }
                    else if a >= mid { owner = y.speaker }
                    else { owned.append((a..<mid, x.speaker)); owned.append((mid..<b, y.speaker)); continue }
                case let (x?, nil): owner = x.speaker
                case let (nil, y?): owner = y.speaker
                default: continue
                }
            }
            if let last = owned.last, last.speaker == owner, last.range.upperBound == a { owned[owned.count - 1].range = last.range.lowerBound..<b }
            else { owned.append((a..<b, owner)) }
        }
        let order = turns.sorted { $0.start < $1.start }.reduce(into: [Int]()) { if !$0.contains($1.speaker) { $0.append($1.speaker) } }
        var made: [Track] = []
        for speaker in order {
            var t = track
            t.id = UUID()
            t.name = speakers.indices.contains(speaker) ? speakers[speaker] : "Speaker \(speaker + 1)"
            t.isMuted = false
            t.origin = nil
            // A frozen track's file is of the whole track: the new tracks play their own clips.
            t.frozen = nil
            t.clips = []
            for clip in track.clips {
                for o in owned where o.speaker == speaker && o.range.overlaps(clip.range) {
                    var piece: Clip? = clip
                    if let p = piece, o.range.lowerBound > p.start { piece = p.split(at: o.range.lowerBound).1 }
                    if let p = piece, o.range.upperBound < p.end { piece = p.split(at: o.range.upperBound).0 }
                    if var p = piece { p.id = UUID(); t.clips.append(p) }
                }
            }
            made.append(t)
        }
        if keepOriginal { tracks[ti].isMuted = true } else { tracks.remove(at: ti) }
        tracks.insert(contentsOf: made, at: keepOriginal ? ti + 1 : ti)
        return made.map(\.id)
    }
}

/// Files that hold biometric data (voice profiles), in an app that isn't sandboxed: the folder only the user can
/// open (0700), each file only the user can read (0600), written atomically (a temporary file in the same folder,
/// renamed over the old one), and rights that have become wider tightened again (SIBLINGS, "Röstprofiler").
public enum PrivateFiles {
    public static let folderMode: mode_t = 0o700
    public static let fileMode: mode_t = 0o600

    public static func write(_ data: Data, named name: String, in folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: Int(folderMode)])
        try fm.setAttributes([.posixPermissions: Int(folderMode)], ofItemAtPath: folder.path)
        let temp = folder.appending(path: ".\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: Int(fileMode)]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // rename(2): the old file is replaced in one step, never left half written.
        if Foundation.rename(temp.path, folder.appending(path: name).path) != 0 {
            try? fm.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Tightens the folder and its files to 0700 and 0600 where they are wider; the names of what was changed
    /// (for a line in the log: never the contents).
    @discardableResult
    public static func tighten(_ folder: URL) -> [String] {
        let fm = FileManager.default
        var changed: [String] = []
        func mode(_ path: String) -> mode_t? { (try? fm.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber).map { mode_t($0.uint16Value) } }
        guard let m = mode(folder.path) else { return [] }
        if m & 0o077 != 0 { try? fm.setAttributes([.posixPermissions: Int(folderMode)], ofItemAtPath: folder.path); changed.append(folder.lastPathComponent) }
        for f in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] {
            let path = folder.appending(path: f).path
            if let fm2 = mode(path), fm2 & 0o077 != 0 { try? fm.setAttributes([.posixPermissions: Int(fileMode)], ofItemAtPath: path); changed.append(f) }
        }
        return changed
    }
}
