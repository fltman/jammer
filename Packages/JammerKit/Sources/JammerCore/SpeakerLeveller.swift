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
    /// The same message by its key in the app's string catalogue (see `KeyedMessage`).
    public var keyed: KeyedMessage? {
        switch self {
        case .noSpeakers: KeyedMessage("error.level.noSpeakers")
        case .silent: KeyedMessage("error.level.silent")
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
                solo.withoutMixer()
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

public struct DynamicLevelReport: Sendable, Equatable {
    public var speakers: Int
    public var maxChangeDB: Double
    /// Spread of short-term loudness under speech (95th minus 10th percentile), LU.
    public var spreadBefore: Double
    public var spreadAfter: Double
}

extension Project {
    /// level_speakers mode dynamic: rides each speaker's gain over time towards `target`,
    /// from short-term loudness (3 s) over their own speech only. Offline, so it looks
    /// ahead: the window is centred, the curve is smoothed both ways (no lag, no pumping
    /// at a speech start), segments break at pauses over 5 s, and in a pause the gain is
    /// the lower of the gains either side, so silence is never lifted. Each track with
    /// speakers is bounced into a new file over its extent; others stay as they are.
    public func levellingSpeakersDynamically(target: Double = -18, maxGain: Double = 12, only: Set<Int>? = nil,
                                             pool: SourcePool, media: URL) throws -> (Project, DynamicLevelReport) {
        let turns = placedTurns().filter { only?.contains($0.speaker) ?? true }
        guard !turns.isEmpty else { throw LevelError.noSpeakers }
        let blockLen = Int(sampleRate / 10)
        var p = self
        let words = placedWords()
        var maxChange = 0.0
        var stBefore: [Double] = [], stAfter: [Double] = []
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        for t in tracks.indices where !tracks[t].isMuted {
            let mine = turns.filter { $0.track == t }
            guard !mine.isEmpty else { continue }
            var solo = self
            solo.tracks = [tracks[t]]
            solo.withoutMixer()
            solo.tracks[0].gainDB = 0
            let first = tracks[t].clips.map(\.start).min()!, end = tracks[t].end
            let plan = PlanCompiler.compile(solo, pool: pool)
            let raw = plan.render(from: 0, frames: Int(length))
            var meter = LoudnessMeter(sampleRate: sampleRate, channels: channels)
            raw.withUnsafeBufferPointer { meter.process($0) }
            let e = meter.blockEnergies
            let nb = e.count
            guard nb > 0 else { continue }
            func lufs(_ x: Double) -> Double { -0.691 + 10 * log10(max(1e-12, x)) }
            // Who talks in each block (by its centre).
            var talkers = [[Int]](repeating: [], count: nb)
            for b in 0..<nb {
                let c = Frame(b * blockLen + blockLen / 2)
                talkers[b] = Array(Set(mine.filter { $0.start <= c && c < $0.end }.map(\.speaker))).sorted()
            }
            var curves: [Int: [Double?]] = [:]
            let smooth = { (x: [Double], tc: Double) -> [Double] in
                let a = 1 - exp(-0.1 / tc)
                var f = x
                for i in 1..<max(1, f.count) { f[i] = f[i - 1] + a * (f[i] - f[i - 1]) }
                if f.count > 1 { for i in stride(from: f.count - 2, through: 0, by: -1) { f[i] = f[i + 1] + a * (f[i] - f[i + 1]) } }
                return f
            }
            for s in Set(mine.map(\.speaker)) {
                let blocks = (0..<nb).filter { talkers[$0].contains(s) }
                // Segments: runs of this speaker's blocks without a pause over 5 s.
                var segments: [[Int]] = []
                for b in blocks {
                    if let last = segments.last?.last, b - last <= 50 { segments[segments.count - 1].append(b) } else { segments.append([b]) }
                }
                var curve = [Double?](repeating: nil, count: nb)
                for seg in segments {
                    let d = seg.map { b -> Double in
                        let win = seg.filter { abs($0 - b) <= 15 }
                        let st = lufs(win.map { e[$0] }.reduce(0, +) / Double(win.count)) + tracks[t].gainDB
                        stBefore.append(st)
                        return min(maxGain, max(-maxGain, target - st))
                    }
                    for (b, g) in zip(seg, smooth(d, 1.0)) { curve[b] = g }
                }
                curves[s] = curve
            }
            // One curve per track: the lowest speaker gain where they talk; in pauses, the
            // lower of the gains on either side.
            var g = [Double?](repeating: nil, count: nb)
            for b in 0..<nb where !talkers[b].isEmpty { g[b] = talkers[b].compactMap { curves[$0]?[b] ?? nil }.min() }
            var prev: Double? = nil
            var before = [Double?](repeating: nil, count: nb)
            for b in 0..<nb { if let v = g[b] { prev = v }; before[b] = prev }
            var next: Double? = nil
            var gain = [Double](repeating: 0, count: nb)
            for b in stride(from: nb - 1, through: 0, by: -1) {
                if let v = g[b] { next = v; gain[b] = v; continue }
                gain[b] = [before[b], next].compactMap { $0 }.min() ?? 0
            }
            for (b, v) in gain.enumerated() where !talkers[b].isEmpty { maxChange = max(maxChange, abs(v)) }
            // Short-term after, for the report (same centred windows).
            for s in Set(mine.map(\.speaker)) {
                let blocks = (0..<nb).filter { talkers[$0].contains(s) }
                for b in blocks {
                    let win = blocks.filter { abs($0 - b) <= 15 }
                    let st = lufs(win.map { e[$0] * pow(10, gain[$0] / 10) }.reduce(0, +) / Double(win.count)) + tracks[t].gainDB
                    stAfter.append(st)
                }
            }
            // Per-sample gain, interpolated between block centres.
            var out = raw
            let ch = channels
            for i in 0..<Int(length) {
                let pos = (Double(i) - Double(blockLen) / 2) / Double(blockLen)
                let b0 = max(0, min(nb - 1, Int(pos.rounded(.down)))), b1 = min(nb - 1, b0 + 1)
                let f = max(0, min(1, pos - Double(b0)))
                let db = gain[b0] + (gain[b1] - gain[b0]) * f
                guard db != 0 else { continue }
                let lin = Float(pow(10, db / 20))
                for c in 0..<ch { out[i * ch + c] = raw[i * ch + c] * lin }
            }
            let url = media.appending(path: "\(UUID().uuidString.prefix(8)) levelled.wav")
            // Noted as made by Jämmer: only such a file can ever be offered for removal (MediaStorage).
            MediaRegister.made(url, kind: "levelled", in: media)
            let w = try WAVWriter(url: url, options: .init(encoding: .float32, channels: channels, sampleRate: sampleRate))
            try w.write(Array(out[Int(first) * ch..<Int(end) * ch]))
            try w.finish()
            let src = SourceRef(name: "\(tracks[t].name) (levelled)", path: url.path, info: try AudioFileReader.info(at: url)).withRepairs(repairsCarried(by: tracks[t]))
            p.sources.append(src)
            let ws = words.filter { $0.track == t }.map { w -> Word in var w2 = w.word; w2.start = w.start - first; w2.end = w.end - first; return w2 }
            if !ws.isEmpty { p.setTranscript(SourceTranscript(sourceID: src.id, language: transcripts.first?.language ?? "und", engine: "carried", words: ws)) }
            p.addCarriedTurns(turnsForBounce(track: t, range: first..<end), to: src.id)
            p.tracks[t].clips = [Clip(sourceID: src.id, start: first, length: end - first)]
        }
        p.pruneSources()
        func spread(_ x: [Double]) -> Double {
            let s = x.sorted()
            guard s.count > 2 else { return 0 }
            return ((s[Int(Double(s.count - 1) * 0.95)] - s[Int(Double(s.count - 1) * 0.10)]) * 10).rounded() / 10
        }
        return (p, DynamicLevelReport(speakers: Set(turns.map(\.speaker)).count, maxChangeDB: (maxChange * 100).rounded() / 100,
                                      spreadBefore: spread(stBefore), spreadAfter: spread(stAfter)))
    }
}

extension LevelError: KeyedFailure {}
