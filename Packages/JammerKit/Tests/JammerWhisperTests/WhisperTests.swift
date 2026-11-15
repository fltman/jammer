import Foundation
import JammerCore
import JammerSpeech
import Testing
@testable import JammerWhisper

/// KB-Whisper on the same synthetic Swedish as the Apple benchmark. Downloads the model
/// (checked against its SHA-256) into JAMMER_MODELS_DIR. `JAMMER_BENCH=1`;
/// JAMMER_WHISPER_MODEL=kb-whisper-small-q5 (default) or kb-whisper-medium-q5.
@Suite("Whisper benchmark", .enabled(if: ProcessInfo.processInfo.environment["JAMMER_BENCH"] != nil))
struct WhisperBenchmark {
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

    @Test("KB-Whisper on synthetic Swedish")
    func kbWhisper() async throws {
        let env = ProcessInfo.processInfo.environment
        let spec = ModelSpec.catalogue.first { $0.id == (env["JAMMER_WHISPER_MODEL"] ?? "kb-whisper-small-q5") }!
        let store = ModelStore.standard()
        let t0 = ContinuousClock.now
        let path = try await store.install(spec)
        print("BENCH  model \(spec.id) ready in \(ContinuousClock.now - t0) at \(path.path)")
        let engine = WhisperEngine(model: spec, path: path)
        let dir = FileManager.default.temporaryDirectory.appending(path: "jammer-wbench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var rows: [String] = []
        var total = WordErrorRate.zero
        var audioSeconds = 0.0, wall = 0.0
        var timingOK = true
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
                timingOK = timingOK && t.words.allSatisfy { $0.start <= $0.end && $0.end <= info.frames }
                    && zip(t.words, t.words.dropFirst()).allSatisfy { $0.start <= $1.start }
                let hyp = t.words.map(\.text).joined(separator: " ")
                let w = WordErrorRate.compute(reference: s, hypothesis: hyp)
                if w.errors > 0 { print("BENCH  \(rate) wpm: \"\(s)\" → \"\(hyp)\"") }
                wer = wer + w
            }
            total = total + wer
            rows.append("| KB-Whisper \(spec.id.replacingOccurrences(of: "kb-whisper-", with: "")) | Alva, \(rate) wpm | \(wer.referenceWords) | \(wer.substitutions) / \(wer.deletions) / \(wer.insertions) | \(String(format: "%.1f %%", wer.rate * 100)) |")
        }
        print(rows.joined(separator: "\n"))
        print("BENCH  all: \(String(format: "%.1f %%", total.rate * 100)) WER over \(total.referenceWords) words; \(String(format: "%.0f", audioSeconds)) s of audio in \(String(format: "%.1f", wall)) s (\(String(format: "%.1f", audioSeconds / max(wall, 1e-9)))× real time)")
        #expect(timingOK)
        #expect(total.rate < 0.5)
    }
}
