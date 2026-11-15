import Foundation
import Testing
@testable import JammerCore

@Suite("Diarisation")
struct DiarizationTests {
    let sr = 48_000.0

    /// Speech-like bursts: noise with a 4 Hz syllable envelope, inside `turns` (seconds).
    private func talker(_ turns: [(Double, Double)], seconds: Double, seed: UInt64) -> [Float] {
        let n = Int(seconds * sr)
        let w = noise(count: n, seed: seed)
        var out = [Float](repeating: 0, count: n)
        for (a, b) in turns {
            for i in Int(a * sr)..<min(n, Int(b * sr)) {
                let t = Double(i) / sr
                out[i] = w[i] * Float(0.15 * (0.55 + 0.45 * sin(2 * .pi * 4 * t)))
            }
        }
        return out
    }

    /// A double-ender: each track has its talker plus the other's bleed at -20 dB and a quiet floor.
    private func doubleEnder(_ dir: TempDir) throws -> (Project, SourcePool, [DiarizationScore.Segment]) {
        let seconds = 30.0
        let aTurns = [(1.0, 6.0), (9.5, 12.0), (15.0, 15.8), (20.0, 26.0)]
        let bTurns = [(5.5, 9.0), (12.4, 14.6), (16.0, 16.7), (24.5, 28.0)] // overlaps at 5.5-6 and 24.5-26
        let a = talker(aTurns, seconds: seconds, seed: 1), b = talker(bTurns, seconds: seconds, seed: 2)
        let floor = noise(count: a.count, seed: 3).map { $0 * 0.0003 }
        var p: Project?
        for (name, own, other) in [("Anna", a, b), ("Bo", b, a)] {
            let mono = (0..<own.count).map { own[$0] + 0.1 * other[$0] + floor[$0] }
            let url = dir.file("\(name).wav")
            try writeWAV(mono.flatMap { [$0, $0] }, to: url)
            let ref = SourceRef(name: name, path: url.path, info: try AudioFileReader.info(at: url))
            if p == nil { p = Project(source: ref) } else { p!.addTrack(source: ref) }
        }
        let reference = aTurns.map { DiarizationScore.Segment("Anna", $0.0, $0.1) } + bTurns.map { DiarizationScore.Segment("Bo", $0.0, $0.1) }
        return (p!, SourcePool(), reference)
    }

    @Test("DER is 0 for a perfect answer and counts misses, false alarms and confusion")
    func score() {
        let ref = [DiarizationScore.Segment("A", 0, 10), .init("B", 10, 20)]
        #expect(DiarizationScore.score(reference: ref, hypothesis: [.init("x", 0, 10), .init("y", 10, 20)]).der < 1e-9)
        let swapped = DiarizationScore.score(reference: ref, hypothesis: [.init("x", 0, 20)])
        #expect(abs(swapped.confusion - 0.5) < 0.01 && swapped.missed < 0.01)
        let half = DiarizationScore.score(reference: ref, hypothesis: [.init("x", 0, 10)])
        #expect(abs(half.missed - 0.5) < 0.01)
    }

    @Test("By track: each track is its speaker, bleed doesn't count, overlaps do")
    func byTrack() throws {
        let dir = TempDir()
        let (p, pool, reference) = try doubleEnder(dir)
        #expect(p.hasOverlappingTracks)
        let r = Diarization.byTrack(p, pool: pool, tracks: p.tracks.map(\.id))
        let hyp = r.flatMap { d in d.turns.map { DiarizationScore.Segment(d.names[$0.speaker], p.seconds($0.range.lowerBound), p.seconds($0.range.upperBound)) } }
        let s = DiarizationScore.score(reference: reference, hypothesis: hyp)
        print(String(format: "DIAR by_track DER %.1f%% (miss %.1f, FA %.1f, conf %.1f)", s.der * 100, s.missed * 100, s.falseAlarm * 100, s.confusion * 100))
        #expect(s.der < 0.05, "DER \(s.der): missed \(s.missed), false alarm \(s.falseAlarm), confusion \(s.confusion)")
        #expect(r.map(\.names) == [["Anna"], ["Bo"]])
    }

    @Test("Turns survive edits, label words, and rename; re-diarising replaces them")
    func storage() throws {
        let dir = TempDir()
        var (p, pool, _) = try doubleEnder(dir)
        let src = p.tracks[0].clips[0].sourceID
        p.setTranscript(SourceTranscript(sourceID: src, language: "sv-SE", engine: "t",
                                         words: [Word(text: "hej", start: Frame(2 * sr), end: Frame(2.4 * sr)),
                                                 Word(text: "tyst", start: Frame(7.5 * sr), end: Frame(7.8 * sr))]))
        p.applyDiarization(Diarization.byTrack(p, pool: pool, tracks: p.tracks.map(\.id)), engine: "by-track")
        #expect(p.speakers == ["Anna", "Bo"])
        #expect(p.transcripts[0].words.map(\.speaker) == [0, nil])
        let before = p.placedTurns().filter { $0.track == 0 }.first!
        try p.delete(0..<Frame(sr / 2)) // ripple: everything moves 0.5 s earlier
        let after = p.placedTurns().filter { $0.track == 0 }.first!
        #expect(after.start == before.start - Frame(sr / 2))
        try p.renameSpeaker("Anna", to: "Anna Andersson")
        try p.renameSpeaker("1", to: "Bo Berg")
        #expect(p.speakers == ["Anna Andersson", "Bo Berg"])
        #expect(throws: SpeakerError.self) { try p.renameSpeaker("Cecilia", to: "x") }
        // Again on track 1 only: its old speaker goes, Anna stays first.
        p.applyDiarization([TrackDiarization(track: p.tracks[1].id, names: ["Speaker 2"], turns: [.init(speaker: 0, range: 0..<Frame(sr))])], engine: "x")
        #expect(p.speakers == ["Anna Andersson", "Speaker 2"])
        #expect(abs((p.speakerSeconds()[1] ?? 0) - 1) < 0.001)
        // Saved and opened again.
        let back = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p))
        #expect(back.speakerTurns == p.speakerTurns && back.speakers == p.speakers)
    }

    @Test("16 kHz for the model: a 1 kHz tone keeps its level and pitch; 8 kHz is filtered away")
    func resampling() throws {
        let dir = TempDir()
        let x = (0..<Int(sr * 2)).map { i -> Float in
            let t = Double(i) / sr
            return Float(0.5 * sin(2 * .pi * 1_000 * t) + 0.5 * sin(2 * .pi * 9_000 * t))
        }
        let url = dir.file("t.wav")
        try writeWAV(x.flatMap { [$0, $0] }, to: url)
        let p = Project(source: SourceRef(name: "t", path: url.path, info: try AudioFileReader.info(at: url)))
        let y = try Diarization.mono16k(p, track: 0, pool: SourcePool())
        #expect(y.count == 32_000)
        // Correlate the middle with a 1 kHz sine at 16 kHz: amplitude 0.5 survives, 9 kHz is gone.
        var c = 0.0, s = 0.0, e = 0.0
        for i in 8_000..<24_000 {
            let t = Double(i) / 16_000
            c += Double(y[i]) * cos(2 * .pi * 1_000 * t)
            s += Double(y[i]) * sin(2 * .pi * 1_000 * t)
            e += Double(y[i] * y[i])
        }
        let amp = 2 * (c * c + s * s).squareRoot() / 16_000
        #expect(abs(amp - 0.5) < 0.01, "1 kHz amplitude \(amp)")
        let rms = (e / 16_000).squareRoot()
        #expect(abs(rms - 0.5 / 2.0.squareRoot()) < 0.01, "only the 1 kHz tone is left: rms \(rms)")
    }

    // MARK: Turns follow bounced audio

    /// Each speaker's turns on a track as merged timeline ranges (bounces split turns at clip edges).
    private func coverage(_ p: Project, track: Int) -> [Int: [Range<Frame>]] {
        var out: [Int: [Range<Frame>]] = [:]
        for t in p.placedTurns().filter({ $0.track == track }).sorted(by: { $0.start < $1.start }) {
            if let last = out[t.speaker]?.last, t.start <= last.upperBound + 1 {
                out[t.speaker]![out[t.speaker]!.count - 1] = last.lowerBound..<max(last.upperBound, t.end)
            } else {
                out[t.speaker, default: []].append(t.start..<t.end)
            }
        }
        return out
    }

    private func diarized(_ dir: TempDir) throws -> (Project, SourcePool) {
        var (p, pool, _) = try doubleEnder(dir)
        p.applyDiarization(Diarization.byTrack(p, pool: pool, tracks: p.tracks.map(\.id)), engine: "by-track")
        return (p, pool)
    }

    private func sameCoverage(_ a: [Int: [Range<Frame>]], _ b: [Int: [Range<Frame>]], tolerance: Frame = 0) -> Bool {
        guard a.keys.sorted() == b.keys.sorted() else { return false }
        return a.keys.allSatisfy { k in
            a[k]!.count == b[k]!.count && zip(a[k]!, b[k]!).allSatisfy { abs($0.lowerBound - $1.lowerBound) <= tolerance && abs($0.upperBound - $1.upperBound) <= tolerance }
        }
    }

    @Test("Turns move with a restoration's new file")
    func turnsThroughRestore() throws {
        let dir = TempDir()
        let (p, pool) = try diarized(dir)
        let before = (coverage(p, track: 0), coverage(p, track: 1))
        let (q, _) = try Restoration.apply(.init(kind: .dehum, humFrequency: 50), to: p, range: Frame(4 * sr)..<Frame(8 * sr), tracks: [p.tracks[0].id],
                                           pool: pool, media: dir.url.appending(path: "media"))
        #expect(q.sources.count > p.sources.count - 0 && q.tracks[0].clips.count == 3)
        #expect(sameCoverage(coverage(q, track: 0), before.0))
        #expect(sameCoverage(coverage(q, track: 1), before.1))
    }

    @Test("Turns move with echo's new file")
    func turnsThroughEcho() throws {
        let dir = TempDir()
        let (p, pool) = try diarized(dir)
        let before = coverage(p, track: 0)
        let q = try p.applyingEcho(Echo(delay: 0.2, feedback: 0.3, mix: 0.3), range: Frame(4 * sr)..<Frame(8 * sr), tracks: [p.tracks[0].id], tail: false,
                                   pool: pool, media: dir.url.appending(path: "media"))
        #expect(q.tracks[0].clips.count == 3)
        #expect(sameCoverage(coverage(q, track: 0), before))
    }

    @Test("Turns move with spectral attenuation's new file")
    func turnsThroughSpectral() throws {
        let dir = TempDir()
        let (p, pool) = try diarized(dir)
        let before = coverage(p, track: 0)
        let q = try p.applyingSpectralAttenuation(range: Frame(4 * sr)..<Frame(8 * sr), freq: 1_000...2_000, gainDB: -20, tracks: [p.tracks[0].id],
                                                  pool: pool, media: dir.url.appending(path: "media"))
        #expect(q.tracks[0].clips.count == 3)
        #expect(sameCoverage(coverage(q, track: 0), before))
    }

    @Test("Turns and words move with drift correction, stretched like the audio")
    func turnsThroughDrift() throws {
        let dir = TempDir()
        var (p, pool) = try diarized(dir)
        let src = p.tracks[1].clips[0].sourceID
        p.setTranscript(SourceTranscript(sourceID: src, language: "sv-SE", engine: "t", words: [Word(text: "ja", start: Frame(25 * sr), end: Frame(25.3 * sr))]))
        let before = coverage(p, track: 1)
        let q = try p.correctingDrift(of: p.tracks[1].id, ppm: 50, pool: pool, media: dir.url.appending(path: "media"))
        #expect(q.tracks[1].clips[0].sourceID != src)
        // 50 ppm over 30 s is 72 frames at most.
        #expect(sameCoverage(coverage(q, track: 1), before, tolerance: 80))
        let w = q.placedWords().first { $0.word.text == "ja" }
        #expect(w != nil && abs(w!.start - Frame(25 * sr)) <= 80 && w!.word.speaker == 1)
    }

    // MARK: Levelling

    @Test("Level speakers on one track: −30 and −20 LUFS come out together; words keep ids and times")
    func levelOneTrack() throws {
        let dir = TempDir()
        let seconds = 24.0
        let aTurns = [(1.0, 5.0), (9.0, 13.0), (17.0, 21.0)], bTurns = [(5.6, 8.4), (13.6, 16.4), (21.4, 23.5)]
        let a = talker(aTurns, seconds: seconds, seed: 11).map { $0 * 0.3 }   // about 10 dB quieter
        let b = talker(bTurns, seconds: seconds, seed: 12).map { $0 * 0.95 }
        let mono = zip(a, b).map { $0 + $1 }
        let url = dir.file("mix.wav")
        try writeWAV(mono.flatMap { [$0, $0] }, to: url)
        var p = Project(source: SourceRef(name: "mix", path: url.path, info: try AudioFileReader.info(at: url)))
        let pool = SourcePool()
        let src = p.sources[0].id
        p.setTranscript(SourceTranscript(sourceID: src, language: "sv-SE", engine: "t",
                                         words: [Word(text: "a", start: Frame(2 * sr), end: Frame(2.5 * sr)), Word(text: "b", start: Frame(6 * sr), end: Frame(6.4 * sr))]))
        let turns = aTurns.map { TrackDiarization.Turn(speaker: 0, range: Frame($0.0 * sr)..<Frame($0.1 * sr)) }
            + bTurns.map { TrackDiarization.Turn(speaker: 1, range: Frame($0.0 * sr)..<Frame($0.1 * sr)) }
        p.applyDiarization([TrackDiarization(track: p.tracks[0].id, names: ["A", "B"], turns: turns)], engine: "test")
        let before = p.speakerLoudness(pool: pool)
        #expect(abs((before[1] ?? 0) - (before[0] ?? 0)) > 8, "\(before)")
        let words = p.placedWords().map { ($0.word.id, $0.start, $0.end) }
        let placed = p.placedTurns().map { ($0.speaker, $0.start, $0.end) }
        let (q, report) = try p.levellingSpeakers(target: -20, pool: pool)
        let after = q.speakerLoudness(pool: pool)
        #expect(abs((after[0] ?? 0) - (after[1] ?? 0)) < 0.5, "after \(after)")
        #expect(abs((after[0] ?? 0) + 20) < 0.5)
        #expect(!report.limited && q.tracks[0].clips.count > 1)
        #expect(q.placedWords().map { ($0.word.id, $0.start, $0.end) }.elementsEqual(words, by: { $0 == $1 }))
        // Turns land in the same places (pieces may be split at clip edges; merge to compare).
        func merged(_ x: [(Int, Frame, Frame)]) -> [(Int, Frame, Frame)] {
            x.sorted { ($0.1, $0.0) < ($1.1, $1.0) }.reduce(into: []) { acc, t in
                if let l = acc.last, l.0 == t.0, t.1 <= l.2 { acc[acc.count - 1].2 = max(l.2, t.2) } else { acc.append(t) }
            }
        }
        #expect(merged(q.placedTurns().map { ($0.speaker, $0.start, $0.end) }).elementsEqual(merged(placed), by: { $0 == $1 }))
    }

    @Test("Level speakers by track: track gains; a track without speakers stays bit for bit")
    func levelByTrack() throws {
        let dir = TempDir()
        var (p, pool, _) = try doubleEnder(dir)
        // A third track nobody was found on.
        let url = dir.file("music.wav")
        try writeWAV(sine(220, amplitudeDB: -30, seconds: 30), to: url)
        p.addTrack(source: SourceRef(name: "music", path: url.path, info: try AudioFileReader.info(at: url)))
        p.tracks[1].gainDB = -8
        p.applyDiarization(Diarization.byTrack(p, pool: pool, tracks: [p.tracks[0].id, p.tracks[1].id]), engine: "by-track")
        var music = p
        music.tracks = [p.tracks[2]]
        let before = PlanCompiler.compile(music, pool: pool).render(from: 0, frames: Int(p.length))
        let (q, _) = try p.levellingSpeakers(target: -24, pool: pool)
        let after = q.speakerLoudness(pool: pool)
        #expect(abs((after[0] ?? 0) - (after[1] ?? 0)) < 0.5, "\(after)")
        #expect(q.tracks[0].clips == p.tracks[0].clips && q.tracks[1].clips == p.tracks[1].clips)
        #expect(q.tracks[0].gainDB != 0 && q.tracks[1].gainDB != -8)
        music.tracks = [q.tracks[2]]
        #expect(PlanCompiler.compile(music, pool: pool).render(from: 0, frames: Int(p.length)) == before)
        #expect(throws: LevelError.self) { try Project(sampleRate: sr, channels: 2).levellingSpeakers(pool: pool) }
    }

    // MARK: De-bleed

    /// Talker A and B on their own tracks, each with the other leaking in: delayed, filtered, at `leakDB`.
    private func leaky(_ dir: TempDir, delay: Double, leakDB: Double, band: ClosedRange<Double>) throws -> (Project, SourcePool, [(Double, Double)], [(Double, Double)]) {
        let seconds = 30.0
        let aTurns = [(1.0, 6.0), (11.0, 15.0), (21.0, 25.0)], bTurns = [(6.6, 10.5), (15.6, 20.5), (25.6, 29.0)]
        let a = talker(aTurns, seconds: seconds, seed: 21), b = talker(bTurns, seconds: seconds, seed: 22)
        func leak(_ x: [Float]) -> [Float] {
            // One-pole high- and low-pass for the band, then delay and level.
            let hp = Float(exp(-2 * .pi * band.lowerBound / sr)), lp = Float(exp(-2 * .pi * band.upperBound / sr))
            var y = [Float](repeating: 0, count: x.count), h: Float = 0, l: Float = 0, prev: Float = 0
            for i in x.indices {
                h = hp * (h + x[i] - prev); prev = x[i]
                l = (1 - lp) * h + lp * l
                y[i] = l
            }
            let d = Int(delay * sr), g = Float(pow(10, leakDB / 20))
            return (0..<x.count).map { $0 >= d ? y[$0 - d] * g : 0 }
        }
        let floor = noise(count: a.count, seed: 23).map { $0 * 0.0002 }
        var p: Project?
        for (name, own, other) in [("A", a, b), ("B", b, a)] {
            let l = leak(other)
            let mono = (0..<own.count).map { own[$0] + l[$0] + floor[$0] }
            let url = dir.file("\(name)-\(UUID().uuidString.prefix(4)).wav")
            try writeWAV(mono.flatMap { [$0, $0] }, to: url)
            let ref = SourceRef(name: name, path: url.path, info: try AudioFileReader.info(at: url))
            if p == nil { p = Project(source: ref) } else { p!.addTrack(source: ref) }
        }
        return (p!, SourcePool(), aTurns, bTurns)
    }

    private func trackLevel(_ p: Project, _ pool: SourcePool, track: Int, in spans: [(Double, Double)]) -> Double {
        var solo = p
        solo.tracks = [p.tracks[track]]
        let x = PlanCompiler.compile(solo, pool: pool).render(from: 0, frames: Int(p.length))
        var e = 0.0, n = 0
        for (a, b) in spans { for i in stride(from: Int((a + 0.3) * sr), to: Int((b - 0.3) * sr), by: 3) { e += Double(x[i * 2] * x[i * 2]); n += 1 } }
        return 10 * log10(e / Double(n))
    }

    @Test("Gate: the leak outside a track's own turns drops; its own speech stays bit for bit")
    func gate() throws {
        let dir = TempDir()
        var (p, pool, aTurns, bTurns) = try leaky(dir, delay: 0.003, leakDB: -20, band: 100...6_000)
        p.applyDiarization(Diarization.byTrack(p, pool: pool, tracks: p.tracks.map(\.id)), engine: "by-track")
        let before = trackLevel(p, pool, track: 0, in: bTurns)
        var soloA = p; soloA.tracks = [p.tracks[0]]
        let ownBefore = PlanCompiler.compile(soloA, pool: pool).render(from: Frame(2 * sr), frames: Int(3 * sr))
        let (q, report) = try p.debleeding(method: "gate", pool: pool, media: dir.file("m"))
        #expect(before - trackLevel(q, pool, track: 0, in: bTurns) >= 15, "gate \(report)")
        soloA = q; soloA.tracks = [q.tracks[0]]
        #expect(PlanCompiler.compile(soloA, pool: pool).render(from: Frame(2 * sr), frames: Int(3 * sr)) == ownBefore)
        _ = aTurns
        #expect(throws: DebleedError.noSpeakers) { try Project(sampleRate: sr, channels: 2).debleeding(method: "gate", pool: pool, media: dir.file("m")) }
    }

    @Test("Cancel, same room (3 ms, low-passed, −20 dB) and at a distance (180 ms, telephone band, −30 dB)",
          arguments: [(0.003, -20.0, 100.0...6_000.0), (0.18, -30.0, 300.0...3_400.0)])
    func cancel(delay: Double, leakDB: Double, band: ClosedRange<Double>) throws {
        let dir = TempDir()
        let (p, pool, aTurns, bTurns) = try leaky(dir, delay: delay, leakDB: leakDB, band: band)
        let bleed = trackLevel(p, pool, track: 0, in: bTurns), own = trackLevel(p, pool, track: 0, in: aTurns)
        let (q, report) = try p.debleeding(method: "cancel", tracks: [p.tracks[0].id], pool: pool, media: dir.file("m"))
        let bleedAfter = trackLevel(q, pool, track: 0, in: bTurns), ownAfter = trackLevel(q, pool, track: 0, in: aTurns)
        print(String(format: "DEBLEED delay %.0f ms: leak %.1f → %.1f dB (−%.1f), own voice %+.2f dB", delay * 1_000, bleed, bleedAfter, bleed - bleedAfter, ownAfter - own))
        #expect(bleed - bleedAfter >= 12, "\(report)")
        #expect(abs(ownAfter - own) <= 0.5)
    }

    // MARK: Dynamic levelling

    /// One speaker on one track; `gainAt` scales the talker over time. Plus a music track nobody talks on.
    private func riding(_ dir: TempDir, turns: [(Double, Double)], seconds: Double, gainAt: (Double) -> Float) throws -> (Project, SourcePool) {
        let x = talker(turns, seconds: seconds, seed: 31)
        let floor = noise(count: x.count, seed: 32).map { $0 * 0.0003 }
        let mono = x.indices.map { x[$0] * gainAt(Double($0) / sr) + floor[$0] }
        let url = dir.file("v.wav"), murl = dir.file("m.wav")
        try writeWAV(mono.flatMap { [$0, $0] }, to: url)
        try writeWAV(sine(330, amplitudeDB: -30, seconds: seconds), to: murl)
        var p = Project(source: SourceRef(name: "Voice", path: url.path, info: try AudioFileReader.info(at: url)))
        p.addTrack(source: SourceRef(name: "Music", path: murl.path, info: try AudioFileReader.info(at: murl)))
        p.applyDiarization([TrackDiarization(track: p.tracks[0].id, names: ["V"], turns: turns.map { .init(speaker: 0, range: Frame($0.0 * sr)..<Frame($0.1 * sr)) })], engine: "test")
        return (p, SourcePool())
    }

    private func loudness(_ p: Project, _ pool: SourcePool, track: Int, _ a: Double, _ b: Double) -> Double {
        var solo = p
        solo.tracks = [p.tracks[track]]
        return LoudnessMeter.measure(PlanCompiler.compile(solo, pool: pool), Frame(a * sr)..<Frame(b * sr)).integrated ?? -99
    }

    @Test("Dynamic: a speaker who drops 8 dB halfway comes out even; the music track is untouched")
    func dynamicHalves() throws {
        let dir = TempDir()
        let turns = [(1.0, 8.0), (9.0, 16.0), (17.0, 24.0), (25.0, 32.0)]
        let (p, pool) = try riding(dir, turns: turns, seconds: 33) { $0 < 16.5 ? 1 : 0.4 }
        var music = p; music.tracks = [p.tracks[1]]
        let mBefore = PlanCompiler.compile(music, pool: pool).render(from: 0, frames: Int(p.length))
        let (q, report) = try p.levellingSpeakersDynamically(target: -20, pool: pool, media: dir.file("m"))
        let first = loudness(q, pool, track: 0, 2, 15), second = loudness(q, pool, track: 0, 18, 31)
        print(String(format: "LEVEL halves %.2f / %.2f LUFS, spread %.1f → %.1f LU", first, second, report.spreadBefore, report.spreadAfter))
        #expect(abs(first + 20) <= 1 && abs(second + 20) <= 1)
        #expect(report.spreadAfter < report.spreadBefore)
        music = q; music.tracks = [q.tracks[1]]
        #expect(PlanCompiler.compile(music, pool: pool).render(from: 0, frames: Int(p.length)) == mBefore)
    }

    @Test("Dynamic: the voice keeps its own rhythm, and a pause isn't lifted")
    func dynamicShape() throws {
        let dir = TempDir()
        let turns = [(1.0, 8.0), (11.0, 18.0)]
        let (p, pool) = try riding(dir, turns: turns, seconds: 19) { _ in 0.25 }
        let (q, _) = try p.levellingSpeakersDynamically(target: -18, pool: pool, media: dir.file("m"))
        func depth(_ x: Project) -> Double {
            var solo = x; solo.tracks = [x.tracks[0]]
            let y = PlanCompiler.compile(solo, pool: pool).render(from: Frame(4 * sr), frames: Int(sr))
            let frame = Int(sr * 0.025)
            let rms = stride(from: 0, to: y.count / 2 - frame, by: frame).map { s in (s..<(s + frame)).map { Double(y[$0 * 2] * y[$0 * 2]) }.reduce(0, +) }
            return 10 * log10(rms.max()! / rms.min()!)
        }
        #expect(abs(depth(q) - depth(p)) <= 1, "modulation \(depth(p)) → \(depth(q)) dB")
        let speechGain = loudness(q, pool, track: 0, 6.5, 7.8) - loudness(p, pool, track: 0, 6.5, 7.8)
        func rms(_ x: Project, _ a: Double, _ b: Double) -> Double {
            var solo = x; solo.tracks = [x.tracks[0]]
            let y = PlanCompiler.compile(solo, pool: pool).render(from: Frame(a * sr), frames: Int((b - a) * sr))
            return 10 * log10(y.map { Double($0 * $0) }.reduce(0, +) / Double(y.count))
        }
        let pauseGain = rms(q, 8.6, 10.4) - rms(p, 8.6, 10.4)
        #expect(pauseGain <= speechGain + 0.2, "pause \(pauseGain) dB vs speech \(speechGain) dB")
    }

    @Test("Dynamic: speech after a long pause, 6 dB louder, doesn't overshoot in its first second")
    func dynamicAfterPause() throws {
        let dir = TempDir()
        let turns = [(1.0, 8.0), (15.0, 22.0)]
        let (p, pool) = try riding(dir, turns: turns, seconds: 23) { $0 < 11 ? 0.2 : 0.4 }
        let (q, _) = try p.levellingSpeakersDynamically(target: -20, pool: pool, media: dir.file("m"))
        let onset = loudness(q, pool, track: 0, 15.0, 16.0)
        print(String(format: "LEVEL first second after the pause: %.2f LUFS (target -20)", onset))
        #expect(onset <= -18, "overshoot \(onset + 20) dB")
        #expect(abs(loudness(q, pool, track: 0, 16, 21.5) + 20) <= 1)
    }

    @Test("A double-ender's transcript shows each line once: the other person's bleed isn't repeated")
    func bleedWords() throws {
        let dir = TempDir()
        var (p, pool, _) = try doubleEnder(dir)
        // Both microphones heard both people: A talks at 2 s, B at 7 s (see doubleEnder's turns).
        for t in 0..<2 {
            p.setTranscript(SourceTranscript(sourceID: p.tracks[t].clips[0].sourceID, language: "en", engine: "t",
                                             words: [Word(text: "hello", start: Frame(2 * sr), end: Frame(2.4 * sr)), Word(text: "there", start: Frame(7 * sr), end: Frame(7.4 * sr))]))
        }
        #expect(p.placedWords().count == 4)
        p.applyDiarization(Diarization.byTrack(p, pool: pool, tracks: p.tracks.map(\.id)), engine: "by-track")
        let w = p.placedWords()
        #expect(w.map(\.word.text) == ["hello", "there"])
        #expect(w.map(\.track) == [0, 1] && w.map(\.word.speaker) == [0, 1])
    }
}
