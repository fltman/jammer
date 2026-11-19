import CryptoKit
import Foundation
import JammerCore
import Testing
@testable import JammerSpeech

@Suite("Word error rate")
struct WordErrorRateTests {
    @Test("Known reference cases")
    func known() {
        // jiwer's README example: one substitution in two words.
        #expect(WordErrorRate.compute(reference: "hello world", hypothesis: "hello duck").rate == 0.5)
        // One substitution and one deletion in six words.
        let w = WordErrorRate.compute(reference: "the cat sat on the mat", hypothesis: "the cat sit on mat")
        #expect(w.substitutions == 1 && w.deletions == 1 && w.insertions == 0 && w.referenceWords == 6)
        #expect(abs(w.rate - 2.0 / 6) < 1e-12)
        // One insertion.
        let i = WordErrorRate.compute(reference: "a b c", hypothesis: "a x b c")
        #expect(i.insertions == 1 && i.errors == 1)
        // Everything deleted; nothing to recognise.
        #expect(WordErrorRate.compute(reference: "ett två tre", hypothesis: "").rate == 1)
        #expect(WordErrorRate.compute(reference: "", hypothesis: "").rate == 0)
        #expect(WordErrorRate.compute(reference: "", hypothesis: "brus").rate == 1)
        // Insertions can push it over 1.
        #expect(WordErrorRate.compute(reference: "ja", hypothesis: "nej nej nej").rate == 3)
    }

    @Test("Case and punctuation don't count; å, ä and ö do")
    func normalising() {
        #expect(WordErrorRate.compute(reference: "Hej, och välkommen!", hypothesis: "hej och välkommen").rate == 0)
        #expect(WordErrorRate.compute(reference: "här är vi", hypothesis: "har är vi").substitutions == 1)
        #expect(WordErrorRate.normalise("podd-avsnitt – del två.") == ["podd", "avsnitt", "del", "två"])
    }

    @Test("Agrees with a brute-force edit distance on random word lists")
    func bruteForce() {
        func distance(_ a: [String], _ b: [String]) -> Int {
            if a.isEmpty { return b.count }
            if b.isEmpty { return a.count }
            return min(distance(Array(a.dropFirst()), Array(b.dropFirst())) + (a[0] == b[0] ? 0 : 1),
                       distance(Array(a.dropFirst()), b) + 1, distance(a, Array(b.dropFirst())) + 1)
        }
        var rng = SystemRandomNumberGenerator()
        let vocab = ["a", "b", "c", "d"]
        for _ in 0..<200 {
            let r = (0..<Int.random(in: 0...6, using: &rng)).map { _ in vocab.randomElement(using: &rng)! }
            let h = (0..<Int.random(in: 0...6, using: &rng)).map { _ in vocab.randomElement(using: &rng)! }
            #expect(WordErrorRate.compute(reference: r, hypothesis: h).errors == distance(r, h), "\(r) vs \(h)")
        }
    }
}

@Suite("Model store")
struct ModelStoreTests {
    @Test("URLs follow the Hugging Face layout under a configurable source")
    func urls() {
        let store = ModelStore(folder: URL(fileURLWithPath: "/tmp/m"))
        #expect(store.url(for: .kbWhisperSmallQ5).absoluteString == "https://huggingface.co/KBLab/kb-whisper-small/resolve/3564d61a42fc210ceaa55a22a96dd64478959c78/ggml-model-q5_0.bin")
        let mirror = ModelStore(source: URL(string: "https://mirror.example/hf")!, folder: URL(fileURLWithPath: "/tmp/m"))
        #expect(mirror.url(for: .kbWhisperSmallQ5).absoluteString == "https://mirror.example/hf/KBLab/kb-whisper-small/resolve/3564d61a42fc210ceaa55a22a96dd64478959c78/ggml-model-q5_0.bin")
        // Defaults that live only in this object: a test leaves nothing in ~/Library/Preferences.
        let defaults = UserDefaults()
        defaults.setVolatileDomain(["models.source": "https://mirror.example"], forName: UserDefaults.argumentDomain)
        let s = ModelStore.standard(defaults: defaults, environment: ["JAMMER_MODELS_DIR": "/Volumes/x/models"])
        #expect(s.source.absoluteString == "https://mirror.example" && s.folder.path == "/Volumes/x/models")
    }

    @Test("Install checks size and checksum before anything is used")
    func install() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "jammer-models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let served = root.appending(path: "source/Org/model/resolve/main/m.bin")
        try FileManager.default.createDirectory(at: served.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payload.write(to: served)
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let store = ModelStore(source: root.appending(path: "source"), folder: root.appending(path: "models"))
        var spec = ModelSpec(id: "test", title: "t", repo: "Org/model", file: "m.bin", size: Int64(payload.count), sha256: hash, licence: "MIT")

        let url = try await store.install(spec)
        #expect(try Data(contentsOf: url) == payload)
        #expect(store.isInstalled(spec))
        try store.remove(spec)
        #expect(!store.isInstalled(spec))

        spec.sha256 = String(repeating: "0", count: 64)
        await #expect(throws: ModelError.wrongChecksum) { try await store.install(spec) }
        #expect(!FileManager.default.fileExists(atPath: store.path(for: spec).path))
        spec.sha256 = hash
        spec.size += 1
        await #expect(throws: ModelError.wrongSize(expected: Int64(payload.count) + 1, got: Int64(payload.count))) { try await store.install(spec) }
    }
}

/// Recognition quality and speed on synthetic speech (macOS voice Alva, two rates).
/// `JAMMER_BENCH=1`; `JAMMER_BENCH_REPORT=path` also writes the table as Markdown.
@Suite("Transcription benchmark", .enabled(if: ProcessInfo.processInfo.environment["JAMMER_BENCH"] != nil))
struct TranscriptionBenchmark {
    static let sentences = [
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

    @Test("Apple dictation on synthetic Swedish")
    func apple() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "jammer-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = AppleSpeechEngine()
        var rows: [String] = []
        var total = WordErrorRate.zero
        var audioSeconds = 0.0, wall = 0.0
        for rate in [180, 230] {
            var wer = WordErrorRate.zero
            for (i, s) in Self.sentences.enumerated() {
                let url = dir.appending(path: "s\(rate)-\(i).aiff")
                let say = Process()
                say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                say.arguments = ["-v", "Alva", "-r", "\(rate)", "-o", url.path, "--data-format=BEI16@48000", s]
                try say.run()
                say.waitUntilExit()
                let info = try AudioFileReader.info(at: url)
                let ref = SourceRef(name: "s", path: url.path, info: info)
                let start = ContinuousClock.now
                let t = try await engine.transcribe(ref, pool: SourcePool(), locale: Locale(identifier: "sv-SE")) { _ in }
                let d = ContinuousClock.now - start
                wall += Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
                audioSeconds += Double(info.frames) / info.sampleRate
                let hyp = t.words.map(\.text).joined(separator: " ")
                let w = WordErrorRate.compute(reference: s, hypothesis: hyp)
                if w.errors > 0 { print("BENCH  \(rate) wpm: \"\(s)\" → \"\(hyp)\"") }
                wer = wer + w
            }
            total = total + wer
            rows.append("| Apple dictation (sv-SE) | Alva, \(rate) wpm | \(wer.referenceWords) | \(wer.substitutions) / \(wer.deletions) / \(wer.insertions) | \(String(format: "%.1f %%", wer.rate * 100)) |")
        }
        let speed = audioSeconds / max(wall, 1e-9)
        let table = "| Engine | Speech | Words | S / D / I | WER |\n|---|---|---|---|---|\n" + rows.joined(separator: "\n")
            + "\n\nAll: \(String(format: "%.1f %%", total.rate * 100)) WER over \(total.referenceWords) words; \(String(format: "%.0f", audioSeconds)) s of audio in \(String(format: "%.1f", wall)) s (\(String(format: "%.0f", speed))× real time, including model start per sentence).\n"
        print(table)
        if let path = ProcessInfo.processInfo.environment["JAMMER_BENCH_REPORT"] { try table.write(toFile: path, atomically: true, encoding: .utf8) }
        #expect(total.rate < 0.25)
    }
}


@Suite("Words without duration")
struct CollapsedWordTests {
    @Test("Words a recogniser gives no duration get the stretch before the next timed word, in order, never overlapping")
    func spread() {
        let runs = [RecognisedRun(text: "Ljudverkstan.", start: 2.17, end: 3.23, confidence: nil),
                    RecognisedRun(text: "Idag", start: 4.16, end: 4.16, confidence: nil), RecognisedRun(text: "ska", start: 4.16, end: 4.16, confidence: nil),
                    RecognisedRun(text: "vi", start: 4.16, end: 4.16, confidence: nil), RecognisedRun(text: "prata", start: 4.25, end: 4.50, confidence: nil),
                    RecognisedRun(text: "till", start: 22.0, end: 22.0, confidence: nil)]
        let w = WordBuilder.words(from: runs, sampleRate: 48_000, sourceFrames: 48_000 * 30)
        #expect(w.allSatisfy { $0.end > $0.start })
        #expect(zip(w, w.dropFirst()).allSatisfy { $0.end <= $1.start })
        #expect(w[1].start >= w[0].end && w[3].end == w[4].start)
        #expect(Double(w[3].end - w[1].start) / 48_000 > 0.5) // nine characters at about 70 ms
        #expect(w[5].end > w[5].start)                         // the last one, with nothing after it
    }
}
