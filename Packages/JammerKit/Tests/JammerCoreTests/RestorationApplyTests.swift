import Foundation
import Testing
@testable import JammerCore

@Suite("Applying restoration")
struct RestorationApplyTests {
    let sr = 48_000.0

    /// A WAV with a voice-like tone plus 60 Hz hum, as a project with a transcript.
    private func setup(_ dir: TempDir, hum: Bool = true) throws -> (Project, SourcePool, [Float]) {
        let n = Int(sr * 3)
        var x = [Float](repeating: 0, count: n * 2)
        for i in 0..<n {
            let t = Double(i) / sr
            var v = 0.3 * sin(2 * .pi * 220 * t) + 0.1 * sin(2 * .pi * 660 * t)
            if hum { v += 0.05 * sin(2 * .pi * 60 * t) + 0.03 * sin(2 * .pi * 120 * t) }
            x[i * 2] = Float(v)
            x[i * 2 + 1] = Float(v * 0.8)
        }
        let url = dir.file("take.wav")
        try writeWAV(x, to: url)
        var p = Project(source: SourceRef(name: "take", path: url.path, info: try AudioFileReader.info(at: url)))
        p.setTranscript(SourceTranscript(sourceID: p.sources[0].id, language: "sv-SE", engine: "test",
                                         words: [Word(text: "ett", start: 10_000, end: 30_000), Word(text: "två", start: 100_000, end: 120_000)]))
        return (p, SourcePool(), x)
    }

    private func render(_ p: Project, _ pool: SourcePool) -> [Float] {
        let plan = PlanCompiler.compile(p, pool: pool)
        return plan.render(from: 0, frames: Int(plan.length))
    }

    @Test("De-hum on a range: new source there, hum gone, the rest bit-exact, words kept, undo is the old value")
    func dehumRange() throws {
        let dir = TempDir()
        let (p, pool, original) = try setup(dir)
        let range: Range<Frame> = 48_000..<144_000
        let (q, report) = try Restoration.apply(.init(kind: .dehum), to: p, range: range, pool: pool, media: dir.file("Media"))
        #expect(report.clips == 1)
        #expect(abs((report.humFrequency ?? 0) - 60) < 0.05)
        #expect(q.length == p.length)
        #expect(q.sources.count == 2)
        #expect(FileManager.default.fileExists(atPath: q.sources[1].path))
        let out = render(q, pool)
        // Outside the range: untouched, bit for bit.
        #expect(Array(out[0..<(48_000 * 2)]) == Array(original[0..<(48_000 * 2)]))
        #expect(Array(out[(144_000 * 2)...]) == Array(original[(144_000 * 2)...]))
        // Inside (after the notches settle): hum down a lot, voice kept.
        let left = stride(from: 96_000 * 2, to: 144_000 * 2, by: 2).map { out[$0] }
        let leftIn = stride(from: 96_000 * 2, to: 144_000 * 2, by: 2).map { original[$0] }
        func lvl(_ x: [Float], _ f: Double) -> Double { 10 * log10(Restoration.goertzel(x, f, sr)) }
        #expect(lvl(leftIn, 60) - lvl(left, 60) > 25)
        #expect(abs(lvl(leftIn, 220) - lvl(left, 220)) < 0.5)
        // Words keep their ids and their place on the timeline.
        #expect(q.placedWords().map(\.start) == p.placedWords().map(\.start))
        #expect(q.placedWords().map(\.word.id) == p.placedWords().map(\.word.id))
        // The original file is untouched; the old project value still plays it.
        #expect(render(p, pool) == original)
    }

    @Test("Amount 0 renders the same samples; no hum is an error unless a frequency is given")
    func amountAndErrors() throws {
        let dir = TempDir()
        let (p, pool, original) = try setup(dir, hum: false)
        #expect(throws: Restoration.ApplyError.noHum) {
            try Restoration.apply(.init(kind: .dehum), to: p, pool: pool, media: dir.file("Media"))
        }
        let (q, _) = try Restoration.apply(.init(kind: .declick, amount: 0), to: p, pool: pool, media: dir.file("Media"))
        #expect(render(q, pool) == original)
        let (h, r) = try Restoration.apply(.init(kind: .dehum, humFrequency: 50), to: p, pool: pool, media: dir.file("Media"))
        #expect(r.humFrequency == 50 && h.sources.count == 1)
        #expect(throws: Restoration.ApplyError.nothingInRange) {
            try Restoration.apply(.init(kind: .declick), to: p, range: 500_000..<600_000, pool: pool, media: dir.file("Media"))
        }
        #expect(throws: CancellationError.self) {
            try Restoration.apply(.init(kind: .declick), to: p, pool: pool, media: dir.file("Media2")) { _ in false }
        }
    }
}
