import Foundation
import Testing
@testable import JammerCore

@Suite("Tempo map")
struct TempoMapTests {
    let sr = 48_000.0

    @Test("Constant 120 BPM in 4/4: a beat is 24 000 frames, a bar 96 000")
    func constant() throws {
        let m = TempoMap()
        #expect(m.quarterNotes(at: 24_000, sampleRate: sr) == 1)
        #expect(m.frame(atQuarterNotes: 4, sampleRate: sr) == 96_000)
        #expect(m.position(at: 0, sampleRate: sr) == MusicalPosition(bar: 1, beat: 1, tick: 0))
        #expect(m.position(at: 96_000, sampleRate: sr) == MusicalPosition(bar: 2))
        #expect(m.position(at: 96_000 + 36_000, sampleRate: sr) == MusicalPosition(bar: 2, beat: 2, tick: 480))
        #expect(m.position(at: 95_999, sampleRate: sr) == MusicalPosition(bar: 1, beat: 4, tick: 959))
        #expect(try m.frame(at: MusicalPosition(bar: 3, beat: 3), sampleRate: sr) == 2 * 96_000 + 48_000)
        #expect(MusicalPosition(bar: 12, beat: 3, tick: 7).description == "12.3.007")
    }

    @Test("A tempo change keeps the bar running")
    func tempoChange() throws {
        var m = TempoMap()
        // Bar 3 starts at 192 000; from there 60 BPM, so a beat is 48 000 frames.
        try m.set(bpm: 60, at: 192_000)
        #expect(m.bpm(at: 191_999) == 120)
        #expect(m.bpm(at: 192_000) == 60)
        #expect(m.quarterNotes(at: 192_000 + 48_000, sampleRate: sr) == 9)
        #expect(m.position(at: 192_000 + 48_000, sampleRate: sr) == MusicalPosition(bar: 3, beat: 2))
        #expect(try m.frame(at: MusicalPosition(bar: 4), sampleRate: sr) == 192_000 + 4 * 48_000)
        // Mid-bar change: bar 1 beat 3 onwards at 240 BPM.
        var n = TempoMap()
        try n.set(bpm: 240, at: 48_000)
        #expect(n.position(at: 48_000 + 12_000, sampleRate: sr) == MusicalPosition(bar: 1, beat: 4))
        #expect(try n.frame(at: MusicalPosition(bar: 2), sampleRate: sr) == 72_000)
    }

    @Test("A new time signature starts a new bar, even after an unfinished one")
    func meterChange() throws {
        var m = TempoMap()
        // 3/4 from bar 2 (on the bar line).
        try m.set(bpm: 120, meter: Meter(3, 4), at: 96_000)
        #expect(m.position(at: 96_000 + 72_000, sampleRate: sr) == MusicalPosition(bar: 3))
        #expect(try m.frame(at: MusicalPosition(bar: 4), sampleRate: sr) == 96_000 + 2 * 72_000)
        #expect(throws: TempoError.badPosition) { try m.frame(at: MusicalPosition(bar: 2, beat: 4), sampleRate: sr) }

        // 6/8 from beat 3 of bar 1: bar 1 stays unfinished, 6/8 starts bar 2 there.
        var n = TempoMap()
        try n.set(bpm: 120, meter: Meter(6, 8), at: 48_000)
        #expect(n.position(at: 48_000, sampleRate: sr) == MusicalPosition(bar: 2))
        // An eighth at 120 quarter-BPM is 12 000 frames.
        #expect(n.position(at: 48_000 + 12_000, sampleRate: sr) == MusicalPosition(bar: 2, beat: 2))
        #expect(try n.frame(at: MusicalPosition(bar: 3), sampleRate: sr) == 48_000 + 72_000)
        #expect(throws: TempoError.badPosition) { try n.frame(at: MusicalPosition(bar: 1, beat: 3), sampleRate: sr) }
        #expect(try n.frame(at: MusicalPosition(bar: 1, beat: 2), sampleRate: sr) == 24_000)
        #expect(n.barStarts(in: 0..<200_000, sampleRate: sr).map(\.frame) == [0, 48_000, 120_000, 192_000])
    }

    @Test("Frames survive the round trip through quarter notes, over three hours")
    func roundTrip() throws {
        var m = TempoMap(bpm: 97.3)
        try m.set(bpm: 141.7, meter: Meter(7, 8), at: 1_234_567)
        try m.set(bpm: 63.25, at: 200_000_001)
        let three = Frame(3 * 3_600 * 48_000)
        for f in stride(from: Frame(0), through: three, by: 7_777_777) + [1_234_566, 1_234_567, 200_000_001, three] {
            #expect(m.frame(atQuarterNotes: m.quarterNotes(at: f, sampleRate: sr), sampleRate: sr) == f)
            let p = m.position(at: f, sampleRate: sr)
            let back = try m.frame(at: p, sampleRate: sr)
            #expect(back <= f && m.position(at: back, sampleRate: sr) == p)
        }
    }

    @Test("Invalid tempo and meter are refused; the first change can't be removed")
    func validation() {
        var m = TempoMap()
        #expect(throws: TempoError.badTempo) { try m.set(bpm: 0) }
        #expect(throws: TempoError.badTempo) { try m.set(bpm: .nan) }
        #expect(throws: TempoError.badMeter) { try m.set(bpm: 100, meter: Meter(4, 3)) }
        #expect(throws: TempoError.noSuchChange) { try m.removeChange(at: 0) }
        #expect(throws: TempoError.noSuchChange) { try m.removeChange(at: 5) }
    }

    @Test("Redundant changes collapse; a change without a meter keeps the one in effect")
    func normalize() throws {
        var m = TempoMap()
        try m.set(bpm: 90, meter: Meter(3, 4), at: 10_000)
        try m.set(bpm: 120, at: 20_000)
        #expect(m.change(at: 20_000).meter == Meter(3, 4))
        try m.set(bpm: 120, meter: .common, at: 10_000)
        #expect(m.changes.count == 2)
        try m.removeChange(at: 20_000)
        #expect(m.isConstant)
    }

    @Test("Ripple delete moves changes with the audio and keeps the tempo after the cut")
    func rippleDelete() throws {
        var m = TempoMap()
        try m.set(bpm: 90, at: 100_000)
        try m.set(bpm: 60, at: 200_000)
        try m.set(bpm: 150, at: 300_000)
        m.delete(150_000..<250_000)
        #expect(m.changes.map(\.position) == [0, 100_000, 150_000, 200_000])
        #expect(m.changes.map(\.bpm) == [120, 90, 60, 150])
        // Deleting over everything but the start leaves the last tempo at the cut.
        var n = m
        n.delete(50_000..<1_000_000)
        #expect(n.changes.map(\.bpm) == [120, 150])
        #expect(n.changes.map(\.position) == [0, 50_000])
        // A gap pushes later changes right; one exactly at the gap goes with the audio.
        m.insertGap(at: 100_000, length: 1_000)
        #expect(m.changes.map(\.position) == [0, 101_000, 151_000, 201_000])
    }

    @Test("Project edits carry the tempo map, and old projects open at 120 in 4/4")
    func project() throws {
        let signal = [Float](repeating: 0.25, count: 2 * 480_000)
        var (p, _) = memoryProject(signal)
        try p.tempo.set(bpm: 100, meter: Meter(3, 4), at: 240_000)
        try p.delete(0..<48_000)
        #expect(p.tempo.changes.map(\.position) == [0, 192_000])
        try p.silence(0..<10_000)
        #expect(p.tempo.changes.map(\.position) == [0, 192_000])
        let decoded = try ProjectPackage.decode(ProjectPackage.encode(p))
        #expect(decoded == p)
        #expect(decoded.musicalPosition(at: 192_000) == MusicalPosition(bar: 3))

        var json = try JSONSerialization.jsonObject(with: ProjectPackage.encode(p)) as! [String: Any]
        json.removeValue(forKey: "tempo")
        let old = try ProjectPackage.decode(JSONSerialization.data(withJSONObject: json))
        #expect(old.tempo == TempoMap())

        json["tempo"] = ["changes": [["position": 0, "bpm": 0, "meter": ["beats": 4, "unit": 4]]]]
        #expect(throws: DecodingError.self) { try ProjectPackage.decode(JSONSerialization.data(withJSONObject: json)) }
    }
}
