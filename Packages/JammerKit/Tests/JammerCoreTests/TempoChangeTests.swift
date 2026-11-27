import Foundation
import Testing
@testable import JammerCore

/// Tempo that changes (a tempo map from the sound's own beat; 2026-11-27): steps are followed, a glide is refused
/// with what was seen, and a steady tempo never grows a change. On made-up clicks and drums; RhythmReferenceTests
/// runs the whole estimate, the system's tracker included, on sound.
@Suite("Tempo changes: stretches of the sound's own beat")
struct TempoChangeTests {
    let sr = 24_000.0

    /// Clicks (the first of four higher) or a kick on every beat with a snare on every other, at `times`.
    func sound(at times: [Double], seconds: Double, drums: Bool = false) -> [Float] {
        let n = Int(seconds * sr)
        var x = [Float](repeating: 0, count: n)
        var seed: UInt64 = 3
        for (k, t0) in times.enumerated() {
            let s = Int(t0 * sr)
            for i in 0..<Int(0.06 * sr) where s + i < n {
                let t = Double(i) / sr
                var v: Double
                if drums {
                    v = exp(-t / 0.03) * sin(2 * .pi * (60 + 80 * exp(-t / 0.01)) * t) * 0.8
                    if k % 2 == 1 {
                        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                        v += exp(-t / 0.008) * Double(Int32(truncatingIfNeeded: seed >> 32)) / 2_147_483_648 * 0.4
                    }
                } else {
                    v = exp(-t / 0.008) * sin(2 * .pi * (k % 4 == 0 ? 1_500 : 1_000) * t) * (k % 4 == 0 ? 0.8 : 0.5)
                }
                x[s + i] += Float(v)
            }
        }
        return x
    }

    /// Beat times of steps, each (bpm, seconds) after the one before, from `start`; and where each step begins.
    /// `gap`: the beat between the steps, when it has a length of its own.
    func steps(_ parts: [(Double, Double)], start: Double = 0.2, gap: Double? = nil) -> (times: [Double], starts: [Double]) {
        var times: [Double] = [], starts: [Double] = [], t = start
        for (k, (bpm, length)) in parts.enumerated() {
            if k > 0, let gap { t = times.last! + gap }
            starts.append(t)
            let end = t + length
            while t < end - 1e-9 { times.append(t); t += 60 / bpm }
        }
        return (times, starts)
    }

    func stretches(_ x: [Float]) -> [Rhythm.Stretch]? {
        if case .stretches(let s) = Rhythm.ownStretches(x, sampleRate: sr) { return s }
        return nil
    }

    @Test("Steps of tempo: each stretch found, its tempo within half a BPM, each change within 30 ms of where it is",
          arguments: [([(120.0, 16.0), (90.0, 16.0), (140.0, 16.0)], false), ([(100.0, 20.0), (128.0, 20.0)], true),
                      ([(72.0, 12.0), (96.0, 12.0), (72.0, 12.0)], false)])
    func stepsFound(parts: [(Double, Double)], drums: Bool) throws {
        let (times, starts) = steps(parts)
        let x = sound(at: times, seconds: parts.reduce(1.2) { $0 + $1.1 }, drums: drums)
        let s = try #require(stretches(x), "\(Rhythm.ownStretches(x, sampleRate: sr))")
        #expect(s.count == parts.count && !s.contains(where: \.bridge), "\(s)")
        for (k, part) in parts.enumerated() where k < s.count {
            #expect(abs(s[k].bpm - part.0) <= 0.5, "\(part.0): \(s[k].bpm)")
            #expect(abs(s[k].start - starts[k]) <= 0.03, "stretch \(k) at \(s[k].start), not \(starts[k])")
        }
        // A whole number of beats between changes, so the bar count stays whole across them.
        let map = try Rhythm.tempoMap(s, offset: 0, sampleRate: sr)
        for st in s.dropFirst() {
            let q = map.quarterNotes(at: Frame((st.start * sr).rounded()), sampleRate: sr) - map.quarterNotes(at: Frame((s[0].start * sr).rounded()), sampleRate: sr)
            #expect(abs(q - q.rounded()) < 0.01, "a change at \(q) quarter notes from the first beat")
        }
    }

    @Test("A beat between two stretches with a length of its own is a bridge: one beat, and every click stays on the map's grid")
    func bridge() throws {
        let (times, starts) = steps([(120, 16), (90, 16)], gap: 0.8)
        let x = sound(at: times, seconds: times.last! + 1.2)
        let s = try #require(stretches(x), "\(Rhythm.ownStretches(x, sampleRate: sr))")
        #expect(s.count == 3 && s[1].bridge && s[1].beats == 1 && !s[0].bridge && !s[2].bridge, "\(s)")
        if s.count == 3 {
            #expect(abs(s[0].bpm - 120) <= 0.5 && abs(s[2].bpm - 90) <= 0.5, "\(s)")
            #expect(abs(s[2].start - starts[1]) <= 0.03, "\(s[2].start), not \(starts[1])")
        }
        let map = try Rhythm.tempoMap(s, offset: 0, sampleRate: sr)
        for t in times where t >= s[0].start {
            let f = Frame((t * sr).rounded())
            let q = map.quarterNotes(at: f, sampleRate: sr)
            #expect(abs(q - q.rounded()) * 60 / map.bpm(at: f) <= 0.02, "the click at \(t) is off the grid")
        }
    }

    @Test("A steady tempo never grows a change, played a little unevenly (to 8 ms), clicks or kick and snare")
    func steady() {
        for (bpm, drums) in [(72.0, false), (93, false), (120, false), (140, false), (174, false), (100, true), (128, true)] {
            let period = 60 / bpm
            let times = (0..<Int(40 / period)).map { 0.25 + Double($0) * period + 0.008 * sin(Double($0) * 2.4) }
            guard let s = stretches(sound(at: times, seconds: 41.5, drums: drums)) else { Issue.record("\(bpm) \(drums ? "drums" : "clicks"): no stretch"); continue }
            #expect(s.count == 1 && abs(s[0].bpm - bpm) <= 0.2, "\(bpm) \(drums ? "drums" : "clicks"): \(s)")
        }
    }

    @Test("A glide (140 to 100 over 30 s) is refused with what was seen: about where it went, and between when")
    func glide() {
        var times: [Double] = []
        var t = 0.2
        while t < 10 { times.append(t); t += 60 / 140.0 }
        let from = t
        while t < from + 30 { times.append(t); t += 60 / (140 - 40 * (t - from) / 30) }
        let to = t
        while t < to + 12 { times.append(t); t += 60 / 100.0 }
        let seg = Rhythm.ownStretches(sound(at: times, seconds: t + 1), sampleRate: sr)
        guard case .glide(let a, let b, let start, let end) = seg else { Issue.record("\(seg)"); return }
        #expect(abs(a - 140) <= 8 && abs(b - 100) <= 8, "\(a) to \(b)")
        #expect(abs(start - from) <= 5 && abs(end - to) <= 5, "\(start)–\(end), not \(from)–\(to)")
        let failure = Rhythm.Failure.glides(from: a, to: b, start: 70 + start, end: 70 + end)
        #expect(failure.reason == "tempo_glides" && failure.keyed?.key == "error.rhythm.glides")
        #expect(Rhythm.Failure.clock(70) == "1:10" && Rhythm.Failure.clock(3_725) == "1:02:05")
    }

    @Test("Clicks that keep to no grid, silence and too little sound are no stretches")
    func noGrid() {
        var seed: UInt64 = 7
        var t = 0.0
        let random = (0..<80).map { _ -> Double in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            t += 0.3 + Double(seed >> 40) / Double(1 << 24) * 0.6
            return t
        }
        #expect(stretches(sound(at: random, seconds: t + 1)) == nil)
        #expect(Rhythm.ownStretches([Float](repeating: 0, count: Int(30 * sr)), sampleRate: sr) == .none)
        #expect(Rhythm.ownStretches(sound(at: steps([(120, 10)]).times, seconds: 10.5), sampleRate: sr) == .none)
    }
}
