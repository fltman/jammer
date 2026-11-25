import Foundation
import JammerCore
import JammerSpeech
import Testing
@testable import JammerWhisper

/// Naming voice tracks from introductions, measured on synthetic voices (the comfort block, step 5): macOS voices
/// say introductions in English and Swedish, the multilingual Whisper small that Transcribe Voice Tracks requires
/// finds the language and transcribes them as the app does, and `introducedName` names the speaker or doesn't.
/// Reported: how often the right name comes out, a wrong one, or none; and the lines that must give no name.
/// Uses only the installed model (never downloads); runs with `JAMMER_BENCH=1`. Results in docs/TRANSCRIPTION.md.
@Suite("Introductions name tracks", .serialized, .enabled(if: ProcessInfo.processInfo.environment["JAMMER_BENCH"] == "1"))
struct IntroNamingEval {
    struct Language {
        let code: String
        /// Voice and speaking rate.
        let voices: [(String, Int)]
        let names: [String]
        /// "{N}" is the name.
        let forms: [String]
        /// Lines that name nobody as the speaker.
        let negatives: [String]
    }

    static let english = Language(
        code: "en",
        voices: [("Daniel", 180), ("Moira", 180), ("Karen", 180), ("Samantha", 180), ("Tessa", 180), ("Rishi", 180)],
        names: ["Daniel", "Sarah", "Michael", "Emma", "James", "Olivia", "Lucy", "Thomas"],
        forms: ["My name is {N}.", "Hi, I'm {N}.", "Hello, I am {N} and I work as a teacher.", "I'm {N}, and I'll be your host today.",
                "Hi everyone, this is {N}.", "Good morning. I'm {N} from the newsroom.", "Hello there, my name's {N}.", "I am {N}."],
        negatives: ["I'm happy to be here today.", "I'm British and I live in London.", "This is London calling.",
                    "I am sure that Daniel will join us later."])

    static let swedish = Language(
        code: "sv",
        voices: [("Alva", 160), ("Alva", 200), ("Alva", 240)],
        names: ["Anna", "Erik", "Karin", "Lars", "Sofia", "Johan", "Maria", "Henrik"],
        forms: ["Jag heter {N}.", "Hej, jag heter {N}.", "Hej, jag är {N}.", "Jag är {N} och jobbar som lärare.",
                "Mitt namn är {N}.", "Hej allihop, det här är {N}.", "God morgon. Jag heter {N} och kommer från Göteborg.",
                "Hej och välkommen. Jag är {N}."],
        negatives: ["Jag är glad att vara här.", "Jag är från Stockholm.", "Det här är Sverige.", "Jag tror att Erik kommer senare."])

    func say(_ voice: String, rate: Int, _ text: String, to url: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", voice, "-r", "\(rate)", "-o", url.path, "--data-format=BEI16@48000", text]
        try p.run()
        p.waitUntilExit()
    }

    @Test("Names from introductions, English and Swedish, on macOS voices")
    func measure() async throws {
        let store = ModelStore.standard()
        let spec = ModelSpec.multilingualWhisper
        guard store.isInstalled(spec) else {
            print("BENCH  \(spec.id) isn't installed; nothing measured (this never downloads)")
            return
        }
        let whisper = WhisperEngine(model: spec, path: store.path(for: spec), language: nil)
        let dir = FileManager.default.temporaryDirectory.appending(path: "jammer-intro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var n = 0
        for lang in [Self.english, Self.swedish] {
            var right = 0, wrong = 0, none = 0, falseNames = 0, wrongLanguage = 0, total = 0
            var misses: [String] = []
            func hear(_ voice: String, _ rate: Int, _ line: String) async throws -> (String?, String, String) {
                n += 1
                let url = dir.appending(path: "\(n).aiff")
                try say(voice, rate: rate, line, to: url)
                let source = SourceRef(name: "intro", path: url.path, info: try AudioFileReader.info(at: url))
                // As the app: the language Whisper hears, then its words in that language.
                let heard = try whisper.detectLanguage(source, pool: SourcePool()) ?? "und"
                let t = try await whisper.transcribe(source, pool: SourcePool(), locale: Locale(identifier: heard)) { _ in }
                let text = t.words.map(\.text).joined(separator: " ")
                return (VoiceTrackTranscription.introducedName(t.words, language: heard), heard, text)
            }
            for (v, (voice, rate)) in lang.voices.enumerated() {
                for (f, form) in lang.forms.enumerated() {
                    let name = lang.names[(f + v) % lang.names.count]
                    let (got, heard, text) = try await hear(voice, rate, form.replacingOccurrences(of: "{N}", with: name))
                    total += 1
                    if heard != lang.code { wrongLanguage += 1 }
                    if got == name { right += 1 } else {
                        if got == nil { none += 1 } else { wrong += 1 }
                        misses.append("\(voice)@\(rate) [\(heard)] \"\(text)\" → \(got ?? "none") (want \(name))")
                    }
                }
                for line in lang.negatives {
                    let (got, heard, text) = try await hear(voice, rate, line)
                    if let got {
                        falseNames += 1
                        misses.append("\(voice)@\(rate) [\(heard)] \"\(text)\" → \(got) (want none)")
                    }
                }
            }
            let negatives = lang.voices.count * lang.negatives.count
            print(String(format: "BENCH  %@: right %d/%d (%.0f %%), wrong name %d, none %d, language misheard %d; named where nobody should be %d/%d",
                         lang.code, right, total, 100 * Double(right) / Double(total), wrong, none, wrongLanguage, falseNames, negatives))
            for m in misses { print("BENCH    \(m)") }
        }
    }
}
