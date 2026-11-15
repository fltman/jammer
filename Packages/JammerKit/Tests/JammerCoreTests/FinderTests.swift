import Foundation
import Testing
@testable import JammerCore

@Suite("Finders")
struct FinderTests {
    @Test("Silences: only stretches long enough and quiet enough")
    func silences() {
        // 0–1 s tone, 1–2.5 s silence, 2.5–3 s tone, 3–3.3 s silence, 3.3–4 s tone.
        let sr = 48_000
        var mono = [Float](repeating: 0, count: sr * 4)
        for i in 0..<mono.count {
            let t = Double(i) / Double(sr)
            if t < 1 || (t >= 2.5 && t < 3) || t >= 3.3 { mono[i] = Float(0.3 * sin(2 * .pi * 300 * t)) }
        }
        let (p, pool) = memoryProject(mono.flatMap { [$0, $0] })
        let found = p.silences(minLength: Frame(sr), pool: pool)
        #expect(found.count == 1)
        #expect(abs(Int(found[0].lowerBound) - sr) <= 480 && abs(Int(found[0].upperBound) - sr * 5 / 2) <= 480)
        #expect(p.silences(minLength: Frame(sr / 5), pool: pool).count == 2)
    }

    @Test("Filler words are found by how they read, case and punctuation aside")
    func fillers() {
        var (p, _) = memoryProject([Float](repeating: 0, count: 96_000))
        let words = ["Ehm,", "hej", "öh", "och", "Hmm.", "välkommen"].enumerated().map { Word(text: $1, start: Frame($0) * 4_000, end: Frame($0) * 4_000 + 2_000) }
        p.setTranscript(SourceTranscript(sourceID: p.sources[0].id, language: "sv-SE", engine: "t", words: words))
        #expect(p.fillerWordIDs() == [words[0].id, words[2].id, words[4].id])
        #expect(p.fillerWordIDs(extra: ["liksom"]).count == 3)
    }
}
