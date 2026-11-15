import Foundation
import Testing
@testable import JammerCore

@Suite("Diarisation")
struct DiarizationTests {
    let sr = 48_000.0

    /// Speech-like bursts: noise with a 4 Hz syllable envelope, inside `turns` (seconds).
    private func talker(_ turns: [(Double, Double)], seconds: Double, seed: UInt64) -> [Float] {
        let n = Int(seconds * sr)
        let w = noise(count: n, seed: seed)
        var out = [Float](repeating: 0, count: n)
        for (a, b) in turns {
            for i in Int(a * sr)..<min(n, Int(b * sr)) {
                let t = Double(i) / sr
                out[i] = w[i] * Float(0.15 * (0.55 + 0.45 * sin(2 * .pi * 4 * t)))
            }
        }
        return out
    }

    /// A double-ender: each track has its talker plus the other's bleed at -20 dB and a quiet floor.
    private func doubleEnder(_ dir: TempDir) throws -> (Project, SourcePool, [DiarizationScore.Segment]) {
        let seconds = 30.0
        let aTurns = [(1.0, 6.0), (9.5, 12.0), (15.0, 15.8), (20.0, 26.0)]
        let bTurns = [(5.5, 9.0), (12.4, 14.6), (16.0, 16.7), (24.5, 28.0)] // overlaps at 5.5-6 and 24.5-26
        let a = talker(aTurns, seconds: seconds, seed: 1), b = talker(bTurns, seconds: seconds, seed: 2)
        let floor = noise(count: a.count, seed: 3).map { $0 * 0.0003 }
        var p: Project?
        for (name, own, other) in [("Anna", a, b), ("Bo", b, a)] {
            let mono = (0..<own.count).map { own[$0] + 0.1 * other[$0] + floor[$0] }
            let url = dir.file("\(name).wav")
            try writeWAV(mono.flatMap { [$0, $0] }, to: url)
            let ref = SourceRef(name: name, path: url.path, info: try AudioFileReader.info(at: url))
            if p == nil { p = Project(source: ref) } else { p!.addTrack(source: ref) }
        }
        let reference = aTurns.map { DiarizationScore.Segment("Anna", $0.0, $0.1) } + bTurns.map { DiarizationScore.Segment("Bo", $0.0, $0.1) }
        return (p!, SourcePool(), reference)
    }

    @Test("DER is 0 for a perfect answer and counts misses, false alarms and confusion")
    func score() {
        let ref = [DiarizationScore.Segment("A", 0, 10), .init("B", 10, 20)]
        #expect(DiarizationScore.score(reference: ref, hypothesis: [.init("x", 0, 10), .init("y", 10, 20)]).der < 1e-9)
        let swapped = DiarizationScore.score(reference: ref, hypothesis: [.init("x", 0, 20)])
        #expect(abs(swapped.confusion - 0.5) < 0.01 && swapped.missed < 0.01)
        let half = DiarizationScore.score(reference: ref, hypothesis: [.init("x", 0, 10)])
        #expect(abs(half.missed - 0.5) < 0.01)
    }

    @Test("By track: each track is its speaker, bleed doesn't count, overlaps do")
    func byTrack() throws {
        let dir = TempDir()
        let (p, pool, reference) = try doubleEnder(dir)
        #expect(p.hasOverlappingTracks)
        let r = Diarization.byTrack(p, pool: pool, tracks: p.tracks.map(\.id))
        let hyp = r.flatMap { d in d.turns.map { DiarizationScore.Segment(d.names[$0.speaker], p.seconds($0.range.lowerBound), p.seconds($0.range.upperBound)) } }
        let s = DiarizationScore.score(reference: reference, hypothesis: hyp)
        print(String(format: "DIAR by_track DER %.1f%% (miss %.1f, FA %.1f, conf %.1f)", s.der * 100, s.missed * 100, s.falseAlarm * 100, s.confusion * 100))
        #expect(s.der < 0.05, "DER \(s.der): missed \(s.missed), false alarm \(s.falseAlarm), confusion \(s.confusion)")
        #expect(r.map(\.names) == [["Anna"], ["Bo"]])
    }

    @Test("Turns survive edits, label words, and rename; re-diarising replaces them")
    func storage() throws {
        let dir = TempDir()
        var (p, pool, _) = try doubleEnder(dir)
        let src = p.tracks[0].clips[0].sourceID
        p.setTranscript(SourceTranscript(sourceID: src, language: "sv-SE", engine: "t",
                                         words: [Word(text: "hej", start: Frame(2 * sr), end: Frame(2.4 * sr)),
                                                 Word(text: "tyst", start: Frame(7.5 * sr), end: Frame(7.8 * sr))]))
        p.applyDiarization(Diarization.byTrack(p, pool: pool, tracks: p.tracks.map(\.id)), engine: "by-track")
        #expect(p.speakers == ["Anna", "Bo"])
        #expect(p.transcripts[0].words.map(\.speaker) == [0, nil])
        let before = p.placedTurns().filter { $0.track == 0 }.first!
        try p.delete(0..<Frame(sr / 2)) // ripple: everything moves 0.5 s earlier
        let after = p.placedTurns().filter { $0.track == 0 }.first!
        #expect(after.start == before.start - Frame(sr / 2))
        try p.renameSpeaker("Anna", to: "Anna Andersson")
        try p.renameSpeaker("1", to: "Bo Berg")
        #expect(p.speakers == ["Anna Andersson", "Bo Berg"])
        #expect(throws: SpeakerError.self) { try p.renameSpeaker("Cecilia", to: "x") }
        // Again on track 1 only: its old speaker goes, Anna stays first.
        p.applyDiarization([TrackDiarization(track: p.tracks[1].id, names: ["Speaker 2"], turns: [.init(speaker: 0, range: 0..<Frame(sr))])], engine: "x")
        #expect(p.speakers == ["Anna Andersson", "Speaker 2"])
        #expect(abs((p.speakerSeconds()[1] ?? 0) - 1) < 0.001)
        // Saved and opened again.
        let back = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p))
        #expect(back.speakerTurns == p.speakerTurns && back.speakers == p.speakers)
    }

    @Test("16 kHz for the model: a 1 kHz tone keeps its level and pitch; 8 kHz is filtered away")
    func resampling() throws {
        let dir = TempDir()
        let x = (0..<Int(sr * 2)).map { i -> Float in
            let t = Double(i) / sr
            return Float(0.5 * sin(2 * .pi * 1_000 * t) + 0.5 * sin(2 * .pi * 9_000 * t))
        }
        let url = dir.file("t.wav")
        try writeWAV(x.flatMap { [$0, $0] }, to: url)
        let p = Project(source: SourceRef(name: "t", path: url.path, info: try AudioFileReader.info(at: url)))
        let y = try Diarization.mono16k(p, track: 0, pool: SourcePool())
        #expect(y.count == 32_000)
        // Correlate the middle with a 1 kHz sine at 16 kHz: amplitude 0.5 survives, 9 kHz is gone.
        var c = 0.0, s = 0.0, e = 0.0
        for i in 8_000..<24_000 {
            let t = Double(i) / 16_000
            c += Double(y[i]) * cos(2 * .pi * 1_000 * t)
            s += Double(y[i]) * sin(2 * .pi * 1_000 * t)
            e += Double(y[i] * y[i])
        }
        let amp = 2 * (c * c + s * s).squareRoot() / 16_000
        #expect(abs(amp - 0.5) < 0.01, "1 kHz amplitude \(amp)")
        let rms = (e / 16_000).squareRoot()
        #expect(abs(rms - 0.5 / 2.0.squareRoot()) < 0.01, "only the 1 kHz tone is left: rms \(rms)")
    }
}
