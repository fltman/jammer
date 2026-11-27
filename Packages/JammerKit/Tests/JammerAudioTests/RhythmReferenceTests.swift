import Foundation
import JammerCore
import Testing
@testable import JammerAudio

/// Tempo detection against sound whose tempo is known, and against sound that has none.
/// These run the system's own analysis (MusicUnderstanding), so they are the reference for what
/// Jämmer shows: docs/TEMPO.md has the table.
@Suite("Tempo against references", .serialized)
struct RhythmReferenceTests {
    let sr = 48_000.0

    init() { MusicRhythm.register() }

    /// Clicks (a short tone burst on every beat, the first of four louder) or drums (a kick on every beat, noise on 2 and 4).
    func beats(bpm: Double, seconds: Double = 30, offset: Double = 0, drums: Bool = false) -> [Float] {
        let n = Int(seconds * sr)
        var x = [Float](repeating: 0, count: n)
        var seed: UInt64 = 1
        var k = 0
        while offset + Double(k) * 60 / bpm < seconds {
            let s = Int((offset + Double(k) * 60 / bpm) * sr)
            for i in 0..<Int(0.06 * sr) where s + i < n {
                let t = Double(i) / sr
                var v: Double
                if drums {
                    v = exp(-t / 0.03) * sin(2 * .pi * (60 + 80 * exp(-t / 0.01)) * t) * 0.8
                    if k % 2 == 1 {
                        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                        v += exp(-t / 0.008) * Double(Int32(truncatingIfNeeded: seed >> 32)) / 2_147_483_648 * 0.4
                    }
                } else {
                    v = exp(-t / 0.008) * sin(2 * .pi * (k % 4 == 0 ? 1_500 : 1_000) * t) * (k % 4 == 0 ? 0.8 : 0.5)
                }
                x[s + i] += Float(v)
            }
            k += 1
        }
        return x
    }

    func project(_ mono: [Float], in dir: URL, name: String = "a.wav") throws -> (Project, SourcePool) {
        let url = dir.appending(path: name)
        let w = try WAVWriter(url: url, options: .init(encoding: .float32, channels: 1, sampleRate: sr))
        try w.write(mono)
        try w.finish()
        return (Project(source: SourceRef(name: "a", path: url.path, info: try AudioFileReader.info(at: url))), SourcePool())
    }

    func folder() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "jammer-tempo-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test("Known tempi are found to a tenth of a beat per minute, and the first beat to 20 ms",
          arguments: [(120.0, 0.0, false), (93.0, 0.25, false), (140.0, 0.1, true), (72.0, 0.0, true), (100.0, 0.4, true)])
    func known(bpm: Double, offset: Double, drums: Bool) throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (p, pool) = try project(beats(bpm: bpm, offset: offset, drums: drums), in: dir)
        let e = try Rhythm.estimate(p, range: 0..<p.length, pool: pool)
        #expect(abs(e.bpm - bpm) <= 0.1, "\(e.bpm) for \(bpm)")
        // The first beat, as a place in the beat: the tracker may start counting a beat or two in.
        let period = 60 / bpm
        let off = (e.firstBeat - offset).truncatingRemainder(dividingBy: period)
        #expect(min(abs(off), period - abs(off)) <= 0.02, "first beat \(e.firstBeat) for \(offset)")
        #expect(e.pulse >= 0.5 && e.alternatives.count == 2 && e.beats.count > 20)
        // From the middle of the file: the same tempo, and beats that still land on the clicks.
        let (q, _) = (p, pool)
        let from = Frame(7.3 * sr)
        let late = try Rhythm.estimate(q, range: from..<q.length, pool: pool)
        #expect(abs(late.bpm - bpm) <= 0.1)
        let place = (7.3 + late.firstBeat - offset).truncatingRemainder(dividingBy: period)
        #expect(min(abs(place), period - abs(place)) <= 0.02, "from 7.3 s: first beat \(late.firstBeat)")
    }

    @Test("A fast tempo comes back at half speed, and the alternatives hold the right one")
    func octave() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (p, pool) = try project(beats(bpm: 174), in: dir)
        let e = try Rhythm.estimate(p, range: 0..<p.length, pool: pool)
        #expect(abs(e.bpm - 87) <= 0.1 && e.alternatives.contains { abs($0 - 174) <= 0.2 })
        let doubled = try Rhythm.estimate(p, range: 0..<p.length, pool: pool, multiply: 2)
        #expect(abs(doubled.bpm - 174) <= 0.2 && doubled.alternatives.contains { abs($0 - 87) <= 0.1 })
    }

    /// Speech from the Mac's own voices: real speech, the same on every run, nothing fetched.
    func speech(_ text: String, voice: String, in dir: URL) throws -> [Float] {
        let url = dir.appending(path: "\(voice).wav")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", voice, "-o", url.path, "--file-format=WAVE", "--data-format=LEI16@48000", text]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0, let info = try? AudioFileReader.info(at: url) else { return [] }
        let raw = SourcePool().read(SourceRef(name: voice, path: url.path, info: info), from: 0, count: Int(info.frames))
        return stride(from: 0, to: raw.count, by: info.channels).map { raw[$0] }
    }

    static let texts = [
        "Welcome back to the workshop. Today we are going to talk about how to record a podcast at home without the room getting in the way. First you need a microphone and a quiet room. Carpets and curtains take the echo down. Then we cut the long pauses and bring the loudness to where it should be, and at the end we listen to the whole thing once more before it goes out.",
        "The ferry leaves at seven in the morning, and if you miss it there is not another one until the afternoon. Bring something warm, because the wind on deck is cold even in July. On the island there is one shop, one café and a lighthouse you can climb for a small fee. Most people walk the path along the western shore, which takes about two hours if you stop to look at the birds.",
    ]

    @Test("Speech has no tempo: four voices, two texts", arguments: ["Samantha", "Daniel", "Alva", "Fred"], [0, 1])
    func speechHasNone(voice: String, text: Int) throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let x = try speech(Self.texts[text], voice: voice, in: dir)
        // A voice that isn't installed on this Mac says nothing: nothing to test with it.
        guard x.count > Int(10 * sr) else { return }
        let (p, pool) = try project(x, in: dir, name: "speech.wav")
        #expect(throws: Rhythm.Failure.noSteadyTempo) { try Rhythm.estimate(p, range: 0..<p.length, pool: pool) }
    }

    @Test("Noise, a steady tone, silence and too little sound have no tempo")
    func noTempo() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        var seed: UInt64 = 3
        let noise = (0..<Int(20 * sr)).map { _ -> Float in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int32(truncatingIfNeeded: seed >> 32)) / 2_147_483_648 * 0.2
        }
        for (name, x) in [("noise", noise), ("tone", (0..<Int(20 * sr)).map { Float(0.3 * sin(2 * .pi * 220 * Double($0) / sr)) }),
                          ("silence", [Float](repeating: 0, count: Int(20 * sr)))] {
            let (p, pool) = try project(x, in: dir, name: "\(name).wav")
            #expect(throws: Rhythm.Failure.noSteadyTempo, "\(name)") { try Rhythm.estimate(p, range: 0..<p.length, pool: pool) }
        }
        let (short, pool) = try project(beats(bpm: 120, seconds: 6), in: dir, name: "short.wav")
        #expect(throws: Rhythm.Failure.tooShort) { try Rhythm.estimate(short, range: 0..<short.length, pool: pool) }
    }

    @Test("The test recordings: the speech has no tempo, the song has 120",
          .enabled(if: ProcessInfo.processInfo.environment["JAMMER_TEMPO_DIR"] != nil))
    func recordings() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JAMMER_TEMPO_DIR"]!)
        for name in ["Episode 7", "Daniel", "Flo", "interview", "Kitchen take", "Church hall", "Booth", "Demo song", "Music bed"] {
            let url = dir.appending(path: "\(name).wav")
            guard let info = try? AudioFileReader.info(at: url) else { continue }
            let p = Project(source: SourceRef(name: name, path: url.path, info: info))
            let e = try? Rhythm.estimate(p, range: 0..<p.length, pool: SourcePool())
            print("TEMPOTABLE", name, e.map { "\($0.bpm) BPM, first beat \($0.firstBeat) s, pulse \($0.pulse)" } ?? "no steady tempo")
            if name == "Demo song" || name == "Music bed" { #expect(e.map { abs($0.bpm - 120) <= 0.1 } ?? false) } else { #expect(e == nil, "\(name)") }
        }
    }
    // MARK: Tempo that changes (a tempo map, 2026-11-26)

    /// Clicks or drums on the given beat times (the first of four louder), `seconds` long.
    func sound(at times: [Double], seconds: Double, drums: Bool = false) -> [Float] {
        let n = Int(seconds * sr)
        var x = [Float](repeating: 0, count: n)
        var seed: UInt64 = 3
        for (k, t0) in times.enumerated() {
            let s = Int(t0 * sr)
            for i in 0..<Int(0.06 * sr) where s + i < n {
                let t = Double(i) / sr
                var v: Double
                if drums {
                    v = exp(-t / 0.03) * sin(2 * .pi * (60 + 80 * exp(-t / 0.01)) * t) * 0.8
                    if k % 2 == 1 {
                        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                        v += exp(-t / 0.008) * Double(Int32(truncatingIfNeeded: seed >> 32)) / 2_147_483_648 * 0.4
                    }
                } else {
                    v = exp(-t / 0.008) * sin(2 * .pi * (k % 4 == 0 ? 1_500 : 1_000) * t) * (k % 4 == 0 ? 0.8 : 0.5)
                }
                x[s + i] += Float(v)
            }
        }
        return x
    }

    /// Beat times of steps: each (bpm, seconds) after the one before, from `start`; and where each step begins.
    func steps(_ parts: [(Double, Double)], start: Double = 0.2) -> (times: [Double], starts: [Double]) {
        var times: [Double] = [], starts: [Double] = [], t = start
        for (bpm, length) in parts {
            starts.append(t)
            let end = t + length
            while t < end - 1e-9 { times.append(t); t += 60 / bpm }
        }
        return (times, starts)
    }

    @Test("Steps of tempo become a map: each tempo within half a BPM, each change within 30 ms, every click on the map's grid within 20 ms",
          arguments: [([(120.0, 16.0), (90.0, 16.0), (140.0, 16.0)], false), ([(100.0, 20.0), (128.0, 20.0)], true)])
    func stepsBecomeAMap(parts: [(Double, Double)], drums: Bool) throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (times, starts) = steps(parts)
        let length = parts.reduce(0.2) { $0 + $1.1 } + 1
        let (p, pool) = try project(sound(at: times, seconds: length, drums: drums), in: dir)
        let e = try Rhythm.estimate(p, range: 0..<p.length, pool: pool)
        print("TEMPOMAP", parts.map(\.0), e.stretches.map { "\($0.bpm) from \($0.start) (\($0.beats) beats, pulse \($0.pulse))" })
        #expect(e.stretches.count == parts.count, "\(e.stretches)")
        for (k, part) in parts.enumerated() where k < e.stretches.count {
            #expect(abs(e.stretches[k].bpm - part.0) <= 0.5, "\(part.0): \(e.stretches[k].bpm)")
            let period = 60 / part.0
            // The tracker may start a stretch's count a beat in: where it starts, as a place in the beat.
            let off = (e.stretches[k].start - starts[k]).truncatingRemainder(dividingBy: period)
            #expect(min(abs(off), period - abs(off)) <= 0.03, "stretch \(k) at \(e.stretches[k].start), not \(starts[k])")
        }
        // The map the step sets: every click lies on one of its beats.
        let map = try Rhythm.tempoMap(e.stretches, offset: 0, sampleRate: sr)
        for t in times where t >= e.stretches[0].start {
            let q = map.quarterNotes(at: Frame((t * sr).rounded()), sampleRate: sr)
            let beat = 60 / map.bpm(at: Frame((t * sr).rounded()))
            #expect(abs(q - q.rounded()) * beat <= 0.02, "the click at \(t) is \(abs(q - q.rounded()) * beat) s off the grid")
        }
    }

    @Test("A steady tempo is one tempo, run after run (the tracker isn't the same twice): never a change")
    func steadyStaysOne() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (p, pool) = try project(beats(bpm: 120, seconds: 40), in: dir)
        for _ in 0..<10 {
            let e = try Rhythm.estimate(p, range: 0..<p.length, pool: pool)
            #expect(e.stretches.count == 1 && abs(e.bpm - 120) <= 0.1, "\(e.stretches)")
        }
    }

    @Test("A tempo that glides (a ritardando, 140 to 100 over 30 s) is refused, saying from what to what and between when")
    func glideRefused() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        var times: [Double] = []
        var t = 0.2
        while t < 10 { times.append(t); t += 60 / 140.0 }
        let from = t
        while t < from + 30 { times.append(t); t += 60 / (140 - 40 * (t - from) / 30) }
        let to = t
        while t < to + 12 { times.append(t); t += 60 / 100.0 }
        let (p, pool) = try project(sound(at: times, seconds: t + 1), in: dir)
        #expect {
            _ = try Rhythm.estimate(p, range: 0..<p.length, pool: pool)
        } throws: { error in
            print("TEMPOGLIDE", error)
            guard case .glides(let a, let b, let s, let e) = error as? Rhythm.Failure else { return false }
            return abs(a - 140) <= 8 && abs(b - 100) <= 8 && abs(s - from) <= 5 && abs(e - to) <= 5
        }
    }
}

