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

    @Test("After hum or noise removal the reverberation time is unknown, with the reason, and stays so through later files and a save")
    func reverbUnknownAfterRepair() throws {
        let dir = TempDir()
        let (p, pool, _) = try setup(dir)
        #expect(Restoration.analyze(p, range: 0..<p.length, pool: pool).reverbUnknown == nil)
        let range: Range<Frame> = 48_000..<144_000
        let (q, _) = try Restoration.apply(.init(kind: .dehum), to: p, range: range, pool: pool, media: dir.file("Media"))
        #expect(q.sources.compactMap(\.repairs) == [["dehum"]])
        let a = Restoration.analyze(q, range: 0..<q.length, pool: pool)
        #expect(a.rt60 == nil && a.reverbUnknown == "after_noise_reduction" && !a.reverberant)
        // Only where the repaired sound is: a stretch that is still the original is measured as before.
        #expect(Restoration.analyze(q, range: 0..<40_000, pool: pool).reverbUnknown == nil)
        // A repair that doesn't leave tails of its own doesn't make it unknown…
        let (c, _) = try Restoration.apply(.init(kind: .declick), to: p, range: range, pool: pool, media: dir.file("Media"))
        #expect(c.sources.compactMap(\.repairs) == [["declick"]] && Restoration.analyze(c, range: 0..<c.length, pool: pool).reverbUnknown == nil)
        // …and one on top of the hum removal keeps what is under it.
        let (d, _) = try Restoration.apply(.init(kind: .declick), to: q, range: range, pool: pool, media: dir.file("Media"))
        #expect(d.sources.compactMap(\.repairs) == [["dehum", "declick"]])
        #expect(d.repairsCarried(by: d.tracks[0]) == ["dehum", "declick"])
        #expect(Restoration.analyze(d, range: 0..<d.length, pool: pool).reverbUnknown == "after_noise_reduction")
        // It is part of the project: there after a save and open, absent in projects saved before it existed.
        let back = try ProjectPackage.decode(try ProjectPackage.encode(d))
        #expect(back.sources.compactMap(\.repairs) == [["dehum", "declick"]])
        #expect(try ProjectPackage.decode(try ProjectPackage.encode(p)).sources.allSatisfy { $0.repairs == nil })
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
        // Inside, from its very start (the notches were warmed up before it): hum down a lot, voice kept.
        let left = stride(from: 48_000 * 2, to: 144_000 * 2, by: 2).map { out[$0] }
        let leftIn = stride(from: 48_000 * 2, to: 144_000 * 2, by: 2).map { original[$0] }
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

    @Test("Only the chosen tracks are repaired; analysis and preview see what's there and change nothing")
    func tracksAnalysisPreview() throws {
        let dir = TempDir()
        var (p, pool, original) = try setup(dir)
        // A second track playing a clean copy of the same file.
        let clean = dir.file("clean.wav")
        let n = original.count / 2
        try writeWAV((0..<n).flatMap { i -> [Float] in let t = Double(i) / sr; let v = Float(0.3 * sin(2 * .pi * 220 * t)); return [v, v] }, to: clean)
        let cleanRef = SourceRef(name: "clean", path: clean.path, info: try AudioFileReader.info(at: clean))
        p.sources.append(cleanRef)
        p.tracks.append(Track(name: "B", clips: [Clip(sourceID: cleanRef.id, start: 0, length: Frame(n))]))
        let a = p.tracks[0].id, b = p.tracks[1].id

        let onlyA = Restoration.analyze(p, range: 0..<p.length, tracks: [a], pool: pool)
        #expect(abs((onlyA.hum?.frequency ?? 0) - 60) < 0.05)
        #expect(onlyA.clippedRuns == 0 && onlyA.clicks == 0 && !onlyA.sampled)
        #expect(Restoration.analyze(p, range: 0..<p.length, tracks: [b], pool: pool).hum == nil)

        let (q, report) = try Restoration.apply(.init(kind: .dehum), to: p, tracks: [a], pool: pool, media: dir.file("Media"))
        #expect(report.clips == 1)
        #expect(q.tracks[1].clips == p.tracks[1].clips)
        #expect(q.tracks[0].clips[0].sourceID != p.tracks[0].clips[0].sourceID)

        let range: Range<Frame> = 48_000..<96_000
        let (_, audio) = try Restoration.preview(.init(kind: .dehum, humFrequency: 60), project: p, range: range, tracks: [a], pool: pool)
        #expect(audio.count == range.count * 2)
        // The project value passed in is unchanged: it still plays the originals.
        #expect(p.tracks[0].clips[0].sourceID == p.sources[0].id)
    }

    @Test("Long ranges are sampled so analysis stays quick")
    func sampledAnalysis() throws {
        let signal = [Float](repeating: 0.1, count: 48_000 * 2 * 120)
        let (p, pool) = memoryProject(signal)
        let a = Restoration.analyze(p, range: 0..<p.length, pool: pool, budget: 20)
        #expect(a.sampled && abs(a.examined - 20) < 0.1)
    }
}
