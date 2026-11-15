import Foundation
import Testing
@testable import JammerStems

/// Against Deezer's Spleeter 4stems checkpoint and reference outputs computed with
/// TensorFlow's own ops (ref/reference.py), when they're on this machine (JAMMER_SPLEETER_DIR).
let spleeterDir = ProcessInfo.processInfo.environment["JAMMER_SPLEETER_DIR"].map { URL(fileURLWithPath: $0) }

func npy(_ url: URL) throws -> [Float] {
    let d = try Data(contentsOf: url)
    let headerLength = Int(d[8]) | Int(d[9]) << 8
    return d.subdata(in: (10 + headerLength)..<d.count).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

@Suite("Spleeter checkpoint", .enabled(if: spleeterDir != nil))
struct CheckpointTests {
    @Test("Every tensor reads back as TensorFlow wrote it")
    func read() throws {
        let dir = spleeterDir!
        let ck = try TFCheckpoint(index: dir.appending(path: "4stems/model.index"), data: dir.appending(path: "4stems/model.data-00000-of-00001"))
        #expect(ck.entries["conv2d/kernel"]?.shape == [5, 5, 2, 16])
        #expect(ck.entries["conv2d_transpose_23/kernel"]?.shape == [5, 5, 1, 32])
        // The flat dump written by TensorFlow: count, then name, rank, dims, floats.
        let dump = try Data(contentsOf: dir.appending(path: "ref/weights.bin"), options: .alwaysMapped)
        var at = 0
        func u32() -> Int { defer { at += 4 }; return Int(dump.subdata(in: at..<(at + 4)).withUnsafeBytes { $0.load(as: UInt32.self) }) }
        let count = u32()
        var checked = 0
        for _ in 0..<count {
            let n = u32()
            let name = String(decoding: dump.subdata(in: at..<(at + n)), as: UTF8.self); at += n
            let rank = u32()
            let shape = (0..<rank).map { _ in u32() }
            let size = shape.reduce(1, *) * 4
            let expected = dump.subdata(in: at..<(at + size)).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }; at += size
            let got = try ck.floats(name)
            #expect(got.shape == shape && got.values == expected, "\(name)")
            checked += 1
        }
        #expect(checked == 296)
    }
}

@Suite("Spleeter network", .enabled(if: spleeterDir != nil))
struct NetTests {
    @Test("The four U-Nets match TensorFlow's output on the same input")
    func parity() throws {
        let dir = spleeterDir!
        let ck = try TFCheckpoint(index: dir.appending(path: "4stems/model.index"), data: dir.appending(path: "4stems/model.data-00000-of-00001"))
        let net = try SpleeterNet(checkpoint: ck, frames: 64)
        let x = try npy(dir.appending(path: "ref/input.npy"))
        let t0 = Date()
        let out = net.run(x)
        print(String(format: "STEMS forward %.2f s for 64 frames", Date().timeIntervalSince(t0)))
        for (i, stem) in SpleeterNet.stems4.enumerated() {
            let ref = try npy(dir.appending(path: "ref/\(stem).npy"))
            var err = 0.0, pow = 0.0, worst: Float = 0
            for k in 0..<ref.count { let d = out[i][k] - ref[k]; err += Double(d * d); pow += Double(ref[k] * ref[k]); worst = max(worst, abs(d)) }
            let snr = 10 * log10(pow / max(err, 1e-30))
            print(String(format: "STEMS %@: SNR %.1f dB vs TensorFlow, worst difference %.2g", stem, snr, worst))
            #expect(snr > 60, "\(stem)")
        }
    }
}

import JammerCore

/// A stand-in network: stem 0 gets everything below 1 kHz, stem 1 the next band up to
/// 5 kHz, stem 2 nothing ("other" then takes what's left).
struct BandSplit: StemEstimator {
    var frames = 64
    var stemNames = ["low", "mid", "other"]
    func estimate(_ mix: [Float]) -> [[Float]] {
        var low = mix, mid = mix
        let zero = [Float](repeating: 0, count: mix.count)
        for t in 0..<frames { for k in 0..<1_024 { for c in 0..<2 {
            let hz = Double(k) * 44_100 / 4_096, i = (t * 1_024 + k) * 2 + c
            if hz >= 1_000 { low[i] = 0 }
            if hz < 1_000 || hz >= 5_000 { mid[i] = 0 }
        } } }
        return [low, mid, zero]
    }
}

@Suite("Stem separator")
struct SeparatorTests {
    @Test("The stems add up to the original, band by band, across block borders and at odd lengths")
    func sumsToOriginal() throws {
        let n = 44_100 * 4 + 777   // several 64-frame blocks, not a multiple of the hop
        var x = [Float](repeating: 0, count: n * 2)
        for i in 0..<n {
            let t = Double(i) / 44_100
            let v = Float(0.3 * sin(2 * .pi * 200 * t) + 0.2 * sin(2 * .pi * 3_000 * t) + 0.1 * sin(2 * .pi * 15_000 * t))
            x[i * 2] = v; x[i * 2 + 1] = v * 0.5
        }
        var stems = [[Float]](repeating: [], count: 3)
        try StemSeparator.separate(x, with: BandSplit()) { s, block in stems[s] += block }
        #expect(stems.allSatisfy { $0.count == x.count })
        var worst: Float = 0
        for i in 0..<x.count { worst = max(worst, abs(stems[0][i] + stems[1][i] + stems[2][i] - x[i])) }
        var err = 0.0, pow = 0.0
        for i in 0..<x.count { let d = Double(stems[0][i] + stems[1][i] + stems[2][i] - x[i]); err += d * d; pow += Double(x[i] * x[i]) }
        print(String(format: "STEMS null test: sum of stems minus original %.1f dB", 10 * log10(max(err, 1e-30) / pow)))
        #expect(10 * log10(max(err, 1e-30) / pow) < -60)
        #expect(worst < 1e-4, "sum differs by \(worst)")
        func amp(_ s: [Float], _ hz: Double) -> Double {
            var c = 0.0, q = 0.0
            for i in 44_100..<(44_100 * 3) { let p = 2 * .pi * hz * Double(i) / 44_100; c += Double(s[i * 2]) * cos(p); q += Double(s[i * 2]) * sin(p) }
            return 2 * (c * c + q * q).squareRoot() / Double(44_100 * 2)
        }
        #expect(abs(amp(stems[0], 200) - 0.3) < 0.01 && amp(stems[0], 3_000) < 0.01)
        #expect(abs(amp(stems[1], 3_000) - 0.2) < 0.01 && amp(stems[1], 200) < 0.01)
        #expect(abs(amp(stems[2], 15_000) - 0.1) < 0.01, "above 11 kHz goes to the last stem")
    }
}

@Suite("Spleeter separation", .enabled(if: spleeterDir != nil))
struct RealSeparationTests {
    /// A synthetic "song" at 44.1 kHz stereo: a spoken voice (macOS Alva), a bass line and drum hits.
    func song() throws -> (mix: [Float], voice: [Float], bass: [Float], drums: [Float]) {
        let url = URL(fileURLWithPath: "$JAMMER_TEST_MEDIA/iso-speech.aiff")
        let info = try AudioFileReader.info(at: url)
        let raw = SourcePool().read(SourceRef(name: "s", path: url.path, info: info), from: 0, count: Int(info.frames))
        let mono48 = stride(from: 0, to: raw.count, by: info.channels).map { raw[$0] }
        let v = try Alignment.resample(mono48, channels: 1, from: info.sampleRate, to: 44_100)
        let n = min(v.count, 44_100 * 8)
        let peak = v.prefix(n).map(abs).max() ?? 1
        var voice = [Float](repeating: 0, count: n), bass = voice, drums = voice
        var seed: UInt64 = 3
        for i in 0..<n {
            let t = Double(i) / 44_100
            voice[i] = v[i] / peak * 0.4
            let note = [55.0, 55, 73.4, 82.4][Int(t * 2) % 4]
            bass[i] = Float(0.25 * sin(2 * .pi * note * t) * min(1, (t * 2).truncatingRemainder(dividingBy: 1) * 20))
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            let w = Float(Int32(truncatingIfNeeded: seed >> 32)) / 2_147_483_648
            let ph = (t * 2).truncatingRemainder(dividingBy: 1)
            drums[i] = w * Float(0.35 * exp(-ph * 40))
        }
        let mix = (0..<n).flatMap { i -> [Float] in let m = voice[i] + bass[i] + drums[i]; return [m, m] }
        return (mix, voice, bass, drums)
    }

    func sisdr(_ est: [Float], _ ref: [Float]) -> Double {
        var dot = 0.0, rr = 0.0
        for i in 0..<ref.count { dot += Double(est[i * 2]) * Double(ref[i]); rr += Double(ref[i] * ref[i]) }
        let a = dot / rr
        var e = 0.0
        for i in 0..<ref.count { let d = Double(est[i * 2]) - a * Double(ref[i]); e += d * d }
        return 10 * log10(a * a * rr / e)
    }

    @Test("Voice, bass and drums come apart; the four stems null against the mix; golden levels hold")
    func separates() throws {
        let dir = spleeterDir!
        let ck = try TFCheckpoint(index: dir.appending(path: "4stems/model.index"), data: dir.appending(path: "4stems/model.data-00000-of-00001"))
        let net = try SpleeterNet(checkpoint: ck)
        let (mix, voice, bass, drums) = try song()
        var stems = [[Float]](repeating: [], count: 4)
        let t0 = Date()
        try StemSeparator.separate(mix, with: net) { s, b in stems[s] += b }
        let seconds = Date().timeIntervalSince(t0)
        var err = 0.0, pow = 0.0
        for i in 0..<mix.count { let d = Double(stems[0][i] + stems[1][i] + stems[2][i] + stems[3][i] - mix[i]); err += d * d; pow += Double(mix[i] * mix[i]) }
        let null = 10 * log10(max(err, 1e-30) / pow)
        let rows = [("vocals", 0, voice), ("drums", 1, drums), ("bass", 2, bass)].map { name, i, ref in (name, sisdr(mix, ref), sisdr(stems[i], ref)) }
        for r in rows { print(String(format: "STEMS %@: SI-SDR %.1f dB in the mix → %.1f dB in its stem", r.0, r.1, r.2)) }
        print(String(format: "STEMS null %.1f dB; %.1f s of audio in %.1f s (%.0f× real time)", null, Double(voice.count) / 44_100, seconds, Double(voice.count) / 44_100 / seconds))
        #expect(null < -60)
        for r in rows { #expect(r.2 > r.1 + 3, "\(r.0)") }
        // Listenable copies, and levels pinned from the first verified run (GPU floats aren't bit-stable).
        let out = dir.appending(path: "golden")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var levels: [Double] = []
        for (i, name) in SpleeterNet.stems4.enumerated() {
            let w = try WAVWriter(url: out.appending(path: "\(name).wav"), options: .init(encoding: .int24, channels: 2, sampleRate: 44_100))
            try w.write(stems[i]); try w.finish()
            levels.append(10 * log10(stems[i].map { Double($0 * $0) }.reduce(0, +) / Double(stems[i].count)))
        }
        print("STEMS golden levels dB: " + levels.map { String(format: "%.2f", $0) }.joined(separator: ", "))
        if let golden = Self.golden { for (a, b) in zip(levels, golden) { #expect(abs(a - b) < 0.3) } }
    }
    static let golden: [Double]? = [-22.12, -36.51, -15.20, -35.81]
}
