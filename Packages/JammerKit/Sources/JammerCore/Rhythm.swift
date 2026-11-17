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

    /// The first of the times `t`, `t ± period`, … that isn't before 0, to the millisecond. A time a hair
    /// before 0 (a line fitted through beats that start at 0) is 0, not one beat later.
    static func first(_ t: Double, every period: Double) -> Double {
        var x = t.truncatingRemainder(dividingBy: period)
        if x < 0 { x += period }
        if period - x < 0.0005 { x = 0 }
        return (x * 1_000).rounded() / 1_000
    }

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

    public enum Failure: Error, LocalizedError, Equatable {
        /// A tempo to two decimals at most: the API writes 120.5, the window as the Mac's region does.
        static func bpm(_ v: Double) -> SaidValue { Said.n((v * 100).rounded() / 100) }
        case unavailable, tooShort, noSteadyTempo, doesNotFit(found: Double)
        public var reason: String {
            switch self {
            case .unavailable: "not_available"
            case .tooShort, .noSteadyTempo: "no_steady_tempo"
            case .doesNotFit: "tempo_mismatch"
            }
        }
        public var errorDescription: String? {
            switch self {
            case .unavailable: "tempo detection isn't available in this build."
            case .tooShort: "tempo detection needs at least \(Int(minSeconds)) seconds of sound."
            case .doesNotFit(let found): "the beat found in the sound is \(Self.bpm(found).english) BPM, which doesn't fit the tempo given (nor half or double it)."
            case .noSteadyTempo: "no steady tempo was found (speech, noise, silence, or music whose tempo changes). If you know the tempo, give bpm."
            }
        }
        /// The same message by its key in the app's string catalogue (see `KeyedMessage`).
        public var keyed: KeyedMessage? {
            switch self {
            case .unavailable: KeyedMessage("error.rhythm.unavailable")
            case .tooShort: KeyedMessage("error.rhythm.tooShort", ["\(Int(minSeconds))"])
            case .doesNotFit(let found): KeyedMessage("error.rhythm.doesNotFit", values: [Self.bpm(found)])
            case .noSteadyTempo: KeyedMessage("error.rhythm.noSteadyTempo")
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
        guard peak > 0, let whole = try read("whole.wav", 0..<frames), let first = try read("first.wav", 0..<half), let second = try read("second.wav", half..<frames),
              var e = judge(whole: whole, first: first, second: second, peak: peak, pulse: { period in
                  let mono = stride(from: 0, to: audio.count, by: ch).map { i in (0..<ch).reduce(Float(0)) { $0 + audio[i + $1] } / Float(ch) }
                  return Self.pulse(mono, sampleRate: project.sampleRate, period: period)
              }) else { throw Failure.noSteadyTempo }
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
        return e
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
