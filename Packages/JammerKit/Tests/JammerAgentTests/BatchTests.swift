import CryptoKit
import Foundation
import Testing
import JammerCore
@testable import JammerAgent

@Suite("Batch")
struct BatchTests {
    func tone(_ url: URL, db: Double) throws {
        let n = 48_000 * 4
        let a = pow(10, db / 20)
        let x = (0..<n).flatMap { i -> [Float] in let v = Float(a * sin(2 * .pi * 440 * Double(i) / 48_000)); return [v, v] }
        let w = try WAVWriter(url: url, options: .init(encoding: .int24, channels: 2, sampleRate: 48_000))
        try w.write(x); try w.finish()
    }
    func hash(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }
    func folder() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "jammer-batch-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: d.appending(path: "in"), withIntermediateDirectories: true)
        return d
    }

    @Test("Three files, one broken: two come out at the target loudness, the broken one is reported, the originals are untouched")
    func run() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appending(path: "in/a.wav"), b = dir.appending(path: "in/b.wav"), c = dir.appending(path: "in/c.wav")
        try tone(a, db: -30); try tone(b, db: -12)
        try Data("this is not audio".utf8).write(to: c)
        let before = [try hash(a), try hash(b), try hash(c)]
        let body: [String: Any] = ["folder": dir.appending(path: "in").path, "output": dir.appending(path: "out").path,
                                   "steps": [["op": "normalize", "params": ["target": "loudness", "level": -20]]], "export": ["format": "flac", "bitDepth": 24]]
        let request = try BatchRequest.parse(body, policy: FolderPolicy(allowed: [dir]))
        #expect(request.inputs.count == 3)
        let result = await BatchRunner.run(request, media: dir.appending(path: "media"))
        #expect(result.outputs.count == 2 && result.failed.count == 1 && result.failed[0].file.hasSuffix("c.wav") && result.failed[0].reason == "unreadable")
        for out in result.outputs {
            let url = URL(fileURLWithPath: out)
            #expect(url.lastPathComponent.hasSuffix(" (Jämmer).flac"))
            let r = try AudioImporter.importFile(url, mediaFolder: dir.appending(path: "media"))
            let p = Project(source: r.source)
            let l = LoudnessMeter.measure(PlanCompiler.compile(p, pool: SourcePool()), 0..<p.length).integrated ?? 0
            #expect(abs(l + 20) < 0.2, "\(url.lastPathComponent): \(l) LUFS")
        }
        #expect(result.loudness.count == 2 && result.loudness.allSatisfy { abs(($0 ?? 0) + 20) < 0.2 } && result.limitedByPeak == [false, false])
        // A target the peaks don't allow (a quiet tone with loud clicks): reported, not hidden.
        let peaky = dir.appending(path: "in/peaky.wav")
        let n = 48_000 * 4
        let x = (0..<n).flatMap { i -> [Float] in let v = Float(0.01 * sin(2 * .pi * 440 * Double(i) / 48_000)) + (i % 12_000 == 0 ? 0.9 : 0); return [v, v] }
        let w = try WAVWriter(url: peaky, options: .init(encoding: .int24, channels: 2, sampleRate: 48_000))
        try w.write(x); try w.finish()
        let loud = BatchRequest(inputs: [peaky], steps: [Step(op: "loudness_preset", params: ["preset": .string("spotify")])], output: dir.appending(path: "out"))
        let limited = await BatchRunner.run(loud, media: dir.appending(path: "media"))
        #expect(limited.limitedByPeak == [true] && ((limited.loudness.first ?? nil) ?? 0) < -15, "\(limited.loudness) \(limited.limitedByPeak)")
        try FileManager.default.removeItem(at: peaky)
        #expect([try hash(a), try hash(b), try hash(c)] == before)
        // Again without overwrite: the two are skipped, nothing rewritten.
        let again = await BatchRunner.run(request, media: dir.appending(path: "media"))
        #expect(again.skipped.count == 2 && again.outputs.isEmpty)
    }

    @Test("Paths must lie in an allowed folder, also through symlinks and ..; output never lands on an input")
    func policy() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outside = try folder()
        defer { try? FileManager.default.removeItem(at: outside) }
        try tone(dir.appending(path: "in/a.wav"), db: -20)
        try tone(outside.appending(path: "in/secret.wav"), db: -20)
        try FileManager.default.createSymbolicLink(at: dir.appending(path: "in/link"), withDestinationURL: outside.appending(path: "in"))
        let policy = FolderPolicy(allowed: [dir])
        func reason(_ body: [String: Any], _ p: FolderPolicy? = policy) -> String? {
            do { _ = try BatchRequest.parse(body, policy: p); return nil } catch { return (error as? BatchError)?.reason }
        }
        let out = dir.appending(path: "out").path
        #expect(reason(["files": [dir.appending(path: "in/a.wav").path], "output": out]) == nil)
        #expect(reason(["files": [outside.appending(path: "in/secret.wav").path], "output": out]) == "folder_not_allowed")
        #expect(reason(["files": [dir.appending(path: "in/link/secret.wav").path], "output": out]) == "folder_not_allowed")
        #expect(reason(["files": [dir.path + "/in/../../" + outside.lastPathComponent + "/in/secret.wav"], "output": out]) == "folder_not_allowed")
        #expect(reason(["files": [dir.appending(path: "in/a.wav").path], "output": dir.appending(path: "in/link/out").path]) == "folder_not_allowed")
        #expect(reason(["files": [dir.appending(path: "in/a.wav").path], "output": out], FolderPolicy(allowed: [])) == "folder_not_allowed")
        #expect(reason(["files": ["relative.wav"], "output": out]) == "bad_request")
        // Same folder, no suffix, same format: the output would be the input.
        #expect(reason(["files": [dir.appending(path: "in/a.wav").path], "output": dir.appending(path: "in").path, "suffix": "", "overwrite": true]) == "would_overwrite_source")
        #expect(reason(["files": [dir.appending(path: "in/a.wav").path], "output": dir.appending(path: "in").path, "overwrite": true]) == nil)
    }
}
