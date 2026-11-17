import Foundation
import Testing
@testable import JammerCore

@Suite("Limiter")
struct LimiterTests {
    static let fs = 48_000.0

    /// The true peak as the app's validated meter reads it (LoudnessTests: EBU cases and ffmpeg).
    static func meter(_ x: [Float], channels: Int) -> Double {
        var m = LoudnessMeter(sampleRate: fs, channels: channels)
        m.process(x)
        return m.result.truePeak
    }

    static func stream(_ x: [Float], channels: Int, settings: Limiter = Limiter(), block: Int? = nil) throws -> [Float] {
        var p = try Limiter.Processor(settings, channels: channels, sampleRate: fs)
        var out: [Float] = []
        let step = (block ?? max(1, x.count / channels)) * channels
        var at = 0
        while at < x.count {
            out += p.process(Array(x[at..<min(x.count, at + step)]))
            at += step
        }
        return out + p.finish()
    }

    /// fs/4 at 45°: every sample lands at ±sin 45° of the amplitude, so the sample peak is
    /// 1/√2 (−3.01 dB) of the true peak. Amplitude 1 → true peak exactly 0 dBTP, sample
    /// peak 0.7071. Faded in and out so the edges add no peaks of their own.
    static func quarterRateSine(seconds: Double = 1) -> [Float] {
        var x = sine(fs / 4, amplitudeDB: 0, seconds: seconds, sampleRate: fs, channels: 2, phase: .pi / 4)
        let n = x.count / 2, fade = 480
        for i in 0..<fade {
            let w = Float(0.5 - 0.5 * cos(.pi * Double(i) / Double(fade)))
            for c in 0..<2 {
                x[i * 2 + c] *= w
                x[(n - 1 - i) * 2 + c] *= w
            }
        }
        return x
    }

    @Test("A sine at fs/4, 45°: no sample is over the ceiling, the true peak is, and it is brought under")
    func betweenTheSamples() throws {
        let x = Self.quarterRateSine()
        let samplePeak = x.map(abs).max()!
        #expect(abs(samplePeak - 0.70711) < 1e-4)
        #expect(Double(samplePeak) < pow(10, -1.0 / 20)) // no sample over −1 dBFS (0.891)
        // The meter on the known 0 dBTP. Its filter has an even number of taps, so its 4×
        // grid sits an eighth of a sample off the samples: at fs/4 that is 11.25° beside
        // the crest, the worst case at this frequency, and it must read
        // 20·log10(cos 11.25°) = −0.169 dBTP. That is inside the 0.3 dB the meter is held
        // to in LoudnessTests, and it is the tolerance of everything below.
        let gridLoss = 20 * log10(cos(11.25 * .pi / 180))
        let before = Self.meter(x, channels: 2)
        #expect(abs(before - gridLoss) < 0.005, "before \(before)")

        let (y, report) = try Limiter.limit(x, channels: 2, sampleRate: Self.fs, settings: Limiter(ceilingDB: -1))
        let after = Self.meter(y, channels: 2)
        print(String(format: "limiter fs/4: before %.3f, after %.3f dBTP, margin %.2f, reduction %.3f dB, limited %.3f s",
                     before, after, report.marginDB, report.reductionMaxDB, report.limitedSeconds))
        // The meter's own reading must be at or under the ceiling; no tolerance is added.
        #expect(after <= -1.0, "after \(after)")
        #expect(report.truePeakAfterDB == after && report.truePeakBeforeDB == before)
        // Without the meter: in the steady middle the gain is constant, so the output is
        // the same sine and its true peak is its sample peak × √2. The limiter sees what
        // the meter sees, so the analytic peak is over the meter's by that same 0.169 dB:
        // the ceiling is kept as the meter reads it, to the meter's tolerance in truth.
        let middle = y[(12_000 * 2)..<(36_000 * 2)].map(abs).max()!
        let analytic = 20 * log10(Double(middle) * 2.0.squareRoot())
        print(String(format: "limiter fs/4: analytic true peak after %.3f dBTP", analytic))
        #expect(abs(analytic - (-1 - report.marginDB - gridLoss)) < 0.005, "analytic \(analytic)")
        #expect(analytic < -0.7) // reduced, though no sample was over the ceiling
        // From what the meter read down to ceiling − margin.
        #expect(abs(report.reductionMaxDB - (before + 1 + report.marginDB)) < 0.005)
        #expect(report.limitedSeconds > 0.95 && report.limitedSeconds <= 1.0)
        #expect(report.ceilingDB == -1)
    }

    /// Stereo 1 kHz and 9 973 Hz bursts at +6 dBFS with hard edges, 100 ms on, 200 ms off.
    static func bursts() -> [Float] {
        let n = Int(fs) * 2
        var x = [Float](repeating: 0, count: n * 2)
        for i in 0..<n where (i / 4_800) % 3 == 0 {
            let f = (i / 14_400) % 2 == 0 ? 1_000.0 : 9_973.0
            let v = Float(2 * sin(2 * .pi * f * Double(i) / fs))
            x[i * 2] = v
            x[i * 2 + 1] = -v * 0.9
        }
        return x
    }

    @Test("Bursts, an impulse and noise at +6 dB end at or under the ceiling by the meter", arguments: [-0.1, -1.0, -3.0])
    func underTheCeiling(ceiling: Double) throws {
        var impulse = [Float](repeating: 0, count: 24_000)
        impulse[10_000] = 1 // full scale: sample peak and true peak are both 0 dB
        let signals: [(String, [Float], Int)] = [
            ("bursts", Self.bursts(), 2),
            ("impulse", impulse, 1),
            ("noise +6 dB", noise(count: 96_000 * 2, seed: 7).map { $0 * 2 }, 2),
        ]
        for (name, x, ch) in signals {
            let before = Self.meter(x, channels: ch)
            let (y, report) = try Limiter.limit(x, channels: ch, sampleRate: Self.fs, settings: Limiter(ceilingDB: ceiling))
            let after = Self.meter(y, channels: ch)
            print(String(format: "limiter %@ @ %.1f: before %.3f, after %.3f dBTP, margin %.2f, reduction %.2f dB, limited %.3f s",
                         name, ceiling, before, after, report.marginDB, report.reductionMaxDB, report.limitedSeconds))
            #expect(before > ceiling, "\(name)")
            #expect(after <= ceiling, "\(name): \(after)")
            // Not far under either: what is given up is the margin, and a little more
            // where the loudest peak falls inside a longer dip.
            #expect(after > ceiling - 1.5, "\(name): \(after)")
            #expect(y.count == x.count)
            #expect(report.truePeakBeforeDB == before && report.truePeakAfterDB == after)
            #expect(report.reductionMaxDB > 0 && report.limitedSeconds > 0)
            #expect(Limiter.margins.contains(report.marginDB))
        }
        // The impulse is known exactly: the gain at its frame is ceiling − margin, and
        // nothing else in the file is anything but zero.
        let (y, report) = try Limiter.limit(impulse, channels: 1, sampleRate: Self.fs, settings: Limiter(ceilingDB: ceiling))
        #expect(abs(20 * log10(Double(y[10_000])) - (ceiling - report.marginDB)) < 0.001)
        #expect(y.enumerated().allSatisfy { $0.offset == 10_000 || $0.element == 0 })
    }

    @Test("Audio already under the ceiling comes back bit for bit")
    func untouched() throws {
        let quiet = sine(997, amplitudeDB: -12, seconds: 1) // true peak −12 dBTP by construction
        let hiss = noise(count: 48_000 * 2, seed: 3).map { $0 * 0.25 }
        for x in [quiet, hiss] {
            let (y, report) = try Limiter.limit(x, channels: 2, sampleRate: Self.fs, settings: Limiter(ceilingDB: -1))
            #expect(y == x)
            #expect(report.reductionMaxDB == 0 && report.limitedSeconds == 0 && report.marginDB == 0)
            #expect(report.truePeakAfterDB == report.truePeakBeforeDB && report.truePeakBeforeDB < -1)
            // The processor itself too, not only the shortcut in `limit`.
            var p = try Limiter.Processor(Limiter(ceilingDB: -1), channels: 2, sampleRate: Self.fs)
            let z = p.process(x) + p.finish()
            #expect(z == x && p.stats == Limiter.Stats())
        }
        // Silence: the peak is −∞ and nothing happens.
        let (s, r) = try Limiter.limit([Float](repeating: 0, count: 2_000), channels: 2, sampleRate: Self.fs, settings: Limiter())
        #expect(s == [Float](repeating: 0, count: 2_000) && r.reductionMaxDB == 0 && r.truePeakBeforeDB == -.infinity)
    }

    @Test("Quiet passages away from the loud ones are bit-identical")
    func quietBetweenLoud() throws {
        // Noise at −20 dBFS for 3 s; +6 dBFS during 0.5–0.6 s and 2.5–2.6 s.
        let n = 144_000
        var x = noise(count: n, seed: 11).map { $0 * 0.1 }
        for i in (24_000..<28_800) { x[i] *= 20 }
        for i in (120_000..<124_800) { x[i] *= 20 }
        let settings = Limiter(ceilingDB: -1, releaseMs: 50, lookaheadMs: 5)
        let (y, report) = try Limiter.limit(x, channels: 1, sampleRate: Self.fs, settings: settings)
        #expect(report.reductionMaxDB > 6)
        // Before a loud part the gain moves at most lookahead (240) + the oversampler's
        // reach (16) frames early.
        #expect(Array(y[0..<(24_000 - 256)]) == Array(x[0..<(24_000 - 256)]))
        #expect(y[24_000 - 100] != x[24_000 - 100])
        // After one, the release (aimed at 1.001, cut at 1) is back in τ·ln(0.7/0.001) ≈ 6.6 τ
        // from a gain of 0.3, plus the lookahead: 0.33 s here. Checked from 0.4 s after.
        let from = 28_800 + 19_200, to = 120_000 - 256
        #expect(Array(y[from..<to]) == Array(x[from..<to]))
        #expect(Array(y[(124_800 + 19_200)...]) == Array(x[(124_800 + 19_200)...]))
        #expect(Array(y[24_000..<28_800]) != Array(x[24_000..<28_800]))
        // Limited time is the two loud parts and their releases, not the file.
        #expect(report.limitedSeconds > 0.2 && report.limitedSeconds < 1.0)
    }

    @Test("Block sizes don't matter: 1, 7, 480 and 65 536 frames give the same bits as one call")
    func blockSizes() throws {
        // Stereo, 150 001 frames, loud and quiet stretches so the gain goes both ways.
        let n = 150_001
        var x = noise(count: n * 2, seed: 5)
        for i in 0..<n {
            let scale: Float = (i / 9_000) % 3 == 0 ? 2 : 0.2
            x[i * 2] *= scale
            x[i * 2 + 1] *= scale * 0.7
        }
        let whole = try Self.stream(x, channels: 2)
        #expect(whole.count == x.count)
        #expect(whole != x)
        for block in [1, 7, 480, 65_536] {
            let y = try Self.stream(x, channels: 2, block: block)
            #expect(y.count == x.count, "block \(block)")
            #expect(y == whole, "block \(block)")
        }
        // A block may even end inside a frame.
        var p = try Limiter.Processor(Limiter(), channels: 2, sampleRate: Self.fs)
        var odd: [Float] = []
        var at = 0
        while at < x.count {
            odd += p.process(Array(x[at..<min(x.count, at + 1_001)]))
            at += 1_001
        }
        odd += p.finish()
        #expect(odd == whole)
        // And `limit` is the same processor: with the margin it reports, it matches.
        let (z, report) = try Limiter.limit(x, channels: 2, sampleRate: Self.fs, settings: Limiter())
        var q = try Limiter.Processor(Limiter(), channels: 2, sampleRate: Self.fs, marginDB: report.marginDB)
        #expect(q.process(x) + q.finish() == z)
    }

    @Test("Frame k out is frame k in")
    func alignment() throws {
        var x = [Float](repeating: 0, count: 30_000)
        x[12_345] = 0.25 // −12 dBFS, well under the ceiling
        for block in [nil, 1, 7, 480] as [Int?] {
            let y = try Self.stream(x, channels: 1, block: block)
            #expect(y.count == x.count)
            #expect(y[12_345] == 0.25)
            #expect(y == x)
        }
        // While limiting too: a full-scale impulse stays where it is, only lower.
        x[12_345] = 1
        let y = try Self.stream(x, channels: 1, settings: Limiter(ceilingDB: -6))
        #expect(y.firstIndex { $0 != 0 } == 12_345 && y.lastIndex { $0 != 0 } == 12_345)
        #expect(abs(20 * log10(Double(y[12_345])) - -6) < 0.001)
        // Shorter than the lookahead, and a single frame.
        #expect(try Self.stream([0.5, -0.5, 0.25], channels: 1) == [0.5, -0.5, 0.25])
        let one = try Self.stream([1], channels: 1, settings: Limiter(ceilingDB: -6))
        #expect(one.count == 1 && abs(20 * log10(Double(one[0])) - -6) < 0.001)
    }

    @Test("Channels are linked: a loud left lowers the right by the same gain")
    func linked() throws {
        // Every sample is a power of two, so out / in is the applied gain exactly.
        // Left: 0.5, with ±2 square bursts at 500 Hz. Right: 0.125 throughout, far under the ceiling.
        let n = 48_000
        var x = [Float](repeating: 0, count: n * 2)
        for i in 0..<n {
            let loud = (i / 6_000) % 2 == 1
            x[i * 2] = loud ? ((i / 48) % 2 == 0 ? 2 : -2) : 0.5
            x[i * 2 + 1] = 0.125
        }
        let y = try Self.stream(x, channels: 2)
        var lowest: Float = 1
        var same = true
        for i in 0..<n {
            let l = y[i * 2] / x[i * 2], r = y[i * 2 + 1] / x[i * 2 + 1]
            if l != r { same = false }
            lowest = min(lowest, r)
        }
        #expect(same)
        #expect(lowest < 0.5) // the right channel went down by more than 6 dB without ever being loud
        #expect(y[1] == x[1]) // and is untouched before the first burst
    }

    @Test("Values out of range, NaN and infinity are refused by name; empty in, empty out")
    func badValues() throws {
        func message(_ s: Limiter) -> String {
            do {
                _ = try Limiter.limit([0.5, 0.5], channels: 1, sampleRate: Self.fs, settings: s)
                return "accepted"
            } catch let e as LimiterError {
                guard case .badValue = e else { return "wrong error" }
                // The processor and validate() refuse the same value.
                #expect(throws: LimiterError.self) { try s.validate() }
                #expect(throws: LimiterError.self) { _ = try Limiter.Processor(s, channels: 1, sampleRate: Self.fs) }
                return e.localizedDescription
            } catch { return "wrong error" }
        }
        #expect(message(Limiter(ceilingDB: .nan)).hasPrefix("ceiling"))
        #expect(message(Limiter(ceilingDB: .infinity)).hasPrefix("ceiling"))
        #expect(message(Limiter(ceilingDB: -.infinity)).hasPrefix("ceiling"))
        #expect(message(Limiter(ceilingDB: 1)).hasPrefix("ceiling"))
        #expect(message(Limiter(releaseMs: 0)).hasPrefix("release"))
        #expect(message(Limiter(releaseMs: .nan)).hasPrefix("release"))
        #expect(message(Limiter(releaseMs: .infinity)).hasPrefix("release"))
        #expect(message(Limiter(lookaheadMs: 100)).hasPrefix("lookahead"))
        #expect(message(Limiter(lookaheadMs: .nan)).hasPrefix("lookahead"))
        #expect(message(Limiter(lookaheadMs: .infinity)).hasPrefix("lookahead"))
        try Limiter().validate()
        try Limiter(ceilingDB: 0, releaseMs: 2_000, lookaheadMs: 0.5).validate()
        try Limiter(ceilingDB: -20, releaseMs: 1, lookaheadMs: 20).validate()

        #expect(throws: LimiterError.badValue(Said("limiter.channels_1_64", "channels must be 1 to 64."))) {
            _ = try Limiter.limit([], channels: 0, sampleRate: Self.fs, settings: Limiter())
        }
        #expect(throws: LimiterError.self) { _ = try Limiter.limit([0.1], channels: 1, sampleRate: .nan, settings: Limiter()) }
        #expect(throws: LimiterError.self) { _ = try Limiter.limit([0.1, 0.2, 0.3], channels: 2, sampleRate: Self.fs, settings: Limiter()) }
        #expect(throws: LimiterError.self) { _ = try Limiter.Processor(Limiter(), channels: 2, sampleRate: Self.fs, marginDB: .nan) }

        let (y, report) = try Limiter.limit([], channels: 2, sampleRate: Self.fs, settings: Limiter())
        #expect(y.isEmpty && report.reductionMaxDB == 0 && report.limitedSeconds == 0)
        var p = try Limiter.Processor(Limiter(), channels: 2, sampleRate: Self.fs)
        #expect(p.process([]).isEmpty && p.finish().isEmpty && p.finish().isEmpty)
        // A NaN sample poisons nothing but itself: no crash, the count holds, and the audio
        // out of the oversampler's reach of it is untouched.
        var x = [Float](repeating: 0.25, count: 4_000)
        x[2_000] = .nan
        let z = try Self.stream(x, channels: 1)
        #expect(z.count == 4_000 && z[2_000].isNaN && Array(z[0..<1_900]) == Array(x[0..<1_900]) && Array(z[2_100...]) == Array(x[2_100...]))
    }

    @Test("Other sample rates: 44.1 kHz (4×), 96 kHz (2×) and 192 kHz (sample peaks, like the meter)", arguments: [44_100.0, 96_000.0, 192_000.0])
    func rates(rate: Double) throws {
        let x = noise(count: Int(rate), seed: 9).map { $0 * 2 }
        let (y, report) = try Limiter.limit(x, channels: 1, sampleRate: rate, settings: Limiter(ceilingDB: -1))
        var m = LoudnessMeter(sampleRate: rate, channels: 1)
        m.process(y)
        print(String(format: "limiter noise @ %.0f Hz: before %.3f, after %.3f dBTP, margin %.2f", rate, report.truePeakBeforeDB, m.result.truePeak, report.marginDB))
        #expect(m.result.truePeak <= -1 && m.result.truePeak == report.truePeakAfterDB)
    }

    @Test("The fastest settings, where the gain moves most between samples, still keep the ceiling")
    func fastest() throws {
        let settings = Limiter(ceilingDB: -0.1, releaseMs: 1, lookaheadMs: 0.5)
        for (name, x, ch) in [("noise +6 dB", noise(count: 96_000 * 2, seed: 7).map { $0 * 2 }, 2), ("bursts", Self.bursts(), 2)] {
            let (y, report) = try Limiter.limit(x, channels: ch, sampleRate: Self.fs, settings: settings)
            let after = Self.meter(y, channels: ch)
            print(String(format: "limiter fastest %@: before %.3f, after %.3f dBTP, margin %.2f", name, report.truePeakBeforeDB, after, report.marginDB))
            #expect(after <= -0.1 && after == report.truePeakAfterDB)
        }
    }

    /// The mastering use: the gain is found on the mix and put on each track, so the tracks' sum is the
    /// limited mix. Limiting the tracks one by one would not bound their sum.
    @Test("The gain curve from the mix, applied to the tracks, gives the limited mix")
    func gainsFromTheMix() throws {
        let n = 48_000
        var rng = SystemRandomNumberGenerator()
        let a = (0..<n * 2).map { _ in Float.random(in: -0.9...0.9, using: &rng) }
        let b = (0..<n * 2).map { i in Float(0.8 * sin(Double(i / 2) * 0.21)) }
        let mix = zip(a, b).map { $0 + $1 }
        var whole = try Limiter.Processor(Limiter(), channels: 2, sampleRate: 48_000, marginDB: 0.05)
        let limited = whole.process(mix) + whole.finish()
        var curve = try Limiter.Processor(Limiter(), channels: 2, sampleRate: 48_000, marginDB: 0.05)
        var gains: [Float] = []
        var at = 0
        for size in [1, 7, 4_096, 9_999, n] where at < n {       // odd blocks: the curve doesn't depend on them
            let m = min(size, n - at)
            gains += curve.gains(Array(mix[(at * 2)..<((at + m) * 2)]))
            at += m
        }
        gains += curve.gains(Array(mix[(at * 2)...]))
        gains += curve.finishGains()
        #expect(gains.count == n && curve.stats == whole.stats && gains.contains { $0 < 1 })
        // The curve on the mix is the limited mix, bit for bit; on the tracks, their sum is it to rounding.
        var worst: Float = 0
        for i in 0..<n {
            for c in 0..<2 {
                let k = i * 2 + c
                #expect(gains[i] < 1 ? mix[k] * gains[i] == limited[k] : mix[k] == limited[k])
                worst = max(worst, abs(a[k] * gains[i] + b[k] * gains[i] - limited[k]))
            }
        }
        #expect(worst < 1e-6)
        // Each track alone is far over what limiting it alone would need, and that is the point.
        var m = Limiter.PeakMeter(channels: 2, sampleRate: 48_000)
        m.process(limited)
        #expect(m.peakDB <= -1.0)
    }
}
