import Foundation
import Testing
@testable import JammerCore

/// A model download is checked file by file before it is installed (the coordinator, 2026-11-19).
@Suite("Model manifests")
struct ModelManifestTests {
    func folder(_ files: [String: Data]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "jammer-manifest-\(UUID().uuidString)").appending(path: "repo")
        for (path, data) in files {
            let u = root.appending(path: path)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: u)
        }
        return root
    }

    let weights = Data((0..<4096).map { UInt8($0 % 251) })
    var manifest: ModelManifest {
        // "hello\n" has git's blob id ce013625… (`printf 'hello\n' | git hash-object --stdin`).
        let sha = ModelManifest.sha256Hex(weights)
        return ModelManifest(repo: "x/y", commit: "0123456789", lines: ["a.mlmodelc/weights/weight.bin|4096|sha256:\(sha)",
                                                                        "config.json|6|blob:ce013625030ba8dba906f756967f9e9ca394464a"])
    }

    @Test("Every file listed with its size and sum passes; FluidAudio's own marker is ignored")
    func passes() throws {
        let r = try folder(["a.mlmodelc/weights/weight.bin": weights, "config.json": Data("hello\n".utf8), ".fluidaudio-revision": Data("abc".utf8)])
        defer { try? FileManager.default.removeItem(at: r.deletingLastPathComponent()) }
        try manifest.verify(r)
    }

    @Test("A changed byte, another size, an unknown file or nothing at all fails, naming the file")
    func fails() throws {
        var bad = weights; bad[100] ^= 1
        for (files, file, why) in [
            (["a.mlmodelc/weights/weight.bin": bad, "config.json": Data("hello\n".utf8)], "a.mlmodelc/weights/weight.bin", "sha256"),
            (["a.mlmodelc/weights/weight.bin": weights, "config.json": Data("hellO\n".utf8)], "config.json", "git blob id"),
            (["a.mlmodelc/weights/weight.bin": weights.prefix(4000), "config.json": Data("hello\n".utf8)], "a.mlmodelc/weights/weight.bin", "4000 bytes, not 4096"),
            (["a.mlmodelc/weights/weight.bin": weights, "extra.bin": Data([1])], "extra.bin", "not in the repository at 01234567"),
        ] as [([String: Data], String, String)] {
            let r = try folder(files)
            defer { try? FileManager.default.removeItem(at: r.deletingLastPathComponent()) }
            #expect(throws: ModelManifest.Mismatch(file: file, why: why)) { try manifest.verify(r) }
        }
        let empty = try folder([:])
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(throws: ModelManifest.Mismatch.self) { try manifest.verify(empty) }
    }

    @Test("A download that fails the check installs nothing and leaves no staging folder; one that passes is moved into place")
    func staged() async throws {
        let models = FileManager.default.temporaryDirectory.appending(path: "jammer-staged-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: models) }
        let target = models.appending(path: "diarisation").appending(path: "repo")
        func fill(_ staging: URL, weight: Data) throws {
            try FileManager.default.createDirectory(at: staging.appending(path: "a.mlmodelc/weights"), withIntermediateDirectories: true)
            try weight.write(to: staging.appending(path: "a.mlmodelc/weights/weight.bin"))
            try Data("hello\n".utf8).write(to: staging.appending(path: "config.json"))
        }
        var bad = weights; bad[0] ^= 0xFF
        await #expect(throws: ModelManifest.Mismatch.self) {
            try await manifest.installVerified(target: target) { try fill($0, weight: bad) }
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: models.path).filter { $0.hasPrefix(".staging") }.isEmpty)
        try await manifest.installVerified(target: target) { try fill($0, weight: weights) }
        try manifest.verify(target)
        #expect(try FileManager.default.contentsOfDirectory(atPath: models.path).filter { $0.hasPrefix(".staging") }.isEmpty)
    }

    @Test("The manifests hold every file the app needs, each with a sum")
    func shipped() {
        for f in ["Segmentation.mlmodelc/weights/weight.bin", "FBank.mlmodelc/coremldata.bin", "Embedding.mlmodelc/weights/weight.bin",
                  "PldaRho.mlmodelc/weights/weight.bin", "plda-parameters.json", "config.json", "provenance.json", "xvector-transform.json"] {
            #expect(ModelManifest.diarisation.entries[f] != nil, "\(f)")
        }
        for f in ["Preprocessor.mlmodelc/weights/weight.bin", "Encoder_v2.mlmodelc/weights/weight.bin", "Decoder.mlmodelc/weights/weight.bin",
                  "JointDecisionv3.mlmodelc/weights/weight.bin", "parakeet_v3_vocab.json"] {
            #expect(ModelManifest.parakeetV3.entries[f] != nil, "\(f)")
        }
        for m in [ModelManifest.diarisation, .parakeetV3] {
            #expect(m.entries.values.allSatisfy { ($0.sha256?.count == 64) != ($0.gitBlob?.count == 40) })
        }
    }

    /// The installed model on this Mac against its manifest (JAMMER_MODELS_DIR, the app's own folder).
    @Test("An installed diarisation model passes its manifest", .enabled(if: ProcessInfo.processInfo.environment["JAMMER_MODELS_DIR"] != nil))
    func installed() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JAMMER_MODELS_DIR"]!).appending(path: "diarisation/speaker-diarization")
        try ModelManifest.diarisation.verify(dir)
    }
}
