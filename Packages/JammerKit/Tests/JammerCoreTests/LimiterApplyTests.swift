import Foundation
import Testing
@testable import JammerCore

@Suite("Limiter on a document")
struct LimiterApplyTests {
    static let n = 48_000 * 6
    /// Two tracks, each under the ceiling alone, together over it between 2 s and 4 s:
    /// a steady tone at 0.55, and a second at 0.6 that only sounds from 2 s to 4 s.
    static func document() -> (Project, SourcePool) {
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: Int64(n), chunks: [], bext: nil, ixml: nil, markers: [])
        let a = SourceRef(name: "voice", path: "/dev/null", info: info), b = SourceRef(name: "music", path: "/dev/null", info: info)
        let pool = SourcePool()
        pool.register(a.id, memory: (0..<n).flatMap { i -> [Float] in let v = Float(0.55 * sin(Double(i) * 0.031)); return [v, v] }, channels: 2)
        pool.register(b.id, memory: (0..<n).flatMap { i -> [Float] in let v = i >= 96_000 && i < 192_000 ? Float(0.6 * sin(Double(i) * 0.047)) : 0; return [v, v] }, channels: 2)
        var p = Project(source: a)
        _ = p.addTrack(source: b, name: "Music")
        p.setTranscript(SourceTranscript(sourceID: a.id, language: "sv-SE", engine: "x", words: [Word(text: "hej", start: 100_000, end: 110_000)]))
        return (p, pool)
    }
    static func render(_ p: Project, _ pool: SourcePool) -> [Float] { PlanCompiler.compile(p, pool: pool).render(from: 0, frames: Int(p.length)) }
    static func peak(_ x: [Float]) -> Double { var m = Limiter.PeakMeter(channels: 2, sampleRate: 48_000); m.process(x); return m.peakDB }
    func folder() -> URL { FileManager.default.temporaryDirectory.appending(path: "jammer-limit-\(UUID().uuidString)") }

    @Test("The mix comes under the ceiling; what needed nothing is the old audio bit for bit; nothing moves")
    func mix() throws {
        let (p, pool) = Self.document()
        let media = folder()
        defer { try? FileManager.default.removeItem(at: media) }
        let old = Self.render(p, pool)
        // Each track alone is under −1 dBTP (0.55 → −5.2, 0.6 → −4.4); together they reach +1.2.
        #expect(Self.peak(old) > 0)
        let (q, report) = try p.limiting(Limiter(ceilingDB: -1), range: 0..<p.length, pool: pool, media: media)
        let new = Self.render(q, pool)
        #expect(Self.peak(new) <= -1.0 && abs(report.truePeakAfterDB - Self.peak(new)) < 0.01, "\(Self.peak(new)) \(report)")
        #expect(abs(report.truePeakBeforeDB - Self.peak(old)) < 0.01 && report.tracks == 2 && report.ceilingDB == -1 && !report.beforePlugins)
        #expect(report.reductionMaxDB > 1.5 && report.reductionMaxDB < 3.5 && report.limitedSeconds > 1.9 && report.limitedSeconds < 3.5)
        // Same length, and the first second and the last (far from the loud part) null against the old mix.
        #expect(new.count == old.count && q.length == p.length)
        #expect(new[0..<(48_000 * 2)] == old[0..<(48_000 * 2)] && new[(48_000 * 5 * 2)...] == old[(48_000 * 5 * 2)...])
        // In the loud part the new mix is the old one times one gain for both tracks: the ratio between
        // the channels and the tone's zero crossings stay where they were (nothing is delayed).
        let k = 120_000 * 2
        #expect(new[k] != old[k] && abs(new[k] / old[k] - new[k + 2_000] / old[k + 2_000]) < 0.2)
        var crossings = 0
        for i in 100_000..<180_000 where (old[i * 2] > 0) != (old[i * 2 + 2] > 0) { crossings += 1; #expect((new[i * 2] > 0) != (new[i * 2 + 2] > 0) || new[i * 2] == 0 || new[i * 2 + 2] == 0) }
        #expect(crossings > 100)
        // Each track plays one new file over the range; the word came along; the sources are untouched and one value back.
        #expect(q.tracks.allSatisfy { $0.clips.count == 1 } && q.placedWords().map(\.word.text) == ["hej"] && q.placedWords()[0].start == 100_000)
        #expect(Self.render(p, pool) == old)
    }

    @Test("A range in the middle: outside it, bit for bit; one track only: the other is not touched")
    func rangeAndTracks() throws {
        let (p, pool) = Self.document()
        let media = folder()
        defer { try? FileManager.default.removeItem(at: media) }
        let old = Self.render(p, pool)
        let r = Frame(48_000 * 2)..<Frame(48_000 * 3)
        let (q, report) = try p.limiting(Limiter(ceilingDB: -1), range: r, pool: pool, media: media)
        let new = Self.render(q, pool)
        #expect(new[0..<(96_000 * 2)] == old[0..<(96_000 * 2)] && new[(144_000 * 2)...] == old[(144_000 * 2)...])
        #expect(Self.peak(Array(new[(96_000 * 2)..<(144_000 * 2)])) <= -1.0 && report.limitedSeconds <= 1.0)
        #expect(q.tracks[0].clips.count == 3 && q.tracks[1].clips.count == 3)
        // Only the music, with a ceiling under its own peak: the voice keeps its clip, and the report says one track.
        let (m, one) = try p.limiting(Limiter(ceilingDB: -6), range: 0..<p.length, tracks: [p.tracks[1].id], pool: pool, media: media)
        #expect(one.tracks == 1 && m.tracks[0] == p.tracks[0] && m.tracks[1] != p.tracks[1] && one.truePeakAfterDB <= -6)
    }

    @Test("Refused in words: already under the ceiling, nothing in the range, values out of range")
    func refusals() throws {
        let (p, pool) = Self.document()
        let media = folder()
        defer { try? FileManager.default.removeItem(at: media) }
        #expect(throws: LimiterError.self) { _ = try p.limiting(Limiter(ceilingDB: -1), range: 0..<48_000, pool: pool, media: media) }
        do { _ = try p.limiting(Limiter(ceilingDB: -1), range: 0..<48_000, pool: pool, media: media) } catch {
            #expect(error.localizedDescription.contains("already at or under the ceiling") && error.localizedDescription.contains("Nothing was changed"))
        }
        #expect(throws: EffectError.nothingInRange) { _ = try p.limiting(Limiter(), range: 0..<p.length, tracks: [UUID()], pool: pool, media: media) }
        for bad in [Limiter(ceilingDB: 1), Limiter(ceilingDB: .nan), Limiter(releaseMs: 0), Limiter(releaseMs: .infinity), Limiter(lookaheadMs: 100), Limiter(ceilingDB: -200)] {
            #expect(throws: LimiterError.self) { _ = try p.limiting(bad, range: 0..<p.length, pool: pool, media: media) }
        }
        // Nothing was written for any of them.
        #expect((try? FileManager.default.contentsOfDirectory(atPath: media.path))?.isEmpty ?? true)
    }
}

@Suite("A loudness preset with the limiter")
struct LoudnessMatchTests {
    /// 20 s: a steady tone at −26 dBFS with a loud burst (−2 dBFS) for 5 ms every second: quiet on
    /// average, with peaks that stop a plain gain far short of −14 LUFS.
    static func document() -> (Project, SourcePool) {
        let n = 48_000 * 20
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: Int64(n), chunks: [], bext: nil, ixml: nil, markers: [])
        let a = SourceRef(name: "peaky", path: "/dev/null", info: info)
        let pool = SourcePool()
        pool.register(a.id, memory: (0..<n).flatMap { i -> [Float] in
            let amp = i % 48_000 < 240 ? 0.79 : 0.05
            let v = Float(amp * sin(Double(i) * 0.13))
            return [v, v]
        }, channels: 2)
        return (Project(source: a), pool)
    }
    static func measure(_ pool: SourcePool) -> (Project, Range<Frame>) -> LoudnessResult {
        { p, r in LoudnessMeter.measure(PlanCompiler.compile(p, pool: pool), r) }
    }

    @Test("Without the limiter the peaks stop it short; with it the target is reached, the ceiling holds, and the cost is said")
    func reaches() throws {
        let (p, pool) = Self.document()
        let media = FileManager.default.temporaryDirectory.appending(path: "jammer-match-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: media) }
        let all = 0..<p.length
        let (_, plain) = try #require(try p.matching(.spotify, range: all, limit: false, pool: pool, media: media, measure: Self.measure(pool)))
        #expect(plain.limitedByPeak && !plain.limited && plain.integratedAfter < -15 && plain.truePeakAfter <= -0.99)
        let (q, m) = try #require(try p.matching(.spotify, range: all, limit: true, pool: pool, media: media, measure: Self.measure(pool)))
        let after = Self.measure(pool)(q, all)
        #expect(m.limited && !m.limitedByPeak && abs(m.integratedAfter - -14) <= 0.1 && abs((after.integrated ?? 0) - -14) <= 0.1, "\(m)")
        #expect(after.truePeak <= -1.0 && m.truePeakAfter <= -1.0 && m.reductionMaxDB > 3 && m.limitedSeconds > 1)
        // What it took is in the answer: the reduction, and the loudness range before and after (this
        // signal repeats every second, so its range is next to nothing both times; the figures are there).
        #expect(m.rangeBefore != nil && m.rangeAfter != nil && abs((m.rangeAfter ?? 9) - (after.range ?? 0)) < 0.001)
        // Only the last try's files are left.
        #expect(try FileManager.default.contentsOfDirectory(atPath: media.path).count == 1 && q.length == p.length)
        // Peaks that leave room: one gain as before, and the limiter isn't touched even when allowed.
        let (_, easy) = try #require(try p.matching(.ebuR128, range: all, limit: true, pool: pool, media: media, measure: Self.measure(pool)))
        #expect(!easy.limited && !easy.limitedByPeak && abs(easy.integratedAfter - -23) < 0.01)
    }

    @Test("RMS: a full-scale sine reads −3.01 dB, half scale −9.03, silence nothing")
    func rms() {
        func rms(_ amp: Double) -> Double? {
            var m = LoudnessMeter(sampleRate: 48_000, channels: 2)
            m.process((0..<48_000).flatMap { i -> [Float] in let v = Float(amp * sin(2 * .pi * 1_000 * Double(i) / 48_000)); return [v, v] })
            return m.result.rms
        }
        #expect(abs((rms(1) ?? 0) - -3.0103) < 0.001 && abs((rms(0.5) ?? 0) - -9.0309) < 0.001 && rms(0) == nil)
        // Results saved before the figure existed still read.
        let old = try? JSONDecoder().decode(LoudnessResult.self, from: Data(#"{"integrated":-16,"range":3,"samplePeak":-1,"truePeak":-1,"duration":2}"#.utf8))
        #expect(old != nil && old?.rms == nil)
    }
}
