import Foundation
import Testing
@testable import JammerCore

/// The arithmetic is checked against EBU Tech 3341's own case: a 1 kHz stereo sine at −23 dBFS is −23.0 LUFS.
/// Where the speech is can't be checked here; that is what the reference measurements are for.
@Suite("Dialogue-gated loudness")
struct DialogueLoudnessTests {
    static func tone(seconds: Double, dbfs: Double, sr: Double = 48_000) -> [Float] {
        let a = Float(pow(10, dbfs / 20)), n = Int(sr * seconds)
        var out = [Float](repeating: 0, count: n * 2)
        for i in 0..<n {
            let v = a * Float(sin(2 * Double.pi * 1_000 * Double(i) / sr))
            out[2 * i] = v; out[2 * i + 1] = v
        }
        return out
    }
    static func energies(_ x: [Float]) -> [Double] {
        var m = LoudnessMeter(sampleRate: 48_000, channels: 2)
        m.process(x)
        return m.blockEnergies
    }

    @Test("Only the speech counts: 10 s of a −23 dBFS tone marked as speech among 20 s at −10 dBFS measures −23.0, with a third of the time speech; the ordinary measurement of the same is far louder")
    func onlyTheSpeech() {
        let x = Self.tone(seconds: 10, dbfs: -10) + Self.tone(seconds: 10, dbfs: -23) + Self.tone(seconds: 10, dbfs: -10)
        let e = Self.energies(x)
        #expect(e.count == 300)
        let g = DialogueLoudness.gated(energies: e, block: 4_800, speech: [Frame(480_000)..<Frame(960_000)])
        #expect(g.speechBlocks == 100 && abs((g.dialogue ?? 0) + 23) < 0.1, "\(g.dialogue ?? 0)")
        var m = LoudnessMeter(sampleRate: 48_000, channels: 2)
        m.process(x)
        #expect((m.result.integrated ?? -99) > -12)
        // Everything speech: the same as the tone's own loudness.
        let all = DialogueLoudness.gated(energies: Self.energies(Self.tone(seconds: 5, dbfs: -23)), block: 4_800, speech: [0..<Frame(240_000)])
        #expect(abs((all.dialogue ?? 0) + 23) < 0.1 && all.speechBlocks == 50)
    }

    @Test("A block is speech when half of it is; silence marked as speech counts as time but not as level; no speech gives no number")
    func edges() {
        // Silence first (after a tone the meter's filters ring on for a while, and that is level, not silence).
        let e = Self.energies([Float](repeating: 0, count: 96_000) + Self.tone(seconds: 1, dbfs: -23))
        // 2 400 of 4 800 frames is half: block 0 counts; one frame less doesn't.
        #expect(DialogueLoudness.gated(energies: e, block: 4_800, speech: [0..<2_400]).speechBlocks == 1)
        #expect(DialogueLoudness.gated(energies: e, block: 4_800, speech: [0..<2_399]).speechBlocks == 0)
        // Two ranges that each cover a quarter of the same block make its half together.
        #expect(DialogueLoudness.gated(energies: e, block: 4_800, speech: [0..<1_200, 2_400..<3_600]).speechBlocks == 1)
        // Speech over the silence and the tone after it: 20 blocks of time, the level the tone's alone.
        let g = DialogueLoudness.gated(energies: e, block: 4_800, speech: [0..<96_000])
        #expect(g.speechBlocks == 20 && abs((g.dialogue ?? 0) + 23) < 0.15, "\(g.dialogue ?? 0) \(g.speechBlocks)")
        let none = DialogueLoudness.gated(energies: e, block: 4_800, speech: [])
        #expect(none.dialogue == nil && none.speechBlocks == 0)
        let silent = DialogueLoudness.gated(energies: e, block: 4_800, speech: [0..<Frame(48_000)])
        #expect(silent.dialogue == nil && silent.speechBlocks == 10)
    }

    @Test("Where the speech is: the turns of who speaks when on the tracks that are heard; without turns the transcript's words, joined when less than 0.3 s apart; without either, none")
    func ranges() {
        var (p, _) = MixerTests.document()
        #expect(p.speechRanges().source == .none && p.speechRanges().ranges.isEmpty)
        let source = p.tracks[0].clips[0].sourceID
        p.transcripts = [SourceTranscript(sourceID: source, language: "en", engine: "test", words: [
            Word(text: "one", start: 4_800, end: 9_600), Word(text: "two", start: 12_000, end: 19_200), Word(text: "three", start: 38_400, end: 43_200)])]
        let w = p.speechRanges()
        #expect(w.source == .words && w.ranges == [4_800..<19_200, 38_400..<43_200], "\(w.ranges)")
        p.speakerTurns = [SourceSpeakers(sourceID: source, engine: "test", turns: [SpeakerTurn(speaker: 0, start: 0, end: 24_000), SpeakerTurn(speaker: 1, start: 20_000, end: 30_000)])]
        let t = p.speechRanges()
        #expect(t.source == .speakers && t.ranges == [0..<30_000], "\(t.ranges)")
        #expect(p.speechRanges(in: 10_000..<25_000).ranges == [10_000..<25_000])
        p.tracks[0].isMuted = true
        #expect(p.speechRanges().source == .none)
    }

    @Test("A profile goes by the dialogue when there is enough of it and by the whole programme when there isn't; every profile says where and when it was read, and one not read at its source says so")
    func profiles() {
        let programme = LoudnessResult(integrated: -20, range: 8, maxMomentary: -12, maxShortTerm: -15, samplePeak: -4, truePeak: -3.2, duration: 100)
        let talky = DialogueLoudness(dialogue: -26.2, speechShare: 0.5, speechSeconds: 50, programme: programme, source: .speakers)
        let n = DialogueProfile.netflix.reading(talky)
        #expect(n.basis == .dialogue && n.target == -27 && abs((n.fromTarget ?? 0) - 0.8) < 1e-9 && n.truePeakCeiling == -2)
        // 10 % speech: Netflix (15 %) goes by the programme at −24, ATSC (8 %) still by the dialogue at −24.
        var sparse = talky; sparse.speechShare = 0.10
        let byProgramme = DialogueProfile.netflix.reading(sparse)
        #expect(byProgramme.basis == .programme && byProgramme.target == -24 && byProgramme.measured == -20 && byProgramme.fromTarget == 4)
        #expect(DialogueProfile.atscA85.reading(sparse).basis == .dialogue && DialogueProfile.atscA85.reading(sparse).target == -24)
        // No speech at all: the programme, whatever the share says.
        let none = DialogueLoudness(dialogue: nil, speechShare: 0, speechSeconds: 0, programme: programme, source: .none)
        #expect(DialogueProfile.atscA85.reading(none).basis == .programme)
        for p in DialogueProfile.allCases {
            let s = p.spec
            #expect(s.source.contains("http") && s.read.count == 10 && s.tolerance > 0 && s.minimumSpeechShare > 0 && s.truePeakCeiling < 0, "\(p.rawValue)")
            #expect((p.json(talky)["note"] as? String)?.contains("No verdict") == true)
        }
        #expect(DialogueProfile.atscA85.spec.readAtSource && !DialogueProfile.netflix.spec.readAtSource)
    }
}
