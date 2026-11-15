import Foundation
import JammerCore
import Testing
@testable import JammerSpeech

@Suite("Word builder")
struct WordBuilderTests {
    @Test("Runs become words in source frames; punctuation joins the word before; blanks go")
    func build() {
        let runs = [
            RecognisedRun(text: " podden", start: 1.23, end: 1.86, confidence: 0.49),
            RecognisedRun(text: "Hej ", start: 0, end: 0.3, confidence: 0.4),
            RecognisedRun(text: ".", start: 1.98, end: 1.98, confidence: 0.49),
            RecognisedRun(text: "  ", start: 1.9, end: 1.95, confidence: nil),
            RecognisedRun(text: "Idag", start: 1.98, end: 2.49, confidence: 0.81),
            RecognisedRun(text: "sist", start: 9.9, end: 12, confidence: nil),
        ]
        let words = WordBuilder.words(from: runs, sampleRate: 48_000, sourceFrames: 480_000)
        #expect(words.map(\.text) == ["Hej", "podden.", "Idag", "sist"])
        #expect(words[1].start == 59_040 && words[1].end == 89_280)
        #expect(words[1].confidence == 0.49)
        // Clamped to the source.
        #expect(words[3].end == 480_000)
    }

    @Test("A leading punctuation mark with nothing before it is kept as a word")
    func leadingPunctuation() {
        let words = WordBuilder.words(from: [RecognisedRun(text: "–", start: 0, end: 0.1, confidence: nil)], sampleRate: 16_000, sourceFrames: 16_000)
        #expect(words.map(\.text) == ["–"])
    }
}

/// Real recognition of synthetic Swedish speech (macOS voice Alva). Needs Apple's
/// sv-SE dictation assets (downloaded on first use). `JAMMER_SPEECH_TESTS=1`.
@Suite("Apple speech", .enabled(if: ProcessInfo.processInfo.environment["JAMMER_SPEECH_TESTS"] != nil))
struct AppleSpeechTests {
    @Test("Swedish: words land where they're spoken, in any source format Jammer reads")
    func swedish() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "jammer-speech-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 44.1 kHz stereo-free AIFF on purpose: not what the recogniser wants.
        let url = dir.appending(path: "alva.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Alva", "-o", url.path, "--data-format=BEI16@44100",
                         "Hej och välkommen till podden. Idag pratar vi om hur man tar bort tystnader."]
        try say.run()
        say.waitUntilExit()
        let info = try AudioFileReader.info(at: url)
        let ref = SourceRef(name: "alva", path: url.path, info: info)
        let engine = AppleSpeechEngine()
        #expect(await engine.supports(Locale(identifier: "sv-SE")))
        let t = try await engine.transcribe(ref, pool: SourcePool(), locale: Locale(identifier: "sv-SE")) { _ in }
        let text = t.words.map(\.text).joined(separator: " ").lowercased()
        print("SPEECH  \(t.engine) \(t.language): \(text)")
        for w in ["välkommen", "podden", "pratar", "tystnader"] { #expect(text.contains(w), "missing \(w)") }
        #expect(t.engine == "apple-dictation")
        // Anchors in source frames, in order, inside the file.
        #expect(zip(t.words, t.words.dropFirst()).allSatisfy { $0.start <= $1.start })
        #expect(t.words.allSatisfy { $0.start >= 0 && $0.end <= info.frames && $0.start <= $0.end })
        // "välkommen" is near the start (about 0.35–1.05 s at Alva's default rate).
        let v = try #require(t.words.first { $0.text.lowercased().hasPrefix("välkommen") })
        #expect(Double(v.start) / info.sampleRate < 1.0 && Double(v.end) / info.sampleRate > 0.5)

        // Into a project: deleting "välkommen" by text removes it from what plays.
        var p = Project(source: ref)
        p.setTranscript(t)
        try p.deleteWords([v.id])
        #expect(!p.transcriptText().lowercased().contains("välkommen"))
    }
}
