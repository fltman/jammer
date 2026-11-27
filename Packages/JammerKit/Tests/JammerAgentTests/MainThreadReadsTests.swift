import Foundation
import Testing

/// The timeline's draw runs on the main thread and never reads the audio files (2026-11-27: with allowRaw true the
/// first draw of a 24-track document read every short clip from disk, 156 s with the window unanswering; measured in
/// BigOpenBench). Only the job it starts off the main thread (requestExact) may read them.
@Suite("The main thread never waits for a disk: the waveform's draw")
struct MainThreadReadsTests {
    @Test("In WaveformMetalView.draw every columnValues outside the background job has allowRaw: false")
    func drawReadsNoFiles() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../../App/TimelineView.swift").standardizedFileURL
        let text = try String(contentsOf: file, encoding: .utf8)
        guard let start = text.range(of: "func draw(in view: MTKView)"), let end = text.range(of: "\n    }\n", range: start.upperBound..<text.endIndex) else {
            Issue.record("WaveformMetalView.draw wasn't found in \(file.path)"); return
        }
        var body = String(text[start.lowerBound..<end.upperBound])
        // The background job's closure may read the files (its own allowRaw); it is taken out first.
        if let job = body.range(of: "requestExact(") , let close = body.range(of: "\n                }", range: job.upperBound..<body.endIndex) {
            body.removeSubrange(job.lowerBound..<close.upperBound)
        }
        let uses = body.components(separatedBy: "allowRaw:").dropFirst().map { $0.prefix(while: { $0 != ")" && $0 != "," }).trimmingCharacters(in: .whitespaces) }
        #expect(!uses.isEmpty, "the draw makes its columns with an explicit allowRaw")
        #expect(uses.allSatisfy { $0 == "false" }, "allowRaw in the draw: \(uses)")
    }
}
