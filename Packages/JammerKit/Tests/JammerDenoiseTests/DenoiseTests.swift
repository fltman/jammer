import Foundation
import Testing
@testable import JammerCore
@testable import JammerDenoise

@Suite("DeepFilterNet")
struct DenoiseTests {
    static let model = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appending(path: "../../Vendor/DeepFilterNet3_onnx.tar.gz").standardized

    @Test("Measure the model's delay with a click")
    func delay() throws {
        let d = try Denoiser(modelPath: Self.model)
        var x = [Float](repeating: 0, count: 48_000)
        // A short burst of voice-like tone, which the model keeps.
        for i in 20_000..<20_480 { x[i] = Float(0.5 * sin(2 * .pi * 300 * Double(i) / 48_000) * sin(.pi * Double(i - 20_000) / 480)) }
        let raw = d.process48k(x, amount: 1, delay: 0)
        // Cross-correlate to find the shift.
        var best = 0, bestV = -Double.infinity
        for lag in 0..<2_000 {
            var v = 0.0
            for i in 19_000..<22_000 where i + lag < raw.count { v += Double(x[i]) * Double(raw[i + lag]) }
            if v > bestV { bestV = v; best = lag }
        }
        print("DENOISE  delay \(best) samples")
        #expect(best == Denoiser.delay)
    }

    /// A vowel-like signal with a slow envelope, the kind of thing the model keeps.
    func voice(_ n: Int, rate: Double = 48_000) -> [Float] {
        (0..<n).map { i in
            let t = Double(i) / rate
            let env = max(0, sin(2 * .pi * 1.3 * t))
            return Float(env * (0.25 * sin(2 * .pi * 180 * t) + 0.12 * sin(2 * .pi * 360 * t) + 0.06 * sin(2 * .pi * 900 * t) + 0.03 * sin(2 * .pi * 2_100 * t)))
        }
    }
    func noise(_ n: Int, level: Float) -> [Float] {
        var x: UInt64 = 42
        return (0..<n).map { _ in
            x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int32(truncatingIfNeeded: x >> 32)) / 2_147_483_648 * level
        }
    }
    func snr(_ clean: [Float], _ y: [Float], from: Int) -> Double {
        var s = 0.0, e = 0.0
        for i in from..<clean.count { s += Double(clean[i] * clean[i]); e += Double((y[i] - clean[i]) * (y[i] - clean[i])) }
        return 10 * log10(s / max(e, 1e-12))
    }

    /// Synthetic Swedish speech (macOS voice Alva) at `rate`, mono.
    func speech(rate: Double) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appending(path: "jammer-dn-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Alva", "-o", url.path, "--data-format=BEF32@\(Int(rate))",
                         "Hej och välkommen. Idag pratar vi om brus, och om hur man tar bort det."]
        try say.run()
        say.waitUntilExit()
        let info = try AudioFileReader.info(at: url)
        let ref = SourceRef(name: "s", path: url.path, info: info)
        return SourcePool().read(ref, from: 0, count: Int(info.frames))
    }

    func rms(_ x: ArraySlice<Float>) -> Double { (x.reduce(0) { $0 + Double($1 * $1) } / Double(max(1, x.count))).squareRoot() }
    func db(_ v: Double) -> Double { 20 * log10(max(v, 1e-12)) }

    @Test("Noise in the pauses goes down a lot; speech keeps its level and shape; nothing shifts", arguments: [48_000.0, 44_100.0])
    func quality(rate: Double) throws {
        let d = try Denoiser(modelPath: Self.model)
        let clean = try speech(rate: rate)
        let noisy = zip(clean, noise(clean.count, level: 0.03)).map(+)
        let full = d.process(noisy, sampleRate: rate, amount: 1)
        let gentle = d.process(noisy, sampleRate: rate, amount: 0.5)
        #expect(full.count == clean.count)
        // 20 ms blocks: pauses where the clean speech is silent, speech where it's loud.
        let block = Int(rate * 0.02)
        var pauses: [Range<Int>] = [], loud: [Range<Int>] = []
        for b in stride(from: Int(rate * 0.3), to: clean.count - block, by: block) {
            let r = b..<(b + block), e = rms(clean[r])
            if e < 1e-4 { pauses.append(r) } else if e > 0.03 { loud.append(r) }
        }
        func level(_ x: [Float], _ rs: [Range<Int>]) -> Double { db((rs.reduce(0.0) { $0 + pow(rms(x[$1]), 2) } / Double(rs.count)).squareRoot()) }
        let noiseBefore = level(noisy, pauses), noiseFull = level(full, pauses), noiseGentle = level(gentle, pauses)
        let speechClean = level(clean, loud), speechFull = level(full, loud)
        var dot = 0.0, a = 0.0, b2 = 0.0
        for r in loud { for i in r { dot += Double(clean[i] * full[i]); a += Double(clean[i] * clean[i]); b2 += Double(full[i] * full[i]) } }
        let corr = dot / (a * b2).squareRoot()
        print("DENOISE  \(Int(rate)) Hz: pauses \(String(format: "%.1f", noiseBefore)) → \(String(format: "%.1f", noiseFull)) dB (50 %: \(String(format: "%.1f", noiseGentle))), speech \(String(format: "%.1f", speechClean)) → \(String(format: "%.1f", speechFull)) dB, correlation \(String(format: "%.3f", corr)), \(pauses.count) pause blocks")
        #expect(pauses.count > 10 && loud.count > 20)
        #expect(noiseBefore - noiseFull > 20)
        #expect(abs(noiseBefore - noiseGentle - 6) < 2)
        #expect(abs(speechClean - speechFull) < 3)
        #expect(corr > 0.9)
        // Aligned: the correlation with the clean speech peaks at lag 0.
        var best = 0, bestV = -Double.infinity
        for lag in -100...100 {
            var v = 0.0
            for r in loud { for i in r where i + lag >= 0 && i + lag < full.count { v += Double(clean[i]) * Double(full[i + lag]) } }
            if v > bestV { bestV = v; best = lag }
        }
        #expect(abs(best) <= 1, "output shifted by \(best) samples")
    }

    @Test("Through Restoration: denoise is a repair like the others; amount 0 is bit-exact")
    func throughRestoration() throws {
        let d = try Denoiser(modelPath: Self.model)
        d.register()
        defer { Restoration.denoiser = nil }
        let signal = zip(voice(48_000 * 3), noise(48_000 * 3, level: 0.05)).map(+)
        let stereo = signal.flatMap { [$0, $0] }
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: Int64(signal.count), chunks: [], bext: nil, ixml: nil, markers: [])
        let ref = SourceRef(name: "noisy", path: "/dev/null", info: info)
        let pool = SourcePool()
        pool.register(ref.id, memory: stereo, channels: 2)
        let p = Project(source: ref)
        let media = FileManager.default.temporaryDirectory.appending(path: "jammer-dn-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: media) }
        let (q, report) = try Restoration.apply(.init(kind: .denoise), to: p, pool: pool, media: media)
        #expect(report.clips == 1 && q.sources[0].name.hasSuffix("(denoise)"))
        let (z, _) = try Restoration.apply(.init(kind: .denoise, amount: 0), to: p, pool: pool, media: media)
        let plan = PlanCompiler.compile(z, pool: pool)
        #expect(plan.render(from: 0, frames: signal.count) == stereo)
    }
}
