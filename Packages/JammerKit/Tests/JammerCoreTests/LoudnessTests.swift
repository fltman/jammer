import Foundation
import Testing
@testable import JammerCore

/// The meter is calibrated against EBU's published test cases, and cross-checked
/// against an independent implementation (ffmpeg's ebur128) when ffmpeg exists.
@Suite("Loudness (EBU Tech 3341 / 3342)")
struct LoudnessTests {
    private func measure(_ samples: [Float], channels: Int = 2, rate: Double = 48_000) -> LoudnessResult {
        var m = LoudnessMeter(sampleRate: rate, channels: channels)
        // Odd block sizes on purpose: the result must not depend on them.
        var i = 0
        let sizes = [4_801, 997, 65_536, 12_000]
        var k = 0
        while i < samples.count {
            let n = min(sizes[k % sizes.count] * channels, samples.count - i)
            samples[i..<(i + n)].withUnsafeBufferPointer { m.process($0) }
            i += n
            k += 1
        }
        return m.result
    }

    private func sequence(_ parts: [(db: Double, seconds: Double)]) -> [Float] {
        parts.flatMap { sine(1_000, amplitudeDB: $0.db, seconds: $0.seconds) }
    }

    @Test("Tech 3341 cases 1–2: stereo 1 kHz sine at −23 and −33 dBFS", arguments: [(-23.0, -23.0), (-33.0, -33.0)])
    func steady(level: Double, expected: Double) throws {
        let r = measure(sine(1_000, amplitudeDB: level, seconds: 20))
        let i = try #require(r.integrated)
        #expect(abs(i - expected) <= 0.1, "integrated \(i)")
        #expect(abs((r.maxMomentary ?? 0) - expected) <= 0.1)
        #expect(abs((r.maxShortTerm ?? 0) - expected) <= 0.1)
    }

    @Test("Tech 3341 cases 3–5: gating")
    func gating() throws {
        let cases: [[(db: Double, seconds: Double)]] = [
            [(-36, 10), (-23, 60), (-36, 10)],
            [(-72, 10), (-36, 10), (-23, 60), (-36, 10), (-72, 10)],
            [(-26, 20), (-20, 20.1), (-26, 20)],
        ]
        for parts in cases {
            let i = try #require(measure(sequence(parts)).integrated)
            #expect(abs(i - -23) <= 0.1, "\(parts) → \(i)")
        }
    }

    @Test("Tech 3342 cases 1–4: loudness range")
    func range() throws {
        let cases: [([(db: Double, seconds: Double)], Double)] = [
            ([(-20, 20), (-30, 20)], 10),
            ([(-20, 20), (-15, 20)], 5),
            ([(-40, 20), (-20, 20)], 20),
            ([(-50, 20), (-35, 20), (-20, 20), (-35, 20), (-50, 20)], 15),
        ]
        for (parts, expected) in cases {
            let lra = try #require(measure(sequence(parts)).range)
            #expect(abs(lra - expected) <= 1, "\(parts) → \(lra)")
        }
    }

    @Test("Silence is below the absolute gate")
    func silence() {
        let r = measure([Float](repeating: 0, count: 48_000 * 2 * 5))
        #expect(r.integrated == nil)
        #expect(r.range == nil)
    }

    @Test("True peak finds the peak between samples")
    func truePeak() {
        // fs/4 at 45°: every sample sits at 0.707 of the real peak (−6.02 dBFS here).
        let s = sine(12_000, amplitudeDB: -6.0206, seconds: 2, phase: .pi / 4)
        let r = measure(s)
        #expect(abs(r.samplePeak - -9.03) < 0.05, "sample peak \(r.samplePeak)")
        #expect(abs(r.truePeak - -6.02) < 0.3, "true peak \(r.truePeak)")
    }

    @Test("Agrees with ffmpeg's ebur128 on a varied signal", .enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg")))
    func ffmpegReference() throws {
        let dir = TempDir()
        let url = dir.file("ref.wav")
        // Noise and tones with a moving envelope, so gating and LRA have work to do.
        let rate = 48_000.0
        let n = Int(rate * 40)
        let white = noise(count: n * 2, seed: 42)
        var s = [Float](repeating: 0, count: n * 2)
        for i in 0..<n {
            let t = Double(i) / rate
            let env = 0.05 + 0.25 * (0.5 + 0.5 * sin(2 * .pi * t / 13))
            let tone = 0.2 * sin(2 * .pi * 220 * t) + 0.1 * sin(2 * .pi * 3_100 * t)
            s[i * 2] = Float(env * (Double(white[i * 2]) * 0.6 + tone))
            s[i * 2 + 1] = Float(env * (Double(white[i * 2 + 1]) * 0.6 - tone))
        }
        try writeWAV(s, to: url)
        let ours = measure(s)
        let ff = try run("/opt/homebrew/bin/ffmpeg", ["-nostats", "-hide_banner", "-i", url.path, "-af", "ebur128=peak=true", "-f", "null", "-"])
        func value(_ label: String) -> Double? {
            guard let summary = ff.output.range(of: "Summary:") else { return nil }
            let tail = ff.output[summary.upperBound...]
            guard let r = tail.range(of: "\(label):") else { return nil }
            let rest = tail[r.upperBound...].trimmingCharacters(in: .whitespaces)
            return Double(rest.split(separator: " ").first ?? "")
        }
        let i = try #require(value("I"))
        let lra = try #require(value("LRA"))
        let peak = try #require(value("Peak"))
        #expect(abs((ours.integrated ?? 0) - i) <= 0.15, "ours \(ours.integrated ?? 0), ffmpeg \(i)")
        #expect(abs((ours.range ?? 0) - lra) <= 0.5, "ours \(ours.range ?? 0), ffmpeg \(lra)")
        #expect(abs(ours.truePeak - peak) <= 0.3, "ours \(ours.truePeak), ffmpeg \(peak)")
    }

    @Test("44.1 kHz uses coefficients derived for that rate")
    func otherRate() throws {
        let i = try #require(measure(sine(1_000, amplitudeDB: -23, seconds: 20, sampleRate: 44_100), rate: 44_100).integrated)
        #expect(abs(i - -23) <= 0.1)
    }
}
