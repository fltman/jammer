import Foundation
import Testing
@testable import JammerAgent

/// The install register (SIBLINGS, "Det som kan behöva installeras").
@Suite("What Jämmer may need installed")
struct RequirementsTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    @Test("Every item has its source, exact version, checksum or commit and licence (or, installed by the user, a way to verify it)")
    func complete() {
        for r in Requirements.all { #expect(Requirements.faults(r).isEmpty, "\(Requirements.faults(r))") }
        // A planted fault is caught: a model without a checksum, one without a licence, a GPL one.
        var bad = Requirements.all[0]
        bad.source.sha256 = nil
        #expect(Requirements.faults(bad).contains { $0.contains("checksum") })
        bad = Requirements.all[0]; bad.license = nil
        #expect(Requirements.faults(bad).contains { $0.contains("license") })
        bad = Requirements.all[0]; bad.license = .init(spdx: "GPL-3.0-only", url: "x")
        #expect(Requirements.faults(bad).contains { $0.contains("GPL") })
    }

    @Test("Every call that can answer model_missing has an item, and the licence list names every model the app fetches")
    func matchesTheRestOfTheApp() throws {
        let needed = Set(Requirements.all.flatMap(\.neededBy))
        for op in ["transcribe", "diarize", "separate"] { #expect(needed.contains(op), "\(op)") }
        let licences = try String(contentsOf: Self.repo.appending(path: "docs/LICENSES.md"), encoding: .utf8)
        for (id, word) in [("kb-whisper-small", "KB-Whisper"), ("kb-whisper-medium", "KB-Whisper"), ("parakeet-tdt-0.6b-v3", "Parakeet"),
                           ("diarisation", "speaker-diarization-community-1"), ("spleeter-4stems", "Spleeter"), ("mrx", "MRX")] {
            #expect(Requirements.all.contains { $0.id == id } && licences.contains(word), "\(id): \(word)")
        }
    }

    @Test("A release lists only what it can use, and the JSON has the fields the series agreed on")
    func listing() {
        #expect(!Requirements.listed(clap: false).contains { $0.id == "clap-plugins" } && Requirements.listed(clap: true).contains { $0.id == "clap-plugins" })
        let j = Requirements.json(Requirements.all[0], installed: false)
        for k in ["id", "name", "kind", "neededBy", "required", "installed", "sizeBytes", "license", "source", "install", "where", "remove", "modes", "debugOnly"] {
            #expect(j[k] != nil, "\(k)")
        }
        #expect((Requirements.json(Requirements.all.first { $0.id == "audio-units" }!, installed: nil)["verify"] as? [String: Any])?["command"] != nil)
        #expect(Requirements.guideSection(clap: false).contains("## What Jämmer may need installed") && !Requirements.guideSection(clap: false).contains("clap-plugins"))
    }
}
