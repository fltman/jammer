import FluidAudio
import Foundation
import JammerCore
import JammerSpeech
import Testing
@testable import JammerParakeet

@Suite("Parakeet words")
struct ParakeetWordTests {
    @Test("SentencePiece tokens join into words with times and their mean confidence")
    func words() {
        let t = [TokenTiming(token: "▁Hej", tokenId: 1, startTime: 0.10, endTime: 0.30, confidence: 0.9),
                 TokenTiming(token: "▁väl", tokenId: 2, startTime: 0.40, endTime: 0.55, confidence: 0.8),
                 TokenTiming(token: "kom", tokenId: 3, startTime: 0.55, endTime: 0.70, confidence: 0.6),
                 TokenTiming(token: "men", tokenId: 4, startTime: 0.70, endTime: 0.80, confidence: 0.95),
                 TokenTiming(token: ".", tokenId: 5, startTime: 0.80, endTime: 0.82, confidence: 0.99)]
        let w = ParakeetEngine.words(t, sampleRate: 48_000)
        #expect(w.map(\.text) == ["Hej", "välkommen."])
        // FluidAudio's tokens mark a new word with a leading space.
        let spaced = t.map { TokenTiming(token: $0.token.replacingOccurrences(of: "▁", with: " "), tokenId: $0.tokenId, startTime: $0.startTime, endTime: $0.endTime, confidence: $0.confidence) }
        #expect(ParakeetEngine.words(spaced, sampleRate: 48_000).map(\.text) == ["Hej", "välkommen."])
        #expect(w[1].start == 19_200 && w[1].end == 39_360)
        #expect(abs((w[1].confidence ?? 0) - (0.8 + 0.6 + 0.95 + 0.99) / 4) < 1e-6)
    }
}

/// Parakeet on the same synthetic Swedish as KB-Whisper and Apple, plus English. Downloads
/// the model (about 630 MB) into JAMMER_MODELS_DIR; `JAMMER_BENCH=1`.
@Suite("Parakeet benchmark", .serialized, .enabled(if: ProcessInfo.processInfo.environment["JAMMER_BENCH"] != nil))
struct ParakeetBenchmark {
    static let swedish = [
        "Hej och välkommen till dagens avsnitt.",
        "Vi ska prata om hur man spelar in en bra podd hemma.",
        "Först behöver du en mikrofon och ett tyst rum.",
        "Mattor och gardiner dämpar ekot i rummet.",
        "Håll mikrofonen ungefär en handsbredd från munnen.",
        "Spela in en minut av tystnad innan ni börjar prata.",
        "Den kan användas senare för att ta bort brus.",
        "Prata lugnt och ta gärna en paus mellan meningarna.",
        "När inspelningen är klar lyssnar du igenom allt en gång.",
        "Ta bort långa tystnader och upprepningar.",
        "Normalisera ljudet till minus sexton LUFS innan publicering.",
        "Kapitelmarkeringar gör det lättare för lyssnarna att hitta rätt.",
        "Glöm inte att spara projektet ofta.",
        "Tack för att du lyssnade och välkommen tillbaka nästa vecka.",
    ]
    static let english = [
        "Welcome back to the show.",
        "Today we are talking about recording a podcast at home.",
        "You need a decent microphone and a quiet room.",
        "Rugs and curtains take the echo out of the room.",
        "Keep the microphone about a hand's width from your mouth.",
        "When you are done, listen to the whole recording once.",
        "Thanks for listening, and see you next week.",
    ]

    func run(_ engine: ParakeetEngine, _ sentences: [String], voice: String, locale: String, rate: Int, dir: URL) async throws -> (WordErrorRate, Double, Double, Bool) {
        var wer = WordErrorRate.zero, audio = 0.0, wall = 0.0, timingOK = true
        for (i, s) in sentences.enumerated() {
            let url = dir.appending(path: "\(voice)-\(rate)-\(i).aiff")
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-v", voice, "-r", "\(rate)", "-o", url.path, "--data-format=BEI16@48000", s]
            try say.run()
            say.waitUntilExit()
            let info = try AudioFileReader.info(at: url)
            let ref = SourceRef(name: "s", path: url.path, info: info)
            let start = ContinuousClock.now
            let t = try await engine.transcribe(ref, pool: SourcePool(), locale: Locale(identifier: locale)) { _ in }
            let d = ContinuousClock.now - start
            wall += Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
            audio += Double(info.frames) / info.sampleRate
            timingOK = timingOK && t.words.allSatisfy { $0.start <= $0.end && $0.end <= info.frames + 4_800 }
            // One word per spoken word, not one per sentence (give or take a few misheard joins).
            timingOK = timingOK && abs(t.words.count - s.split(separator: " ").count) <= 3
            let hyp = t.words.map(\.text).joined(separator: " ")
            let w = WordErrorRate.compute(reference: s, hypothesis: hyp)
            if w.errors > 0 { print("BENCH  \(voice) \(rate): \"\(s)\" → \"\(hyp)\"") }
            wer = wer + w
        }
        return (wer, audio, wall, timingOK)
    }

    @Test("Parakeet v3: Swedish (Alva) and English (Daniel)")
    func bench() async throws {
        let store = ModelStore.standard()
        let engine = ParakeetEngine(folder: store.folder, source: store.source)
        let t0 = ContinuousClock.now
        if !engine.isInstalled { try await engine.install() }
        print("BENCH  parakeet ready in \(ContinuousClock.now - t0) at \(store.folder.path)")
        #expect(engine.isInstalled)
        let dir = FileManager.default.temporaryDirectory.appending(path: "jammer-pbench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await run(engine, ["Värmer upp."], voice: "Alva", locale: "sv-SE", rate: 180, dir: dir) // loads the model
        for (voice, locale, sentences) in [("Alva", "sv-SE", Self.swedish), ("Daniel", "en-GB", Self.english)] {
            var all = WordErrorRate.zero, audio = 0.0, wall = 0.0
            for rate in [180, 230] {
                let (w, a, t, ok) = try await run(engine, sentences, voice: voice, locale: locale, rate: rate, dir: dir)
                #expect(ok)
                print("| Parakeet v3 | \(voice), \(rate) wpm | \(w.referenceWords) | \(w.substitutions) / \(w.deletions) / \(w.insertions) | \(String(format: "%.1f %%", w.rate * 100)) |")
                all = all + w; audio += a; wall += t
            }
            print("BENCH  \(locale): \(String(format: "%.1f %%", all.rate * 100)) WER over \(all.referenceWords) words; \(String(format: "%.0f", audio)) s in \(String(format: "%.1f", wall)) s (\(String(format: "%.1f", audio / max(wall, 1e-9)))× real time)")
            #expect(all.rate < 0.5)
        }
    }
}
