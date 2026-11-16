import Foundation
import Testing
@testable import JammerCore

@Suite("Ducking")
struct DuckingTests {
    let sr = 48_000.0
    /// Where the "speech" is, in seconds: two bursts 0.3 s apart, and one after a longer pause.
    let bursts: [(Double, Double)] = [(2.0, 4.0), (4.3, 6.0), (8.0, 9.0)]

    /// Track 0 "Speech": a 300 Hz tone at −20 dBFS in the bursts, nothing between. Track 1 "Music": 440 Hz at −12 dBFS for 12 s.
    func setup() -> (Project, SourcePool, music: [Float]) {
        let n = Int(12 * sr)
        var speech = [Float](repeating: 0, count: n * 2)
        for (a, b) in bursts {
            for i in Int(a * sr)..<Int(b * sr) {
                let v = Float(0.1 * sin(2 * .pi * 300 * Double(i) / sr))
                speech[i * 2] = v; speech[i * 2 + 1] = v
            }
        }
        let music = sine(440, amplitudeDB: -12, seconds: 12)
        var (p, pool) = memoryProject(speech)
        p.tracks[0].name = "Speech"
        var info = p.sources[0].info
        info.frames = Int64(n)
        let ref = SourceRef(name: "music", path: "/dev/null", info: info)
        pool.register(ref.id, memory: music, channels: 2)
        p.sources.append(ref)
        p.tracks.append(Track(name: "Music", clips: [Clip(sourceID: ref.id, start: 0, length: Frame(n))]))
        return (p, pool, music)
    }

    func heard(_ p: Project, track: Int, _ pool: SourcePool) -> [Float] {
        var solo = p
        solo.tracks = [p.tracks[track]]
        return PlanCompiler.compile(solo, pool: pool).render(from: 0, frames: Int(p.length))
    }

    /// The change in dB at `seconds` (left channel, over 20 ms from there).
    func change(_ out: [Float], _ ref: [Float], at seconds: Double) -> Double {
        let i = Int(seconds * sr), n = Int(0.02 * sr)
        func power(_ x: [Float]) -> Double { (i..<(i + n)).reduce(0.0) { $0 + Double(x[$1 * 2]) * Double(x[$1 * 2]) } }
        return 10 * log10(power(out) / power(ref))
    }

    func same(_ a: [Float], _ b: [Float], _ from: Double, _ to: Double) -> Bool {
        let r = (Int(from * sr) * 2)..<(Int(to * sr) * 2)
        return a[r] == b[r]
    }

    @Test("By level: down by the amount under the speech, before the first word, up in a long pause and held through a short one, untouched elsewhere")
    func byLevel() throws {
        let dir = TempDir()
        let (p, pool, music) = setup()
        let (q, report) = try p.ducking(tracks: [p.tracks[1].id], pool: pool, media: dir.file("m"))
        // Two stretches: the bursts 0.3 s apart are one (the hold is 0.4 s), the one after 2 s of pause another.
        #expect(report == DuckReport(tracks: 1, regions: 2, duckedSeconds: report.duckedSeconds, trigger: "level", replaced: 0))
        // The level is read in 100 ms blocks with their neighbours, so a stretch is found up to 100 ms wide of the sound.
        #expect(abs(report.duckedSeconds - (4.0 + 0.4 + 1.0 + 0.4)) <= 0.45, "\(report.duckedSeconds)")
        let out = heard(q, track: 1, pool)
        #expect(out.count == music.count)
        for t in [2.0, 3.0, 4.1, 5.0, 5.9, 6.2, 8.0, 8.5, 9.2] { #expect(abs(change(out, music, at: t) + 12) < 0.1, "at \(t): \(change(out, music, at: t))") }
        // Already all the way down when the first word starts, and on its way 100 ms before.
        #expect(change(out, music, at: 1.98) < -11.9 && change(out, music, at: 1.7) > -0.01 && change(out, music, at: 1.82) < -3)
        // Up again 0.6 s after the hold; bit for bit the music before, between and after.
        #expect(same(out, music, 0, 1.7) && same(out, music, 7.25, 7.7) && same(out, music, 10.25, 12))
        #expect(change(out, music, at: 6.85) < -2 && change(out, music, at: 6.85) > -10)
        // The speech track isn't touched, the project's length is the same, and the music is one new file.
        #expect(heard(q, track: 0, pool) == heard(p, track: 0, pool) && q.length == p.length)
        #expect(q.tracks[1].clips.count == 1 && q.sources.count == 3 && q.sources.contains { $0.name == "Music (ducked)" })
        #expect(q.tracks[1].ducked?.clips == p.tracks[1].clips)
    }

    @Test("By speakers' turns when there are any: exact to the frame, and said in the report")
    func byTurns() throws {
        let dir = TempDir()
        var (p, pool, music) = setup()
        p.speakerTurns = [SourceSpeakers(sourceID: p.tracks[0].clips[0].sourceID, engine: "test",
                                         turns: bursts.map { SpeakerTurn(speaker: 0, start: Frame($0.0 * sr), end: Frame($0.1 * sr)) })]
        var s = Ducking.Settings()
        s.amountDB = -20
        s.attackMs = 100
        s.lookaheadMs = 100
        s.releaseMs = 200
        s.holdMs = 0
        let (q, report) = try p.ducking(tracks: [p.tracks[1].id], under: [p.tracks[0].id], settings: s, pool: pool, media: dir.file("m"))
        // No hold: three stretches, of exactly the turns' lengths.
        #expect(report.trigger == "turns" && report.regions == 3 && report.duckedSeconds == 4.7)
        let out = heard(q, track: 1, pool)
        func gain(_ frame: Int) -> Double { Double(out[frame * 2]) / Double(music[frame * 2]) }
        let start = Int(2.0 * sr)
        // Untouched until 100 ms before the turn, half way down (in dB) 50 ms before, all the way at its first frame.
        #expect(out[(start - 4_800 - 1) * 2] == music[(start - 4_800 - 1) * 2])
        #expect(abs(20 * log10(gain(start - 2_399)) + 10) < 0.01 && abs(20 * log10(gain(start + 1)) + 20) < 0.001)
        // Up over 200 ms after the turn ends: half way (in dB) after 100 ms, the music itself at 200 ms,
        // which is the very frame the next turn's ducking starts from (it begins 100 ms before 4.3 s).
        let end = Int(4.0 * sr)
        #expect(abs(20 * log10(gain(end + 4_801)) + 10) < 0.01 && out[(end + 9_600) * 2] == music[(end + 9_600) * 2])
        #expect(same(out, music, 6.21, 7.89) && same(out, music, 9.21, 12))
    }

    @Test("Ducking again replaces the earlier ducking; stack adds to it; an edit in between makes it a new start")
    func againAndStack() throws {
        let dir = TempDir()
        let (p, pool, music) = setup()
        let id = p.tracks[1].id
        let (once, _) = try p.ducking(tracks: [id], pool: pool, media: dir.file("m"))
        var s = Ducking.Settings()
        s.amountDB = -6
        let (again, r2) = try once.ducking(tracks: [id], settings: s, pool: pool, media: dir.file("m"))
        #expect(r2.replaced == 1 && abs(change(heard(again, track: 1, pool), music, at: 3) + 6) < 0.1)
        // The first ducking's file is no longer part of the project; the original still is, for next time.
        #expect(again.sources.count == 3 && again.tracks[1].ducked?.clips == p.tracks[1].clips)
        s.stack = true
        let (stacked, r3) = try once.ducking(tracks: [id], settings: s, pool: pool, media: dir.file("m"))
        #expect(r3.replaced == 0 && abs(change(heard(stacked, track: 1, pool), music, at: 3) + 18) < 0.1)
        // After stacking, a plain ducking still goes back to the sound from before the first.
        s.stack = false
        s.amountDB = -3
        let (back, r4) = try stacked.ducking(tracks: [id], settings: s, pool: pool, media: dir.file("m"))
        #expect(r4.replaced == 1 && abs(change(heard(back, track: 1, pool), music, at: 3) + 3) < 0.1)
        // Cut the ducked track, and it is no longer "the ducked file": the next ducking works on what is there.
        var cut = once
        cut.split(at: Frame(5 * sr))
        let (fresh, r5) = try cut.ducking(tracks: [id], pool: pool, media: dir.file("m"))
        #expect(r5.replaced == 0 && abs(change(heard(fresh, track: 1, pool), music, at: 3) + 24) < 0.1)
        // Saved and opened, the project still knows; a stored original that points outside its file is dropped.
        let saved = try ProjectPackage.decode(try ProjectPackage.encode(once))
        #expect(saved.tracks[1].ducked == once.tracks[1].ducked)
        var bad = once
        bad.tracks[1].ducked?.clips[0].sourceStart = 1 << 40
        _ = try ProjectSafety.check(&bad)
        #expect(bad.tracks[1].ducked == nil && bad.tracks[1].clips == once.tracks[1].clips)
        var fine = once
        _ = try ProjectSafety.check(&fine)
        #expect(fine.tracks[1].ducked == once.tracks[1].ducked)
    }

    @Test("What can't be ducked says why and changes nothing; a range limits where")
    func refusalsAndRange() throws {
        let dir = TempDir()
        let (p, pool, music) = setup()
        let speech = p.tracks[0].id, id = p.tracks[1].id
        #expect(throws: DuckError.overlap("Music")) { try p.ducking(tracks: [id], under: [id], pool: pool, media: dir.file("m")) }
        let missing = UUID()
        #expect(throws: DuckError.notFound(missing.uuidString)) { try p.ducking(tracks: [missing], pool: pool, media: dir.file("m")) }
        #expect(throws: DuckError.notFound(missing.uuidString)) { try p.ducking(tracks: [id], under: [missing], pool: pool, media: dir.file("m")) }
        var alone = p
        alone.tracks.remove(at: 0)
        #expect(throws: DuckError.needsTracks) { try alone.ducking(tracks: [id], pool: pool, media: dir.file("m")) }
        var muted = p
        muted.tracks[0].isMuted = true
        #expect(throws: DuckError.needsTracks) { try muted.ducking(tracks: [id], pool: pool, media: dir.file("m")) }
        // Nothing over the threshold in the range: an error, not a file that is the same as before.
        #expect(throws: DuckError.noSpeech) { try p.ducking(tracks: [id], range: Frame(10 * sr)..<Frame(12 * sr), pool: pool, media: dir.file("m")) }
        var high = Ducking.Settings()
        high.threshold = -10
        #expect(throws: DuckError.noSpeech) { try p.ducking(tracks: [id], settings: high, pool: pool, media: dir.file("m")) }
        // The music under the speech, the other way round: the tone is far over the threshold all the time.
        let (reverse, r) = try p.ducking(tracks: [speech], under: [id], pool: pool, media: dir.file("m"))
        #expect(r.regions == 1 && abs(change(heard(reverse, track: 0, pool), heard(p, track: 0, pool), at: 3) + 12) < 0.1)
        // A range: only the speech inside it counts.
        let (late, r2) = try p.ducking(tracks: [id], range: Frame(7 * sr)..<Frame(12 * sr), pool: pool, media: dir.file("m"))
        let out = heard(late, track: 1, pool)
        #expect(r2.regions == 1 && same(out, music, 0, 7.7) && abs(change(out, music, at: 8.5) + 12) < 0.1)
    }

    @Test("The envelope: joined by the hold, the deeper of two overlapping ramps, nothing outside")
    func envelope() {
        #expect(Ducking.regions([10..<20, 25..<30, 100..<110], hold: 5) == [10..<35, 100..<115])
        #expect(Ducking.regions([10..<20, 26..<30], hold: 5) == [10..<25, 26..<35])
        #expect(Ducking.regions([], hold: 5).isEmpty)
        let w = Ducking.depth(0..<60, regions: [20..<30], attack: 10, release: 10, lookahead: 10)
        #expect(w[9] == 0 && w[10] == 0 && w[15] == 0.5 && w[20] == 1 && w[29] == 1 && w[35] == 0.5 && w[40] == 0 && w[59] == 0)
        // Asked for in pieces, it is the same curve.
        let whole = Ducking.depth(0..<200, regions: [20..<30, 38..<50, 150..<160], attack: 10, release: 20, lookahead: 4)
        let pieces = Ducking.depth(0..<37, regions: [20..<30, 38..<50, 150..<160], attack: 10, release: 20, lookahead: 4)
            + Ducking.depth(37..<200, regions: [20..<30, 38..<50, 150..<160], attack: 10, release: 20, lookahead: 4)
        #expect(whole == pieces && whole.allSatisfy { $0 >= 0 && $0 <= 1 })
        // With less lookahead than attack it is still on its way down when the region starts.
        #expect(whole[150] == 0.4 && whole[156] == 1)
    }
}
