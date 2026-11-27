import Foundation

/// Tempo and beats of music. The beat tracking itself is the system's (MusicUnderstanding, which the
/// app plugs in as `analyser`); what is here is the judgement of its answer. The system's analysis
/// gives a tempo for anything, speech, noise and silence included, so an answer is only passed on
/// when the sound behaves like music with one tempo (docs/TEMPO.md has the measurements):
/// the sound itself repeats at the beat it was given (`pulse`, measured here, not by the tracker),
/// the first and the second half of the stretch agree with each other and with the whole, and
/// there is sound at all. The tracker's own beats can't be the test: on the same file it answers
/// with an exact grid one time and with beats a few percent off it the next.
public enum Rhythm {
    /// What the analyser found in one file: beat times in seconds from its start, and its tempo.
    public struct Reading: Sendable, Equatable {
        public var bpm: Double?
        public var beats: [Double]
        public init(bpm: Double?, beats: [Double]) {
            self.bpm = bpm
            self.beats = beats
        }
    }

    public struct Estimate: Sendable, Equatable {
        /// Beats per minute, from a line fitted through the beat times.
        public var bpm: Double
        /// Seconds (from the start of what was analysed) of the first beat on that line.
        public var firstBeat: Double
        /// The beat times the analyser gave.
        public var beats: [Double]
        /// How strongly the sound repeats at the beat (or at half of it): 0 for noise, towards 1 for a
        /// click track. Never under `minPulse` here.
        public var pulse: Double
        /// Half and double the tempo, for when the analyser counted every other beat or twice as many.
        public var alternatives: [Double]
        /// The stretches of one tempo each, when the tempo changes (a tempo map); one stretch when it doesn't.
        public var stretches: [Stretch] = []
    }

    /// A stretch of one tempo: from its first beat (seconds from the start of what was analysed) to the next
    /// stretch's first beat, at `bpm`, chosen so a whole number of its beats lies between the two.
    public struct Stretch: Sendable, Equatable {
        public var start: Double
        public var bpm: Double
        public var beats: Int
        public var pulse: Double
        /// One beat that joins two stretches where the beat at the change has neither tempo's length: not a tempo of its own.
        public var bridge = false
        public init(start: Double, bpm: Double, beats: Int, pulse: Double = 0, bridge: Bool = false) {
            self.start = start; self.bpm = bpm; self.beats = beats; self.pulse = pulse; self.bridge = bridge
        }
    }

    /// What the sound says about the tempo's changes.
    public enum Segmentation: Sendable, Equatable {
        /// Steps between steady stretches (or one stretch: no change).
        case stretches([Stretch])
        /// The tempo moves gradually, from about `from` to about `to` BPM between `start` and `end` (seconds).
        case glide(from: Double, to: Double, start: Double, end: Double)
        /// No steady stretches the sound keeps to.
        case none
    }

    /// Analyses a file (blocking; background threads only). nil when it can't. The app sets it.
    nonisolated(unsafe) public static var analyser: (@Sendable (_ file: URL) -> Reading?)?

    /// The least the sound has to repeat at the beat (music: 0.35 and up; speech, noise: 0.08 and under).
    public static let minPulse = 0.18
    /// How far the halves' tempi may be from the whole's and from each other (music: under 0.3 %; speech,
    /// where its halves happen to agree at all: 0.7 % and up, and it has no pulse).
    public static let maxDisagreement = 0.01
    /// Peak level in dBFS under which there is nothing to analyse.
    public static let silence = -70.0
    /// The analysis looks at this much, from the start of the range.
    public static let maxSeconds = 120.0
    public static let minSeconds = 8.0
    /// For a tempo map, this much is analysed (a tempo that is steady over the first `maxSeconds` is one tempo, as
    /// before: only music that changes there is looked at further).
    public static let maxMapSeconds = 600.0
    /// A change of tempo is a move of more than this share, held for `minStretchBeats` beats and `minStretchSeconds`.
    public static let changeShare = 0.03
    public static let minStretchBeats = 8
    public static let minStretchSeconds = 4.0

    /// The first of the times `t`, `t ± period`, … that isn't before 0, to the millisecond. A time a hair
    /// before 0 (a line fitted through beats that start at 0) is 0, not one beat later.
    static func first(_ t: Double, every period: Double) -> Double {
        var x = t.truncatingRemainder(dividingBy: period)
        if x < 0 { x += period }
        if period - x < 0.0005 { x = 0 }
        return (x * 1_000).rounded() / 1_000
    }

    /// How much later than its value's step an onset is: a rise shows in the first 20 ms window that reaches it,
    /// which starts 15 ms before the window's last step.
    static let onsetLag = 0.015

    /// The onsets of `mono`: the rise in level between 5 ms steps (20 ms windows), one value per step.
    static func onsets(_ mono: [Float], sampleRate: Double) -> (step: Double, values: [Double]) {
        let hop = max(1, Int(sampleRate * 0.005)), win = max(hop, Int(sampleRate * 0.02))
        guard mono.count > win + hop else { return (Double(hop) / sampleRate, []) }
        var level: [Double] = []
        var i = 0
        while i + win <= mono.count {
            var e = 0.0
            for k in i..<(i + win) { e += Double(mono[k]) * Double(mono[k]) }
            level.append(max(-80, 10 * log10(e / Double(win) + 1e-12)))
            i += hop
        }
        var onset = [Double](repeating: 0, count: level.count)
        for j in 1..<level.count { onset[j] = max(0, level[j] - level[j - 1]) }
        return (Double(hop) / sampleRate, onset)
    }

    /// How much of the sound's onsets between `start` and `end` (seconds) lie on a grid of `period` from `start`, or
    /// on its half beats, within 25 ms: towards 1 when the beat is the sound's, about a third for a grid the sound
    /// doesn't keep (the tracker locked on another tempo). Onsets under a tenth of the strongest are not counted.
    public static func onGrid(_ onsets: (step: Double, values: [Double]), start: Double, end: Double, period: Double) -> Double {
        let v = onsets.values, step = onsets.step
        let a = max(0, Int(start / step)), b = min(v.count, Int(end / step))
        guard b > a, period > 0.05 else { return 0 }
        let floor = (v[a..<b].max() ?? 0) / 10
        var on = 0.0, all = 0.0
        let half = period / 2
        for j in a..<b where v[j] > floor {
            let t = Double(j) * step - start
            let off = t - (t / half).rounded() * half
            all += v[j]
            if abs(off) <= 0.025 { on += v[j] }
        }
        return all > 0 ? on / all : 0
    }
    /// The least share of onsets on a stretch's grid for it to be the sound's beat.
    public static let minOnGrid = 0.5

    /// How strongly `mono` repeats every `period` seconds: the autocorrelation of its onsets (the rise
    /// in level between 5 ms steps, 20 ms windows) at that lag or at half of it, whichever is larger,
    /// as a share of the onsets' own energy. The same sound always gives the same number.
    public static func pulse(_ mono: [Float], sampleRate: Double, period: Double) -> Double {
        let hop = max(1, Int(sampleRate * 0.005)), win = max(hop, Int(sampleRate * 0.02))
        guard period > 0.05, mono.count > win + hop * 100 else { return 0 }
        var level: [Double] = []
        level.reserveCapacity(mono.count / hop)
        var i = 0
        while i + win <= mono.count {
            var e = 0.0
            for k in i..<(i + win) { e += Double(mono[k]) * Double(mono[k]) }
            level.append(max(-80, 10 * log10(e / Double(win) + 1e-12)))
            i += hop
        }
        var onset = [Double](repeating: 0, count: level.count)
        for j in 1..<level.count { onset[j] = max(0, level[j] - level[j - 1]) }
        let mean = onset.reduce(0, +) / Double(onset.count)
        for j in onset.indices { onset[j] -= mean }
        let energy = onset.reduce(0) { $0 + $1 * $1 }
        guard energy > 1e-9 else { return 0 }
        func r(_ lag: Int) -> Double {
            guard lag > 0, lag < onset.count else { return 0 }
            var sum = 0.0
            for j in 0..<(onset.count - lag) { sum += onset[j] * onset[j + lag] }
            return sum / energy
        }
        func near(_ seconds: Double) -> Double {
            let c = Int((seconds * sampleRate / Double(hop)).rounded())
            return (-2...2).map { r(c + $0) }.max() ?? 0
        }
        return max(0, near(period), near(period / 2))
    }

    /// The tempo, when the three readings (the whole stretch, its first half, its second half) say
    /// there is one. `peak` is the largest sample of the stretch; `pulse` says how strongly the sound
    /// repeats every so many seconds (`Rhythm.pulse` on the stretch).
    public static func judge(whole: Reading, first: Reading, second: Reading, peak: Float, pulse: (_ period: Double) -> Double) -> Estimate? {
        guard peak > 0, 20 * log10(Double(peak)) > silence else { return nil }
        guard let given = whole.bpm, given > 0, let a = first.bpm, let b = second.bpm, a > 0, b > 0, whole.beats.count >= 8 else { return nil }
        guard abs(a - given) / given <= maxDisagreement, abs(b - given) / given <= maxDisagreement, abs(a - b) / given <= maxDisagreement else { return nil }
        // A line through the beats: its slope is the beat's length, its start the first beat.
        let n = Double(whole.beats.count)
        let mx = (n - 1) / 2, my = whole.beats.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0
        for (i, t) in whole.beats.enumerated() { sxy += (Double(i) - mx) * (t - my); sxx += (Double(i) - mx) * (Double(i) - mx) }
        let period = sxy / sxx
        guard period > 0, TempoMap.bpmRange.contains(60 / period) else { return nil }
        let bpm = (60 / period * 100).rounded() / 100
        let strength = pulse(period)
        guard strength >= minPulse else { return nil }
        // The first beat on the line that isn't before the start.
        let start = Self.first(my - period * mx, every: period)
        return Estimate(bpm: bpm, firstBeat: start, beats: whole.beats, pulse: (min(1, strength) * 100).rounded() / 100,
                        alternatives: [bpm / 2, bpm * 2].filter(TempoMap.bpmRange.contains).map { ($0 * 100).rounded() / 100 })
    }

    /// Where beats of a known length fall, given beat times found at about that length (or twice it):
    /// the first such beat at or after 0, or nil when the times don't keep to it (more than a tenth of
    /// a beat out, on average).
    public static func phase(of beats: [Double], period: Double) -> Double? {
        guard beats.count >= 4, period > 0, let t0 = beats.first else { return nil }
        let offsets = beats.map { t -> Double in (t - t0) - ((t - t0) / period).rounded() * period }
        let mean = offsets.reduce(0, +) / Double(offsets.count)
        let spread = (offsets.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(offsets.count)).squareRoot()
        guard spread <= period / 10 else { return nil }
        var first = (t0 + mean).truncatingRemainder(dividingBy: period)
        if first < 0 { first += period }
        return first
    }

    static func median(_ x: ArraySlice<Double>) -> Double {
        let s = x.sorted()
        return s.isEmpty ? 0 : s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    // MARK: Tempo changes from the sound itself

    /// The stretches of the sound's own beat (Jämmer's measure, not the system tracker's: the tracker keeps one tempo
    /// through a reading and locks wrong around a change). The tempo of every 6 s, a second apart, from the onsets'
    /// autocorrelation (the shortest lag nearly as strong as the strongest, so a bar's accent doesn't win); runs of
    /// one tempo are stretches; each stretch's beats are the onset peaks on its grid, its tempo and phase a line
    /// through them; a change is the first peak on the new grid after the last on the old one. A run at twice another
    /// run's beat is that beat with an accent every other one; windows whose beat moves one way through levels between
    /// two are a glide.
    public static func ownStretches(_ mono: [Float], sampleRate sr: Double) -> Segmentation {
        let found = onsets(mono, sampleRate: sr)
        let v = found.values, step = found.step
        guard v.count > Int(12 / step) else { return .none }
        let window = Int(6 / step), hop = Int(1 / step)
        let minLag = Int(0.25 / step), maxLag = Int(1.5 / step)
        // The tempo of each window, as seconds per beat (nil: no pulse there).
        var periods: [Double?] = []
        // The tempo is read from the onsets smoothed over ±20 ms: a played beat is some ms early or late, and a 5 ms
        // onset correlates with the next one only when they fall on the same step. (Where the beats are is read from
        // the onsets as they are.)
        let smooth = v.indices.map { j in (-4...4).reduce(0.0) { $0 + Double(5 - abs($1)) * v[min(v.count - 1, max(0, j + $1))] } / 25 }
        var at = 0
        while at + window <= v.count {
            let w = smooth[at..<(at + window)]
            let mean = w.reduce(0, +) / Double(window)
            let x = w.map { $0 - mean }
            let energy = x.reduce(0) { $0 + $1 * $1 }
            var r = [Double](repeating: 0, count: maxLag + 2)
            if energy > 1e-9 {
                for lag in (minLag - 1)...(maxLag + 1) where lag < x.count {
                    var sum = 0.0
                    for j in 0..<(x.count - lag) { sum += x[j] * x[j + lag] }
                    r[lag] = sum / energy
                }
            }
            let best = (minLag...maxLag).max { r[$0] < r[$1] } ?? minLag
            if r[best] < minPulse { periods.append(nil) } else {
                let lag = (minLag...maxLag).first { r[$0] >= 0.8 * r[best] && r[$0] >= r[$0 - 1] && r[$0] >= r[$0 + 1] } ?? best
                // Between steps: the peak of a parabola through the three around it.
                let a = r[lag - 1], b = r[lag], c = r[lag + 1]
                let shift = (a - 2 * b + c) != 0 ? 0.5 * (a - c) / (a - 2 * b + c) : 0
                periods.append((Double(lag) + max(-0.5, min(0.5, shift))) * step)
            }
            at += hop
        }
        // Runs of windows at one tempo (within the change share of the run's median); a window across a change, or
        // without a pulse, belongs to none.
        var runs: [(first: Int, last: Int, period: Double)] = []
        var i = 0
        while i < periods.count {
            guard let p = periods[i] else { i += 1; continue }
            var j = i
            var members = [p]
            while j + 1 < periods.count, let q = periods[j + 1], abs(q / median(ArraySlice(members)) - 1) <= changeShare / 2 { j += 1; members.append(q) }
            if j - i + 1 >= 3 { runs.append((i, j, median(ArraySlice(members)))) }
            i = j + 1
        }
        // A run at twice the period of another run is the same beat with an accent every other one (a kick and a
        // snare): it takes the shorter beat. (A tempo that really halves reads as the same beat counted on.)
        let read = runs.map(\.period)
        for k in runs.indices {
            if let b = read.first(where: { abs(read[k] / ($0 * 2) - 1) <= changeShare }) { runs[k].period = b }
        }
        guard !runs.isEmpty else { return .none }
        // A glide: windows one after the other, each with a pulse, whose beat moves one way (back by no more than
        // 0.3 %), over 6 % in all, with at least three windows between the levels at its ends (more than half the
        // change share from both). A step has none between: a window reads the old beat or the new. A window at twice
        // a run's beat is read as that beat first, as the runs are.
        let beat = periods.map { p in p.map { p in read.contains { abs(p / ($0 * 2) - 1) <= changeShare } ? p / 2 : p } }
        var g = 0
        while g < beat.count {
            guard beat[g] != nil else { g += 1; continue }
            var e = g, sign = 0.0
            while e + 1 < beat.count, let a = beat[e], let b = beat[e + 1] {
                let move = b / a - 1
                if abs(move) > 0.003 {
                    if sign == 0 { sign = move > 0 ? 1 : -1 } else if move * sign < 0 { break }
                }
                e += 1
            }
            let lo = beat[g]!, hi = beat[e]!
            let between = (g...e).filter { abs(beat[$0]! / lo - 1) > changeShare / 2 && abs(beat[$0]! / hi - 1) > changeShare / 2 }
            if abs(hi / lo - 1) > 2 * changeShare, between.count >= 3 {
                return .glide(from: (60 / lo).rounded(), to: (60 / hi).rounded(), start: Double(between.first!) * Double(hop) * step,
                              end: Double(between.last!) * Double(hop) * step + 6)
            }
            g = e > g ? e : g + 1
        }
        // Merge neighbours at the same tempo (a pulse-less window between them).
        var merged: [(first: Int, last: Int, period: Double)] = []
        for r in runs {
            if let l = merged.last, abs(r.period / l.period - 1) <= changeShare { merged[merged.count - 1] = (l.first, r.last, (l.period + r.period) / 2) } else { merged.append(r) }
        }
        // The onset peaks: local highs over ±40 ms above a tenth of the strongest.
        let floor = (v.max() ?? 0) / 10, around = Int(0.04 / step)
        var peaks: [Double] = []
        for j in v.indices where v[j] > floor {
            let lo = max(0, j - around), hi = min(v.count - 1, j + around)
            if v[j] == v[lo...hi].max(), peaks.last.map({ Double(j) * step + onsetLag - $0 > 0.05 }) ?? true { peaks.append(Double(j) * step + onsetLag) }
        }
        // Each stretch's grid: the peaks in its windows that keep to its period, and a line through them.
        func grid(_ from: Double, _ to: Double, _ period: Double) -> (t0: Double, period: Double)? {
            let ps = peaks.filter { $0 >= from && $0 < to }
            guard ps.count >= minStretchBeats else { return nil }
            // The phase most peaks agree with.
            var bestPhase = 0.0, bestCount = 0
            for p in ps {
                let n = ps.filter { abs(($0 - p) / period - (($0 - p) / period).rounded()) * period <= 0.025 }.count
                if n > bestCount { bestCount = n; bestPhase = p }
            }
            let on = ps.filter { abs(($0 - bestPhase) / period - (($0 - bestPhase) / period).rounded()) * period <= 0.025 }
            guard on.count >= minStretchBeats else { return nil }
            let idx = on.map { (($0 - bestPhase) / period).rounded() }
            let n = Double(on.count), mx = idx.reduce(0, +) / n, my = on.reduce(0, +) / n
            var sxy = 0.0, sxx = 0.0
            for (x, y) in zip(idx, on) { sxy += (x - mx) * (y - my); sxx += (x - mx) * (x - mx) }
            guard sxx > 0 else { return nil }
            let slope = sxy / sxx
            // The time of index 0 (near the agreed phase) and the beat's length.
            return slope > 0 ? (my - slope * mx, slope) : nil
        }
        func fits(_ t: Double, _ g: (t0: Double, period: Double)) -> Bool {
            abs((t - g.t0) / g.period - ((t - g.t0) / g.period).rounded()) * g.period <= 0.025
        }
        let windowStart = { (w: Int) in Double(w) * Double(hop) * step }
        var grids: [(t0: Double, period: Double)] = []
        for r in merged {
            guard let g = grid(windowStart(r.first), windowStart(r.last) + 6, r.period) else { return .none }
            grids.append(g)
        }
        // The beats of each stretch, and where each change is.
        var out: [Stretch] = []
        var first = peaks.first { fits($0, grids[0]) && $0 >= windowStart(merged[0].first) - 1 } ?? grids[0].t0
        for k in grids.indices {
            let g = grids[k]
            if k + 1 == grids.count {
                let last = peaks.last { fits($0, g) } ?? first
                let beats = Int(((last - first) / g.period).rounded()) + 1
                out.append(Stretch(start: (first * 1_000).rounded() / 1_000, bpm: (60 / g.period * 100).rounded() / 100, beats: beats))
                break
            }
            let next = grids[k + 1]
            let middle = (windowStart(merged[k].last) + 6 + windowStart(merged[k + 1].first)) / 2
            // The last peak on this grid before the next stretch's run, and the first on the next grid after it.
            guard let lastOld = peaks.last(where: { fits($0, g) && $0 < middle + 3 && !(fits($0, next) && $0 > middle) }),
                  let firstNew = peaks.first(where: { $0 > lastOld + 0.05 && fits($0, next) }) else { return .none }
            let m = ((lastOld - first) / g.period).rounded()
            guard m >= Double(minStretchBeats - 1) else { return .none }
            // The beat between the last on the old grid and the first on the new: the old tempo's (the old stretch
            // ends a beat later), the new tempo's (the last old beat is the new stretch's first, as when a beat lies
            // on both grids), or neither (a bridge of one beat).
            let gap = firstNew - lastOld
            if abs(gap / g.period - 1) <= changeShare {
                out.append(Stretch(start: (first * 1_000).rounded() / 1_000, bpm: (60 * (m + 1) / (firstNew - first) * 100).rounded() / 100, beats: Int(m) + 1))
            } else if abs(gap / next.period - 1) <= changeShare {
                out.append(Stretch(start: (first * 1_000).rounded() / 1_000, bpm: (60 * m / (lastOld - first) * 100).rounded() / 100, beats: Int(m)))
                first = lastOld
                continue
            } else {
                out.append(Stretch(start: (first * 1_000).rounded() / 1_000, bpm: (60 * m / (lastOld - first) * 100).rounded() / 100, beats: Int(m)))
                out.append(Stretch(start: (lastOld * 1_000).rounded() / 1_000, bpm: (60 / (firstNew - lastOld) * 100).rounded() / 100, beats: 1, bridge: true))
            }
            first = firstNew
        }
        guard out.allSatisfy({ TempoMap.bpmRange.contains($0.bpm) }) else { return .none }
        return .stretches(out)
    }

    /// A tempo map with a tempo per stretch, each starting on its first beat (seconds on the timeline: `offset` plus
    /// the stretch's start); before the first, one beat as `tempoMap(bpm:firstBeat:)` makes it.
    public static func tempoMap(_ stretches: [Stretch], offset: Double, sampleRate: Double, meter: Meter = .common) throws -> TempoMap {
        guard let first = stretches.first else { throw Failure.noSteadyTempo }
        var map = try tempoMap(bpm: first.bpm, firstBeat: offset + first.start, sampleRate: sampleRate, meter: meter)
        var changes = map.changes
        for s in stretches.dropFirst() {
            changes.append(TempoChange(position: Frame(((offset + s.start) * sampleRate).rounded()), bpm: s.bpm, meter: meter))
        }
        map = try TempoMap(changes: changes)
        return map
    }

    public enum Failure: Error, LocalizedError, Equatable {
        /// A tempo to two decimals at most: the API writes 120.5, the window as the Mac's region does.
        static func bpm(_ v: Double) -> SaidValue { Said.n((v * 100).rounded() / 100) }
        case unavailable, tooShort, noSteadyTempo, doesNotFit(found: Double)
        /// The tempo moves gradually (seconds on the timeline): a map of steps would only roughly follow it.
        case glides(from: Double, to: Double, start: Double, end: Double)
        /// m:ss, or h:mm:ss.
        static func clock(_ t: Double) -> String {
            let s = Int(t.rounded())
            return s >= 3_600 ? String(format: "%d:%02d:%02d", s / 3_600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
        }
        public var reason: String {
            switch self {
            case .unavailable: "not_available"
            case .tooShort, .noSteadyTempo: "no_steady_tempo"
            case .doesNotFit: "tempo_mismatch"
            case .glides: "tempo_glides"
            }
        }
        public var errorDescription: String? {
            switch self {
            case .unavailable: "tempo detection isn't available in this build."
            case .tooShort: "tempo detection needs at least \(Int(minSeconds)) seconds of sound."
            case .doesNotFit(let found): "the beat found in the sound is \(Self.bpm(found).english) BPM, which doesn't fit the tempo given (nor half or double it)."
            case .noSteadyTempo: "no steady tempo was found (speech, noise, silence, or music whose tempo neither stays nor changes in clear steps). If you know the tempo, give bpm."
            case .glides(let a, let b, let s, let e): "the tempo glides from about \(Int(a)) to \(Int(b)) BPM between \(Self.clock(s)) and \(Self.clock(e)); set it by hand."
            }
        }
        /// The same message by its key in the app's string catalogue (see `KeyedMessage`).
        public var keyed: KeyedMessage? {
            switch self {
            case .unavailable: KeyedMessage("error.rhythm.unavailable")
            case .tooShort: KeyedMessage("error.rhythm.tooShort", ["\(Int(minSeconds))"])
            case .doesNotFit(let found): KeyedMessage("error.rhythm.doesNotFit", values: [Self.bpm(found)])
            case .noSteadyTempo: KeyedMessage("error.rhythm.noSteadyTempo")
            case .glides(let a, let b, let s, let e): KeyedMessage("error.rhythm.glides", ["\(Int(a))", "\(Int(b))", Self.clock(s), Self.clock(e)])
            }
        }
    }

    /// The tempo of `range` of the mix (of `tracks` alone when given): rendered to temporary files, read
    /// by the analyser as a whole and in halves, and judged. Looks at up to `maxSeconds` from the start.
    /// `multiply` (0.5 or 2) is for a tracker that counted at twice or half the speed. `bpm` is for a
    /// tempo that is known: it has to fit what was found (within 2 %, or half or double it), and only
    /// where the beats fall is then taken from the sound.
    public static func estimate(_ project: Project, range: Range<Frame>, tracks: Set<UUID>? = nil, pool: SourcePool,
                                multiply: Double = 1, bpm known: Double? = nil) throws -> Estimate {
        guard let analyser else { throw Failure.unavailable }
        let frames = min(range.count, Int(project.sampleRate * maxSeconds))
        guard Double(frames) >= project.sampleRate * minSeconds else { throw Failure.tooShort }
        var p = project
        if let tracks {
            p.tracks = p.tracks.filter { tracks.contains($0.id) }
            for i in p.tracks.indices { p.tracks[i].isMuted = false }
        }
        for i in p.tracks.indices { p.tracks[i].inserts = [] }
        let audio = PlanCompiler.compile(p, pool: pool).render(from: range.lowerBound, frames: frames)
        let peak = audio.reduce(Float(0)) { max($0, abs($1)) }
        let dir = FileManager.default.temporaryDirectory.appending(path: "jammer-tempo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ch = project.channels, half = frames / 2
        func read(_ name: String, _ part: Range<Int>) throws -> Reading? {
            let url = dir.appending(path: name)
            let w = try WAVWriter(url: url, options: .init(encoding: .int24, channels: ch, sampleRate: project.sampleRate))
            try w.write(Array(audio[(part.lowerBound * ch)..<(part.upperBound * ch)]))
            try w.finish()
            return analyser(url)
        }
        guard peak > 0, let whole = try read("whole.wav", 0..<frames), let first = try read("first.wav", 0..<half), let second = try read("second.wav", half..<frames)
        else { throw Failure.noSteadyTempo }
        func mono(_ a: [Float]) -> [Float] { stride(from: 0, to: a.count, by: ch).map { i in (0..<ch).reduce(Float(0)) { $0 + a[i + $1] } / Float(ch) } }
        guard var e = judge(whole: whole, first: first, second: second, peak: peak, pulse: { period in
            Self.pulse(mono(audio), sampleRate: project.sampleRate, period: period)
        }) else {
            // Not one tempo. A tempo the caller knows is one tempo; otherwise, does it change in steps?
            guard known == nil, 20 * log10(Double(peak)) > silence else { throw Failure.noSteadyTempo }
            // Not even a pulse at the tracker's usual beat (speech, noise): no tempo, and nothing more is read. The usual
            // spacing, not the average: with tempi mixed, an average beat matches none of them.
            let spacing = zip(whole.beats.dropFirst(), whole.beats).map { $0 - $1 }.filter { $0 > 0.05 }
            let steady = spacing.count >= 8 && pulse(mono(audio), sampleRate: project.sampleRate, period: median(ArraySlice(spacing))) >= minPulse
            // The sound itself, up to `maxMapSeconds` (the tracker keeps one tempo through a reading and locks wrong
            // around a change, so the stretches are Jämmer's own). A glide has no usual beat to pulse at, so without
            // one only a glide is looked for: runs of windows each with its own pulse, each moving on from the last.
            let n = min(range.count, Int(project.sampleRate * maxMapSeconds))
            let long = n > frames ? PlanCompiler.compile(p, pool: pool).render(from: range.lowerBound, frames: n) : audio
            return try map(project, range: range, audio: long, multiply: multiply, glideOnly: !steady)
        }
        e.stretches = [Stretch(start: e.firstBeat, bpm: e.bpm, beats: e.beats.count, pulse: e.pulse)]
        if let known {
            guard [0.5, 1, 2].contains(where: { abs(e.bpm * $0 - known) / known <= 0.02 }), let first = phase(of: e.beats, period: 60 / known) else {
                throw Failure.doesNotFit(found: e.bpm)
            }
            e.bpm = known
            e.firstBeat = Self.first(first, every: 60 / known)
        } else if multiply != 1 {
            let bpm = (e.bpm * multiply * 100).rounded() / 100
            guard TempoMap.bpmRange.contains(bpm) else { throw Failure.noSteadyTempo }
            e.bpm = bpm
            e.firstBeat = Self.first(e.firstBeat, every: 60 / bpm)
        }
        e.alternatives = [e.bpm / 2, e.bpm * 2].filter(TempoMap.bpmRange.contains).map { ($0 * 100).rounded() / 100 }
        e.stretches = [Stretch(start: e.firstBeat, bpm: e.bpm, beats: e.beats.count, pulse: e.pulse)]
        return e
    }

    /// The tempo map of music whose tempo changes in steps: the stretches of the sound's own beat (`ownStretches`),
    /// every one checked against the sound, its pulse at its beat and its onsets on its grid. A glide is refused with
    /// what was seen; one stretch that fails refuses the whole map. `glideOnly`: the tracker found no usual beat with a
    /// pulse, so only a glide is taken (anything else is no tempo, as for speech).
    static func map(_ project: Project, range: Range<Frame>, audio: [Float], multiply: Double, glideOnly: Bool = false) throws -> Estimate {
        let sr = project.sampleRate, ch = project.channels
        let offset = project.seconds(range.lowerBound)
        let mono = stride(from: 0, to: audio.count, by: ch).map { i in (0..<ch).reduce(Float(0)) { $0 + audio[i + $1] } / Float(ch) }
        let seg = ownStretches(mono, sampleRate: sr)
        switch seg {
        case .glide(let a, let b, let s, let e):
            throw Failure.glides(from: a, to: b, start: offset + s, end: offset + e)
        case .stretches(var s) where !s.isEmpty && !glideOnly:
            let found = onsets(mono, sampleRate: sr)
            for k in s.indices where !s[k].bridge {
                let end = k + 1 < s.count ? s[k + 1].start : Double(mono.count) / sr
                let from = max(0, Int(s[k].start * sr)), to = min(mono.count, Int(end * sr))
                guard to - from > Int(sr * minStretchSeconds / 2) else { throw Failure.noSteadyTempo }
                let strength = pulse(Array(mono[from..<to]), sampleRate: sr, period: 60 / s[k].bpm)
                let grid = onGrid(found, start: s[k].start - onsetLag, end: end - onsetLag, period: 60 / s[k].bpm)
                guard strength >= minPulse, grid >= minOnGrid else { throw Failure.noSteadyTempo }
                s[k].pulse = (min(1, strength) * 100).rounded() / 100
            }
            if multiply != 1 {
                // Half the tempo keeps the grid only where every stretch but the last has an even number of beats.
                if multiply < 1, s.dropLast().contains(where: { $0.beats % 2 == 1 }) { throw Failure.noSteadyTempo }
                for k in s.indices {
                    s[k].bpm = (s[k].bpm * multiply * 100).rounded() / 100
                    guard TempoMap.bpmRange.contains(s[k].bpm) else { throw Failure.noSteadyTempo }
                }
            }
            let beats = s.flatMap { st in (0..<st.beats).map { st.start + Double($0) * 60 / st.bpm } }
            // One stretch is one tempo (the tracker's halves disagreed, the sound's own beat didn't).
            let alternatives = s.count == 1 ? [s[0].bpm / 2, s[0].bpm * 2].filter(TempoMap.bpmRange.contains).map { ($0 * 100).rounded() / 100 } : []
            return Estimate(bpm: s[0].bpm, firstBeat: Self.first(s[0].start, every: 60 / s[0].bpm), beats: beats, pulse: s.filter { !$0.bridge }.map(\.pulse).min() ?? 0,
                            alternatives: alternatives, stretches: s)
        default:
            throw Failure.noSteadyTempo
        }
    }

    /// A tempo map with one tempo whose beats fall on `firstBeat` (seconds on the timeline) and every
    /// beat after it. The timeline before the first beat is one beat long, at whatever tempo makes it
    /// so; bars are counted from there, which says nothing about where the music's bars begin.
    public static func tempoMap(bpm: Double, firstBeat: Double, sampleRate: Double, meter: Meter = .common) throws -> TempoMap {
        let period = 60 / bpm
        var lead = firstBeat.truncatingRemainder(dividingBy: period)
        if lead < 0 { lead += period }
        let leadFrames = Frame((lead * sampleRate).rounded())
        guard leadFrames > 0 else { return try TempoMap(changes: [TempoChange(position: 0, bpm: bpm, meter: meter)]) }
        // One beat before the first: its tempo has to be one the map takes (10 to 999), so a very short lead gets a beat more.
        var leadSeconds = Double(leadFrames) / sampleRate
        var position = leadFrames
        if 60 / leadSeconds > TempoMap.bpmRange.upperBound {
            leadSeconds += period
            position = Frame((leadSeconds * sampleRate).rounded())
        }
        return try TempoMap(changes: [TempoChange(position: 0, bpm: 60 / leadSeconds, meter: meter), TempoChange(position: position, bpm: bpm, meter: meter)])
    }
}

extension Rhythm.Failure: KeyedFailure {}
