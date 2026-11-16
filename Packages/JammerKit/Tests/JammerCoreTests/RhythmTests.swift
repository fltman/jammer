import Foundation
import Testing
@testable import JammerCore

@Suite("Tempo: the judgement of a beat tracker's answer")
struct RhythmTests {
    func grid(_ bpm: Double, from start: Double = 0, count: Int, wobble: Double = 0) -> [Double] {
        (0..<count).map { start + Double($0) * 60 / bpm + (wobble == 0 ? 0 : wobble * 60 / bpm * sin(Double($0) * 2.4)) }
    }
    func reading(_ bpm: Double, from start: Double = 0, count: Int = 40, wobble: Double = 0) -> Rhythm.Reading {
        Rhythm.Reading(bpm: bpm, beats: grid(bpm, from: start, count: count, wobble: wobble))
    }

    @Test("A regular grid that both halves agree on is a tempo; the tempo and the first beat come from a line through the beats")
    func steady() throws {
        let e = try #require(Rhythm.judge(whole: reading(93, from: 0.25), first: reading(93.02, count: 20), second: reading(92.97, count: 20), peak: 0.5, pulse: { _ in 0.6 }))
        #expect(e.bpm == 93 && e.firstBeat == 0.25 && e.pulse == 0.6 && e.alternatives == [46.5, 186] && e.beats.count == 40)
        // The first beat is the first on the line at or after the start, wherever the tracker began counting.
        let late = try #require(Rhythm.judge(whole: reading(120, from: 1.013), first: reading(120, count: 20), second: reading(120, count: 20), peak: 0.5, pulse: { _ in 0.6 }))
        #expect(late.firstBeat == 0.013 && late.bpm == 120)
        // Beats from 0 whose fitted line starts a hair before 0: the first beat is 0, not one beat later.
        let jitter = Rhythm.Reading(bpm: 87, beats: grid(87, count: 40).enumerated().map { $1 + ($0 % 2 == 0 ? -0.0004 : 0.0003) })
        #expect(Rhythm.judge(whole: jitter, first: reading(87), second: reading(87), peak: 0.5, pulse: { _ in 0.6 })?.firstBeat == 0)
        #expect(Rhythm.first(-0.0002, every: 0.5) == 0 && Rhythm.first(0.69, every: 0.345) == 0 && Rhythm.first(1.013, every: 0.5) == 0.013 && Rhythm.first(-0.1, every: 0.5) == 0.4)
        // Alternatives stay inside what a tempo map takes.
        let fast = try #require(Rhythm.judge(whole: reading(600), first: reading(600), second: reading(600), peak: 0.5, pulse: { _ in 0.6 }))
        #expect(fast.alternatives == [300])
    }

    @Test("What isn't one tempo is refused: beats off the grid, halves that disagree, too few beats, silence")
    func refused() {
        let ok = reading(100)
        #expect(Rhythm.judge(whole: ok, first: ok, second: ok, peak: 0.5, pulse: { _ in 0.6 }) != nil)
        // The sound doesn't repeat at that beat (speech and noise: 0.08 and under), whatever the tracker says.
        #expect(Rhythm.judge(whole: ok, first: ok, second: ok, peak: 0.5, pulse: { _ in 0.1 }) == nil)
        #expect(Rhythm.judge(whole: ok, first: ok, second: ok, peak: 0.5, pulse: { _ in Rhythm.minPulse })?.pulse == Rhythm.minPulse)
        // Beats a few percent off the grid are how the tracker often answers for a click track: not a reason to refuse.
        #expect(Rhythm.judge(whole: reading(100, wobble: 0.03), first: ok, second: ok, peak: 0.5, pulse: { _ in 0.6 }).map { abs($0.bpm - 100) < 0.1 } == true)
        // The halves: 1.5 % apart, or both 1.5 % from the whole (a tempo that changes, or no tempo).
        #expect(Rhythm.judge(whole: ok, first: reading(100.8), second: reading(99.3), peak: 0.5, pulse: { _ in 0.6 }) == nil)
        #expect(Rhythm.judge(whole: ok, first: reading(101.5), second: reading(101.5), peak: 0.5, pulse: { _ in 0.6 }) == nil)
        #expect(Rhythm.judge(whole: ok, first: Rhythm.Reading(bpm: nil, beats: []), second: ok, peak: 0.5, pulse: { _ in 0.6 }) == nil)
        #expect(Rhythm.judge(whole: reading(100, count: 7), first: ok, second: ok, peak: 0.5, pulse: { _ in 0.6 }) == nil)
        // Silence, for which the tracker also has a tempo.
        #expect(Rhythm.judge(whole: ok, first: ok, second: ok, peak: 0, pulse: { _ in 0.6 }) == nil && Rhythm.judge(whole: ok, first: ok, second: ok, peak: 0.0002, pulse: { _ in 0.6 }) == nil)
    }

    @Test("The pulse of a sound: clicks repeat at their beat and at no other, noise and silence at none")
    func pulse() {
        let sr = 48_000.0
        var clicks = [Float](repeating: 0, count: Int(20 * sr))
        for k in 0..<40 { for i in 0..<480 { clicks[k * 24_000 + i] = Float(exp(-Double(i) / 100) * sin(Double(i) * 0.2)) } }
        #expect(Rhythm.pulse(clicks, sampleRate: sr, period: 0.5) > 0.7)
        // Counted at half speed, the sound still repeats at half the beat that was given.
        #expect(Rhythm.pulse(clicks, sampleRate: sr, period: 1.0) > 0.7)
        // At a beat that isn't the sound's, nothing.
        #expect(Rhythm.pulse(clicks, sampleRate: sr, period: 0.37) < 0.05 && Rhythm.pulse(clicks, sampleRate: sr, period: 0.71) < 0.05)
        let hiss = noise(count: Int(20 * sr)).map { $0 * 0.2 }
        #expect(Rhythm.pulse(hiss, sampleRate: sr, period: 0.5) < 0.08 && Rhythm.pulse(hiss, sampleRate: sr, period: 0.72) < 0.08)
        #expect(Rhythm.pulse([Float](repeating: 0, count: Int(20 * sr)), sampleRate: sr, period: 0.5) == 0)
        #expect(Rhythm.pulse(clicks, sampleRate: sr, period: 0) == 0 && Rhythm.pulse([], sampleRate: sr, period: 0.5) == 0)
    }

    @Test("The tempo map puts the grid's beats on the found beats, from the first one on", arguments: [(120.0, 0.013), (93.0, 0.25), (140.0, 0.0), (72.0, 0.8), (87.0, 0.6897), (120.05, 2.2)])
    func map(bpm: Double, first: Double) throws {
        let sr = 48_000.0
        let map = try Rhythm.tempoMap(bpm: bpm, firstBeat: first, sampleRate: sr)
        #expect(map.changes.count <= 2 && map.changes.last?.bpm == bpm)
        let period = 60 / bpm
        var t = first.truncatingRemainder(dividingBy: period)
        if map.changes.count == 2 { t = Double(map.changes[1].position) / sr }
        // Every found beat from there on is the start of a beat on the ruler, to within a frame.
        for k in 0..<40 {
            let frame = Frame(((t + Double(k) * period) * sr).rounded())
            let near = [frame - 1, frame, frame + 1].map { map.position(at: max(0, $0), sampleRate: sr).tick }
            #expect(near.contains { $0 <= 1 } || near.contains { $0 >= TempoMap.ticksPerBeat - 2 }, "beat \(k) at \(frame): ticks \(near)")
        }
        // And the found beats are among them: the grid passes through `first` (or a whole number of beats from it).
        let offset = (t - first) / period
        #expect(abs(offset - offset.rounded()) < 0.001)
    }
}
