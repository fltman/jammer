import Accelerate
import Foundation

/// One stretch from a diarisation model: a speaker label and seconds from the start.
public struct DiarizedSegment: Sendable, Equatable {
    public var speaker: String
    public var start: Double
    public var end: Double
    public init(speaker: String, start: Double, end: Double) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

/// A speaker diarisation model fed 16 kHz mono (FluidAudio's Community-1 pipeline in the app).
public protocol SpeakerDiarizer: Sendable {
    /// Stored with the turns, e.g. "pyannote-community-1".
    var engineName: String { get }
    func diarize(mono16k: [Float], minSpeakers: Int?, maxSpeakers: Int?,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> [DiarizedSegment]
}

public enum DiarizationError: Error, LocalizedError, Equatable {
    case noEngine
    case nothingToDo
    case model(String)

    public var reason: String {
        switch self {
        case .noEngine, .model: "model_unavailable"
        case .nothingToDo: "nothing_to_diarize"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .noEngine: "This copy of Jämmer has no diarisation model."
        case .nothingToDo: "There's no audio on those tracks."
        case .model(let m): m
        }
    }
    /// The same message by its key in the app's string catalogue (see `KeyedMessage`).
    public var keyed: KeyedMessage? {
        switch self {
        case .noEngine: KeyedMessage("error.diarization.noEngine")
        case .nothingToDo: KeyedMessage("error.diarization.nothingToDo")
        case .model: nil
        }
    }
}

public enum Diarization {
    /// Registered by the app (FluidAudio); nil in builds without it.
    nonisolated(unsafe) public static var engine: SpeakerDiarizer?

    // MARK: By track

    /// Level analysis frames: 10 ms hop, 20 ms window.
    static let hopSeconds = 0.01

    /// Each track is its speaker (a double-ender): a track speaks where it's well above
    /// its own noise floor *and* louder than the other tracks' bleed into it would make
    /// it. The bleed level between two tracks is measured where one of them clearly
    /// talks alone, so real overlaps (both talking) still count for both.
    public static func byTrack(_ project: Project, pool: SourcePool, tracks wanted: [UUID]) -> [TrackDiarization] {
        let active = project.tracks.indices.filter { !project.tracks[$0].isMuted && !project.tracks[$0].clips.isEmpty }
        let targets = wanted.compactMap { id in project.tracks.firstIndex { $0.id == id } }.filter { active.contains($0) }
        guard !targets.isEmpty else { return [] }
        let levels = active.map { levelsDB(project, track: $0, pool: pool) }
        let n = levels.map(\.count).min() ?? 0
        let threshold = levels.map { l -> Float in
            let sorted = l.prefix(n).sorted()
            let floor = sorted.isEmpty ? -100 : max(-100, sorted[sorted.count / 10])
            return max(floor + 12, -60)
        }
        // Where each track clearly talks alone.
        let dominant: [[Bool]] = active.indices.map { i in
            (0..<n).map { f in
                levels[i][f] > threshold[i] && active.indices.allSatisfy { j in j == i || levels[i][f] >= levels[j][f] + 10 }
            }
        }
        // bleed[i][j]: track i's level relative to track j while only j talks (negative dB).
        var bleed = [[Float?]](repeating: [Float?](repeating: nil, count: active.count), count: active.count)
        for i in active.indices {
            for j in active.indices where j != i {
                let d = (0..<n).filter { dominant[j][$0] }.map { levels[i][$0] - levels[j][$0] }.sorted()
                if d.count >= 50 { bleed[i][j] = d[d.count / 2] }
            }
        }
        let frame = Frame(hopSeconds * project.sampleRate)
        return targets.map { t in
            let i = active.firstIndex(of: t)!
            var speech = (0..<n).map { f in
                levels[i][f] > threshold[i] && active.indices.allSatisfy { j in
                    guard j != i, let b = bleed[i][j] else { return true }
                    return levels[i][f] > levels[j][f] + b + 6
                }
            }
            speech = smooth(speech, closeGaps: 25, minRun: 15)
            var turns: [TrackDiarization.Turn] = []
            var f = 0
            while f < n {
                guard speech[f] else { f += 1; continue }
                let start = f
                while f < n, speech[f] { f += 1 }
                // 50 ms of padding each side; level frames lag their window a little.
                let lo = max(0, Frame(start - 5) * frame), hi = min(project.length, Frame(f + 5) * frame)
                if let last = turns.last, last.range.upperBound >= lo {
                    turns[turns.count - 1].range = last.range.lowerBound..<hi
                } else {
                    turns.append(.init(speaker: 0, range: lo..<hi))
                }
            }
            return TrackDiarization(track: project.tracks[t].id, names: [project.tracks[t].name], turns: turns)
        }
    }

    /// Closes gaps shorter than `closeGaps` frames, then drops runs shorter than `minRun`.
    static func smooth(_ x: [Bool], closeGaps: Int, minRun: Int) -> [Bool] {
        var y = x
        var f = 0
        while f < y.count {
            if !y[f] {
                let start = f
                while f < y.count, !y[f] { f += 1 }
                if start > 0, f < y.count, f - start < closeGaps { for k in start..<f { y[k] = true } }
            } else { f += 1 }
        }
        f = 0
        while f < y.count {
            if y[f] {
                let start = f
                while f < y.count, y[f] { f += 1 }
                if f - start < minRun { for k in start..<f { y[k] = false } }
            } else { f += 1 }
        }
        return y
    }

    /// RMS level in dB per 10 ms of one track on its own (dry, unity gain), mono.
    static func levelsDB(_ project: Project, track t: Int, pool: SourcePool) -> [Float] {
        var solo = project
        solo.tracks = [project.tracks[t]]
        solo.withoutMixer()
        solo.tracks[0].gainDB = 0
        solo.tracks[0].isMuted = false
        let plan = PlanCompiler.compile(solo, pool: pool)
        let hop = max(1, Int(hopSeconds * project.sampleRate)), ch = project.channels
        var out: [Float] = []
        out.reserveCapacity(Int(project.length) / hop + 1)
        var previous = [Float](repeating: 0, count: hop)
        plan.render(0..<project.length, blockFrames: hop * 1_000) { block in
            let frames = block.count / ch
            var at = 0
            while at + hop <= frames {
                var sum: Float = 0
                for k in 0..<hop {
                    var v: Float = 0
                    for c in 0..<ch { v += block[(at + k) * ch + c] }
                    v /= Float(ch)
                    sum += v * v + previous[k] * previous[k]
                    previous[k] = v
                }
                out.append(10 * log10(max(1e-10, sum / Float(2 * hop))))
                at += hop
            }
        }
        return out
    }

    // MARK: Model

    /// Runs the registered model on each track (dry, mono, 16 kHz). Speakers are per
    /// track; names continue from the speakers the rest of the document keeps.
    public static func model(_ project: Project, pool: SourcePool, tracks wanted: [UUID], minSpeakers: Int?, maxSpeakers: Int?,
                             progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [TrackDiarization] {
        guard let engine else { throw DiarizationError.noEngine }
        let targets = wanted.compactMap { id in project.tracks.firstIndex { $0.id == id } }.filter { !project.tracks[$0].clips.isEmpty }
        guard !targets.isEmpty else { throw DiarizationError.nothingToDo }
        let replaced = Set(targets.flatMap { project.tracks[$0].clips.map(\.sourceID) })
        var next = Set(project.speakerTurns.filter { !replaced.contains($0.sourceID) }.flatMap { $0.turns.map(\.speaker) }).count + 1
        var results: [TrackDiarization] = []
        for (k, t) in targets.enumerated() {
            try Task.checkCancellation()
            let audio = try mono16k(project, track: t, pool: pool)
            let base = Double(k) / Double(targets.count), share = 1 / Double(targets.count)
            let segments = try await engine.diarize(mono16k: audio, minSpeakers: minSpeakers, maxSpeakers: maxSpeakers) { p in
                progress(base + share * p)
            }
            var local: [String: Int] = [:]
            var names: [String] = []
            var turns: [TrackDiarization.Turn] = []
            for s in segments.sorted(by: { $0.start < $1.start }) {
                let lo = max(0, project.frames(s.start)), hi = min(project.length, project.frames(s.end))
                guard hi > lo else { continue }
                let id = local[s.speaker] ?? {
                    local[s.speaker] = names.count
                    names.append("Speaker \(next)")
                    next += 1
                    return names.count - 1
                }()
                turns.append(.init(speaker: id, range: lo..<hi))
            }
            results.append(TrackDiarization(track: project.tracks[t].id, names: names, turns: turns))
        }
        progress(1)
        return results
    }

    /// One track on its own, mono, at 16 kHz. Integer ratios (48, 32, 96 kHz) are
    /// decimated as it renders; others go through AudioConverter in one piece.
    static func mono16k(_ project: Project, track t: Int, pool: SourcePool) throws -> [Float] {
        var solo = project
        solo.tracks = [project.tracks[t]]
        solo.withoutMixer()
        solo.tracks[0].gainDB = 0
        solo.tracks[0].isMuted = false
        let plan = PlanCompiler.compile(solo, pool: pool)
        let ch = project.channels, rate = project.sampleRate
        let ratio = rate / 16_000
        let factor = Int(ratio.rounded())
        if abs(ratio - Double(factor)) > 1e-9 || factor < 1 {
            var mono: [Float] = []
            mono.reserveCapacity(Int(project.length))
            plan.render(0..<project.length) { b in
                for f in 0..<(b.count / ch) { mono.append((0..<ch).reduce(0) { $0 + b[f * ch + $1] } / Float(ch)) }
            }
            return try Alignment.resample(mono, channels: 1, from: rate, to: 16_000)
        }
        if factor == 1 {
            var mono: [Float] = []
            plan.render(0..<project.length) { b in
                for f in 0..<(b.count / ch) { mono.append((0..<ch).reduce(0) { $0 + b[f * ch + $1] } / Float(ch)) }
            }
            return mono
        }
        // Windowed-sinc low-pass at 90 % of the new Nyquist (Blackman), then every factor-th sample.
        let taps = 32 * factor + 1
        let fc = 0.45 / Double(factor)
        var h = (0..<taps).map { i -> Float in
            let m = Double(i - taps / 2)
            let sinc = m == 0 ? 2 * fc : sin(2 * .pi * fc * m) / (.pi * m)
            let w = 0.42 - 0.5 * cos(2 * .pi * Double(i) / Double(taps - 1)) + 0.08 * cos(4 * .pi * Double(i) / Double(taps - 1))
            return Float(sinc * w)
        }
        let sum = h.reduce(0, +)
        h = h.map { $0 / sum }
        var pending = [Float](repeating: 0, count: taps / 2) // centres the filter: output n sits at input n·factor
        var out: [Float] = []
        out.reserveCapacity(Int(project.length) / factor + 1)
        func drain() {
            let n = pending.count >= taps ? (pending.count - taps) / factor + 1 : 0
            guard n > 0 else { return }
            var y = [Float](repeating: 0, count: n)
            vDSP_desamp(pending, vDSP_Stride(factor), h, &y, vDSP_Length(n), vDSP_Length(taps))
            out += y
            pending.removeFirst(n * factor)
        }
        plan.render(0..<project.length) { b in
            for f in 0..<(b.count / ch) { pending.append((0..<ch).reduce(0) { $0 + b[f * ch + $1] } / Float(ch)) }
            drain()
        }
        pending += [Float](repeating: 0, count: taps)
        drain()
        return Array(out.prefix(Int(project.length) / factor))
    }
}

/// Diarisation error rate, the standard measure: (missed speech + false alarms +
/// speaker confusion) / reference speech, over 10 ms frames, with the hypothesis
/// speakers mapped to the reference ones for the most overlap. Overlapped speech
/// counts per speaker. `collar` seconds around each reference boundary aren't scored.
public enum DiarizationScore {
    public struct Segment: Sendable, Equatable {
        public var speaker: String
        public var start: Double
        public var end: Double
        public init(_ speaker: String, _ start: Double, _ end: Double) {
            self.speaker = speaker
            self.start = start
            self.end = end
        }
    }

    public struct Result: Sendable, Equatable {
        public var der: Double
        public var missed: Double
        public var falseAlarm: Double
        public var confusion: Double
        public var referenceSeconds: Double
    }

    public static func score(reference: [Segment], hypothesis: [Segment], collar: Double = 0) -> Result {
        let step = 0.01
        let end = max(reference.map(\.end).max() ?? 0, hypothesis.map(\.end).max() ?? 0)
        let n = Int((end / step).rounded(.up)) + 1
        let refNames = Array(Set(reference.map(\.speaker))).sorted(), hypNames = Array(Set(hypothesis.map(\.speaker))).sorted()
        func grid(_ segs: [Segment], _ names: [String]) -> [[Bool]] {
            var g = [[Bool]](repeating: [Bool](repeating: false, count: n), count: names.count)
            for s in segs {
                let k = names.firstIndex(of: s.speaker)!
                for f in max(0, Int((s.start / step).rounded()))..<min(n, Int((s.end / step).rounded())) { g[k][f] = true }
            }
            return g
        }
        let ref = grid(reference, refNames), hyp = grid(hypothesis, hypNames)
        var scored = [Bool](repeating: true, count: n)
        if collar > 0 {
            for s in reference {
                for b in [s.start, s.end] {
                    for f in max(0, Int(((b - collar) / step).rounded()))..<min(n, Int(((b + collar) / step).rounded())) { scored[f] = false }
                }
            }
        }
        // Overlap between each hypothesis and reference speaker, then the best one-to-one map.
        var overlap = [[Int]](repeating: [Int](repeating: 0, count: refNames.count), count: hypNames.count)
        for h in hypNames.indices {
            for r in refNames.indices {
                for f in 0..<n where scored[f] && hyp[h][f] && ref[r][f] { overlap[h][r] += 1 }
            }
        }
        var best: (map: [Int?], total: Int) = ([Int?](repeating: nil, count: hypNames.count), -1)
        func search(_ h: Int, _ used: Set<Int>, _ map: [Int?], _ total: Int) {
            if h == hypNames.count {
                if total > best.total { best = (map, total) }
                return
            }
            search(h + 1, used, map, total)
            for r in refNames.indices where !used.contains(r) {
                var m = map
                m[h] = r
                search(h + 1, used.union([r]), m, total + overlap[h][r])
            }
        }
        search(0, [], best.map, 0)
        var missed = 0, fa = 0, confusion = 0, total = 0
        for f in 0..<n where scored[f] {
            let r = refNames.indices.filter { ref[$0][f] }, h = hypNames.indices.filter { hyp[$0][f] }
            total += r.count
            missed += max(0, r.count - h.count)
            fa += max(0, h.count - r.count)
            let correct = h.filter { best.map[$0].map(r.contains) ?? false }.count
            confusion += min(r.count, h.count) - correct
        }
        let t = Double(max(1, total))
        return Result(der: Double(missed + fa + confusion) / t, missed: Double(missed) / t, falseAlarm: Double(fa) / t,
                      confusion: Double(confusion) / t, referenceSeconds: Double(total) * step)
    }
}

extension DiarizationError: KeyedFailure {}
