import Foundation

public enum LevelError: Error, LocalizedError, Equatable {
    case noSpeakers
    case silent

    public var reason: String {
        switch self {
        case .noSpeakers: "no_speakers"
        case .silent: "nothing_to_measure"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .noSpeakers: "There are no speakers yet; run diarize (Audio › Find Speakers) first."
        case .silent: "The speakers' turns are too quiet or short to measure."
        }
    }
}

public struct SpeakerLevelReport: Sendable, Equatable {
    /// Speaker id → loudness before (LUFS) and the gain applied (dB).
    public var before: [Int: Double]
    public var gains: [Int: Double]
    /// True when some speaker needed more than `maxGain`.
    public var limited: Bool
    public var maxChangeDB: Double { gains.values.map(abs).max() ?? 0 }
}

extension Project {
    /// Each speaker's integrated loudness (BS.1770, gated) over their own turns, as heard:
    /// clip and track gain included.
    public func speakerLoudness(pool: SourcePool) -> [Int: Double] {
        let turns = placedTurns()
        var out: [Int: Double] = [:]
        for speaker in Set(turns.map(\.speaker)) {
            var meter = LoudnessMeter(sampleRate: sampleRate, channels: channels)
            let mine = turns.filter { $0.speaker == speaker }
            for t in Set(mine.map(\.track)) where !tracks[t].isMuted {
                var solo = self
                solo.tracks = [tracks[t]]
                let plan = PlanCompiler.compile(solo, pool: pool)
                for turn in mine where turn.track == t { plan.render(turn.start..<turn.end) { meter.process($0) } }
            }
            if let l = meter.result.integrated, l.isFinite { out[speaker] = l }
        }
        return out
    }

    /// Brings every speaker (or those in `only`) to `target` LUFS with one static gain each,
    /// limited to ±`maxGain` dB. A track with a single speaker gets track gain; a track with
    /// several is split where the speaker changes (in the middle of the pause between
    /// turns) and each piece gets its speaker's gain; where speakers overlap, the lower
    /// gain wins. Sources are untouched, so words and turns keep their ids and times.
    public func levellingSpeakers(target: Double = -18, maxGain: Double = 12, only: Set<Int>? = nil,
                                  pool: SourcePool) throws -> (Project, SpeakerLevelReport) {
        guard !speakerTurns.isEmpty, !placedTurns().isEmpty else { throw LevelError.noSpeakers }
        let loudness = speakerLoudness(pool: pool).filter { only?.contains($0.key) ?? true }
        guard !loudness.isEmpty else { throw LevelError.silent }
        var gains: [Int: Double] = [:]
        var limited = false
        for (s, l) in loudness {
            let want = target - l
            let g = min(maxGain, max(-maxGain, want))
            if g != want { limited = true }
            gains[s] = (g * 100).rounded() / 100
        }
        var p = self
        let turns = placedTurns()
        for t in tracks.indices {
            let mine = turns.filter { $0.track == t && gains[$0.speaker] != nil }.sorted { $0.start < $1.start }
            let speakers = Set(mine.map(\.speaker))
            guard !speakers.isEmpty else { continue }
            let elsewhere = speakers.contains { s in turns.contains { $0.speaker == s && $0.track != t } }
            if speakers.count == 1, !elsewhere, !turns.contains(where: { $0.track == t && gains[$0.speaker] == nil }) {
                p.tracks[t].gainDB += gains[speakers.first!]!
                continue
            }
            p.tracks[t].clips = Self.applyPiecewiseGain(p.tracks[t].clips, segments: Self.gainSegments(mine, gains: gains))
        }
        return (p, SpeakerLevelReport(before: loudness, gains: gains, limited: limited))
    }

    /// Piecewise-constant gain over the timeline from a track's turns: inside turns the
    /// lowest gain of the speakers talking; in a pause, the speaker before it up to the
    /// pause's middle and the one after it from there.
    static func gainSegments(_ turns: [PlacedTurn], gains: [Int: Double]) -> [(start: Frame, gain: Double)] {
        guard !turns.isEmpty else { return [] }
        var points = Set<Frame>()
        for t in turns { points.insert(t.start); points.insert(t.end) }
        // Pause middles between turns that don't touch.
        let ordered = turns.sorted { $0.start < $1.start }
        var reach = ordered[0].end
        for t in ordered.dropFirst() {
            if t.start > reach { points.insert((reach + t.start) / 2) }
            reach = max(reach, t.end)
        }
        let cuts = points.sorted()
        func gain(at x: Frame) -> Double {
            let active = turns.filter { $0.start <= x && x < $0.end }
            if !active.isEmpty { return active.map { gains[$0.speaker] ?? 0 }.min()! }
            let before = turns.filter { $0.end <= x }.max { $0.end < $1.end }
            let after = turns.filter { $0.start > x }.min { $0.start < $1.start }
            switch (before, after) {
            case let (b?, a?): return x < (b.end + a.start) / 2 ? gains[b.speaker] ?? 0 : gains[a.speaker] ?? 0
            case let (b?, nil): return gains[b.speaker] ?? 0
            case let (nil, a?): return gains[a.speaker] ?? 0
            default: return 0
            }
        }
        var out: [(Frame, Double)] = [(.min, gain(at: cuts[0] - 1))]
        for c in cuts {
            let g = gain(at: c)
            if g != out.last!.1 { out.append((c, g)) }
        }
        return out
    }

    /// Splits clips at the segment starts and adds each segment's gain to its pieces.
    static func applyPiecewiseGain(_ clips: [Clip], segments: [(start: Frame, gain: Double)]) -> [Clip] {
        var pieces = clips
        for s in segments where s.start != .min {
            pieces = pieces.flatMap { c -> [Clip] in
                guard c.start < s.start, c.end > s.start else { return [c] }
                let (l, r) = c.split(at: s.start)
                return [l, r].compactMap { $0 }
            }
        }
        return pieces.map { c in
            var c = c
            let g = segments.last { $0.start <= c.start }?.gain ?? segments.first?.gain ?? 0
            guard g != 0 else { return c }
            c.gainDB = ((c.gainDB + g) * 1_000).rounded() / 1_000
            return c
        }.sorted { $0.start < $1.start }
    }
}
