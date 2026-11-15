import Accelerate
import Foundation
import Testing
@testable import JammerCore

@Suite("De-reverb")
struct DereverbTests {
    let sr = 48_000.0
    let bursts: [(Double, Double)] = [(0.3, 0.9), (1.5, 2.0), (2.7, 3.3), (4.0, 4.5)]

    /// Speech-like bursts (noise shaped like syllables, low-passed), dry.
    func dry(seconds: Double = 5.5) -> [Float] {
        let n = Int(seconds * sr)
        let w = noise(count: n, seed: 41)
        var out = [Float](repeating: 0, count: n), lp: Float = 0
        for (a, b) in bursts {
            for i in Int(a * sr)..<min(n, Int(b * sr)) {
                let t = Double(i) / sr
                lp = 0.85 * lp + 0.15 * w[i]
                let edge = min(1, min(t - a, b - t) / 0.01)
                out[i] = lp * Float(0.5 * (0.55 + 0.45 * sin(2 * .pi * 5 * t)) * edge)
            }
        }
        return out
    }

    /// A room: exponentially decaying noise after a direct path, reverberation time `rt60`.
    func room(_ x: [Float], rt60: Double = 0.6, level: Float = 0.5) -> [Float] {
        let len = Int(rt60 * sr)
        let w = noise(count: len, seed: 42)
        var h = (0..<len).map { i in w[i] * Float(exp(-6.91 * Double(i) / sr / rt60)) }
        let e = (h.map { $0 * $0 }.reduce(0, +)).squareRoot()
        h = h.map { $0 / e * level }
        var y = x
        // Sparse convolution: the dry signal is zero between bursts.
        for (i, v) in x.enumerated() where v != 0 {
            let end = min(x.count, i + len)
            var k = 0
            var j = i + Int(0.004 * sr)
            while j < end { y[j] += v * h[k]; j += 1; k += 1 }
        }
        return y
    }

    func db(_ x: ArraySlice<Float>) -> Double { 10 * log10(Double(x.map { $0 * $0 }.reduce(0, +)) / Double(x.count) + 1e-20) }
    /// Mean level 60–300 ms after each burst ends: the reverberant tail.
    func tail(_ x: [Float]) -> Double { bursts.map { db(x[Int(($0.1 + 0.06) * sr)..<Int(($0.1 + 0.3) * sr)]) }.reduce(0, +) / Double(bursts.count) }
    func sisdr(_ est: [Float], _ ref: [Float]) -> Double {
        var dot = 0.0, rr = 0.0
        for i in 0..<ref.count { dot += Double(est[i]) * Double(ref[i]); rr += Double(ref[i] * ref[i]) }
        let a = dot / rr
        var e = 0.0
        for i in 0..<ref.count { let d = Double(est[i]) - a * Double(ref[i]); e += d * d }
        return 10 * log10(a * a * rr / e)
    }

    @Test("A reverberant room: the tails drop, the result is closer to the dry sound, amount 0 changes nothing")
    func reverberant() {
        let d = dry(), wet = room(d)
        let out = Restoration.dereverb(wet, sampleRate: sr)
        print(String(format: "DEREVERB tails %.1f → %.1f dB; SI-SDR vs dry %.1f → %.1f dB; RT60 estimate %@ → %@", tail(wet), tail(out), sisdr(wet, d), sisdr(out, d),
                     Restoration.estimateRT60(wet, sampleRate: sr).map { String(format: "%.2f s", $0) } ?? "nil",
                     Restoration.estimateRT60(out, sampleRate: sr).map { String(format: "%.2f s", $0) } ?? "nil"))
        #expect(tail(wet) - tail(out) >= 6)
        #expect(sisdr(out, d) > sisdr(wet, d))
        #expect(Restoration.dereverb(wet, sampleRate: sr, amount: 0) == wet)
        let rt = Restoration.estimateRT60(wet, sampleRate: sr)
        #expect(rt != nil && (0.35...0.9).contains(rt!), "estimated \(String(describing: rt))")
    }

    @Test("Dry sound isn't harmed")
    func dryStays() {
        let d = dry()
        let out = Restoration.dereverb(d, sampleRate: sr)
        let change = bursts.map { db(out[Int($0.0 * sr)..<Int($0.1 * sr)]) - db(d[Int($0.0 * sr)..<Int($0.1 * sr)]) }
        print("DEREVERB dry change dB:", change.map { String(format: "%.2f", $0) }, "SI-SDR", String(format: "%.1f", sisdr(out, d)))
        #expect(change.allSatisfy { abs($0) <= 0.5 })
        let rt = Restoration.estimateRT60(d, sampleRate: sr)
        #expect(rt == nil || rt! < 0.3, "dry estimated \(String(describing: rt))")
    }

    @Test("Noisy material (15 dB SNR): the noise floor isn't lifted by more than 1 dB")
    func noisy() {
        let d = dry(), wet = room(d)
        let speech = bursts.map { db(wet[Int($0.0 * sr)..<Int($0.1 * sr)]) }.reduce(0, +) / Double(bursts.count)
        let g = Float(pow(10, (speech - 15) / 20))
        let nz = noise(count: wet.count, seed: 43).map { $0 * g * 1.7320508 } // uniform noise at that RMS
        let x = zip(wet, nz).map { $0 + $1 }
        let out = Restoration.dereverb(x, sampleRate: sr)
        // The floor: well after each tail has died and before the next burst.
        let gaps = [(1.25, 1.45), (2.45, 2.65), (3.7, 3.95), (5.0, 5.4)]
        let before = gaps.map { db(x[Int($0.0 * sr)..<Int($0.1 * sr)]) }.reduce(0, +) / 4, after = gaps.map { db(out[Int($0.0 * sr)..<Int($0.1 * sr)]) }.reduce(0, +) / 4
        print(String(format: "DEREVERB noisy: floor %.1f → %.1f dB (%+.2f); tails %.1f → %.1f dB", before, after, after - before, tail(x), tail(out)))
        #expect(after - before <= 1)
        #expect(tail(out) < tail(x))
    }
}

/// Voices in rooms of known length (JAMMER_EVAL_DIR; see its SOURCES.md): two macOS voices,
/// which are clean and perfectly dry, and a LibriVox reader (public domain, never in the
/// repository) whose recording has its own noise 20 dB under the voice.
@Suite("De-reverb on voices", .enabled(if: ProcessInfo.processInfo.environment["JAMMER_EVAL_DIR"] != nil))
struct DereverbEvaluation {
    let sr = 44_100.0

    func load(_ file: String, seconds: Double) throws -> [Float] {
        let d = try Data(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.environment["JAMMER_EVAL_DIR"]!).appending(path: file))
        return Array(d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }.prefix(Int(seconds * sr)))
    }
    /// dry + dry * h: decaying noise 6 dB under the direct sound, starting 4 ms after it.
    func room(_ dry: [Float], rt60: Double) -> [Float] {
        let len = Int(rt60 * sr)
        let w = noise(count: len, seed: 42)
        var h = (0..<len).map { i in w[i] * Float(exp(-6.91 * Double(i) / sr / rt60)) }
        let e = (h.map { $0 * $0 }.reduce(0, +)).squareRoot()
        h = h.map { $0 / e * 0.5 }
        let padded = [Float](repeating: 0, count: len - 1 + Int(0.004 * sr)) + dry
        var rev = [Float](repeating: 0, count: dry.count)
        h.withUnsafeBufferPointer { hp in vDSP_conv(padded, 1, hp.baseAddress! + (len - 1), -1, &rev, 1, vDSP_Length(dry.count), vDSP_Length(len)) }
        return zip(dry, rev).map { $0 + $1 }
    }

    @Test("Closer to the dry voice, quieter in the pauses", arguments: ["say/sv.f32", "say/en.f32", "speech.f32"], [0.6, 1.0])
    func voice(file: String, rt60: Double) throws {
        let dry = try load(file, seconds: 20), wet = room(dry, rt60: rt60)
        let t0 = Date()
        let out = Restoration.dereverb(wet, sampleRate: sr, amount: 1)
        let took = Date().timeIntervalSince(t0)
        func sisdr(_ est: [Float]) -> Double {
            var dot = 0.0, rr = 0.0
            for i in 0..<dry.count { dot += Double(est[i]) * Double(dry[i]); rr += Double(dry[i] * dry[i]) }
            let a = dot / rr
            var err = 0.0
            for i in 0..<dry.count { let q = Double(est[i]) - a * Double(dry[i]); err += q * q }
            return 10 * log10(a * a * rr / err)
        }
        // The pauses: 20 ms frames where the dry voice is 45 dB or more under its loudest frame.
        let f = Int(0.02 * sr)
        func level(_ x: [Float], _ i: Int) -> Double { 10 * log10(Double(x[i..<(i + f)].map { $0 * $0 }.reduce(0, +)) / Double(f) + 1e-20) }
        let starts = Array(stride(from: 0, to: dry.count - f, by: f))
        let top = starts.map { level(dry, $0) }.max()!
        let pauses = starts.filter { level(dry, $0) < top - 45 }
        func mean(_ x: [Float]) -> Double { 10 * log10(pauses.map { pow(10, level(x, $0) / 10) }.reduce(0, +) / Double(max(1, pauses.count))) }
        print(String(format: "DEREVERB %@, room %.1f s: SI-SDR vs dry %.1f → %.1f dB; level in the pauses (%d frames) %.1f → %.1f dB; %.2f s for 20 s",
                     file, rt60, sisdr(wet), sisdr(out), pauses.count, mean(wet), mean(out), took))
        #expect(sisdr(out) > sisdr(wet) + 1)
        // The LibriVox recording has next to no pauses under its own noise.
        if pauses.count >= 50 { #expect(mean(wet) - mean(out) >= 3) }
    }

    @Test("The reverberation time that analysis reports", arguments: ["say/sv.f32", "say/en.f32"])
    func time(file: String) throws {
        let dry = try load(file, seconds: 60)
        let rooms = [0.3, 0.6, 1.0, 1.5]
        let est = [Restoration.estimateRT60(dry, sampleRate: sr)] + rooms.map { Restoration.estimateRT60(room(dry, rt60: $0), sampleRate: sr) }
        print("DEREVERB RT60", file, "dry, 0.3, 0.6, 1.0, 1.5 s →", est.map { $0.map { String(format: "%.2f", $0) } ?? "nil" })
        #expect(est[0] == nil || est[0]! < 0.25)
        #expect(est[1] != nil && (0.2...0.5).contains(est[1]!))
        #expect(est[2] != nil && (0.45...0.85).contains(est[2]!))
        #expect(est[3] != nil && (0.7...1.3).contains(est[3]!))
        // Longer than speech pauses show: it reads short, but never as a dry room.
        #expect(est[4] != nil && est[4]! >= 0.6)
    }
}
