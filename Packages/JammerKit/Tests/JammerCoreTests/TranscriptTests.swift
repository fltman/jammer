import Foundation
import Testing
@testable import JammerCore

@Suite("Transcript")
struct TranscriptTests {
    /// Ten seconds of distinct samples with one word per second ("w0" … "w9"),
    /// each lasting 0.5 s from the start of its second.
    private func project() -> (Project, SourcePool, [Word]) {
        let signal = (0..<(480_000 * 2)).map { Float(($0 * 13) % 65_536 - 32_768) / 32_768 }
        var (p, pool) = memoryProject(signal)
        let words = (0..<10).map { Word(text: "w\($0)", start: Frame($0) * 48_000, end: Frame($0) * 48_000 + 24_000, confidence: 0.9) }
        p.setTranscript(SourceTranscript(sourceID: p.sources[0].id, language: "sv-SE", engine: "test", words: words))
        return (p, pool, words)
    }

    private func rendered(_ p: Project, _ pool: SourcePool) -> [Float] {
        let plan = PlanCompiler.compile(p, pool: pool)
        return plan.render(from: 0, frames: Int(plan.length))
    }

    @Test("Untouched, the transcript reads the words at their source times")
    func untouched() {
        let (p, _, words) = project()
        let placed = p.placedWords()
        #expect(placed.map(\.word.text) == words.map(\.text))
        #expect(placed.map(\.start) == words.map(\.start))
        #expect(p.transcriptText() == "w0 w1 w2 w3 w4 w5 w6 w7 w8 w9")
        #expect(p.transcriptText(in: 96_000..<200_000) == "w2 w3 w4")
    }

    @Test("Deleting words is a ripple delete of exactly their audio")
    func deleteWords() throws {
        var (p, pool, words) = project()
        let before = rendered(p, pool)
        try p.deleteWords([words[3].id])
        #expect(p.transcriptText() == "w0 w1 w2 w4 w5 w6 w7 w8 w9")
        #expect(p.length == 480_000 - 24_000)
        // Same as deleting the range by hand, bit for bit.
        var (byHand, handPool, _) = project()
        try byHand.delete(144_000..<168_000)
        #expect(rendered(p, pool) == rendered(byHand, handPool))
        #expect(Array(rendered(p, pool)[0..<(144_000 * 2)]) == Array(before[0..<(144_000 * 2)]))
        // Words after the cut moved left with the audio.
        let w4Start: Frame? = p.placedWords().first { $0.word.text == "w4" }?.start
        let expected: Frame = 4 * 48_000 - 24_000
        #expect(w4Start == expected)
    }

    @Test("A run of words goes with the pauses between them; separate words stay separate")
    func runs() throws {
        let (p, _, words) = project()
        // w2 and w3 are 0.5 s apart: merged only when the bridge covers the pause.
        #expect(p.ranges(ofWords: [words[2].id, words[3].id]).count == 2)
        #expect(p.ranges(ofWords: [words[2].id, words[3].id], bridge: 24_000) == [96_000..<168_000])
        var q = p
        try q.deleteWords([words[2].id, words[3].id], bridge: 24_000)
        #expect(q.transcriptText() == "w0 w1 w4 w5 w6 w7 w8 w9")
        #expect(q.length == 480_000 - 72_000)
        #expect(throws: TranscriptError.noWords) { try q.deleteWords([words[2].id]) }
    }

    @Test("Edits made on the waveform show up in the transcript; undo brings words back")
    func waveformEdits() throws {
        var (p, _, _) = project()
        let undo = p
        // Cut through the middle of w5 (frames 240 000..<264 000).
        try p.delete(252_000..<300_000)
        let placed = p.placedWords()
        let w5 = try #require(placed.first { $0.word.text == "w5" })
        #expect(w5.isPartial)
        #expect(w5.range == 240_000..<252_000)
        // Silence removes words from what plays without moving the rest.
        try p.silence(0..<48_000)
        #expect(p.placedWords().first?.word.text == "w1")
        p = undo
        #expect(p.transcriptText() == "w0 w1 w2 w3 w4 w5 w6 w7 w8 w9")
    }

    @Test("Copy and paste carries the words; pasting twice shows them twice")
    func copyPaste() throws {
        var (p, _, words) = project()
        let clip = try p.copy(48_000..<96_000)
        #expect(clip.transcripts?.first?.words.count == 10)
        try p.paste(clip, at: 0)
        #expect(p.transcriptText().hasPrefix("w1 w0 w1 w2"))
        // Into a project that has no transcript yet.
        var other = Project(sampleRate: 48_000, channels: 2)
        try other.paste(clip, at: 0)
        #expect(other.transcriptText() == "w1")
        #expect(other.placedWords().first?.word.id == words[1].id)
    }

    @Test("Correcting a word changes the text only; transcripts survive saving")
    func correctAndSave() throws {
        var (p, pool, words) = project()
        let audio = rendered(p, pool)
        try p.correctWord(words[0].id, to: "Hej")
        #expect(p.transcriptText().hasPrefix("Hej w1"))
        #expect(rendered(p, pool) == audio)
        #expect(throws: TranscriptError.unknownWord) { try p.correctWord(UUID(), to: "x") }
        let back = try ProjectPackage.decode(ProjectPackage.encode(p))
        #expect(back == p)
        // Projects saved before transcripts existed still open.
        var json = try JSONSerialization.jsonObject(with: ProjectPackage.encode(p)) as! [String: Any]
        json.removeValue(forKey: "transcripts")
        #expect(try ProjectPackage.decode(JSONSerialization.data(withJSONObject: json)).transcripts.isEmpty)
    }

    @Test("Muted tracks and pruned sources drop out of the transcript")
    func mutedAndPruned() throws {
        var (p, _, _) = project()
        p.tracks[0].isMuted = true
        #expect(p.placedWords().isEmpty)
        p.tracks[0].isMuted = false
        try p.delete(0..<p.length)
        p.pruneSources()
        #expect(p.transcripts.isEmpty)
    }
}
