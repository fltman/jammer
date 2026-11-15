import Foundation
import Testing
@testable import JammerCore

@Suite("Spectral")
struct SpectralTests {
    let sr = 48_000.0
    func sines(_ n: Int, _ parts: [(Double, Double)]) -> [Float] {
        (0..<n).map { i in Float(parts.reduce(0.0) { $0 + $1.1 * sin(2 * .pi * $1.0 * Double(i) / sr) }) }
    }
    func level(_ x: [Float], _ f: Double) -> Double { 10 * log10(max(Restoration.goertzel(x, f, sr), 1e-30)) }

    @Test("A full-scale sine shows at about 0 dBFS in its bin, silence far below")
    func spectrogram() {
        let cols = Spectral.spectrogram(sines(48_000, [(3_000, 1)]))
        let bin = Int(3_000.0 / (sr / 2_048))
        let mid = cols[cols.count / 2]
        #expect(abs(mid[bin] - 0) < 1.5, "peak \(mid[bin]) dB")
        #expect(mid[bin + 40] < -80)
    }

    @Test("Attenuating a box removes that tone there only; everything outside is bit-exact")
    func attenuate() {
        let n = 96_000
        let x = sines(n, [(500, 0.3), (6_000, 0.3)])
        let box = 30_000..<60_000
        let y = Spectral.attenuate(x, sampleRate: sr, time: box, freq: 5_000...7_000, gainDB: -40)
        let inside = Array(y[36_000..<54_000]), insideX = Array(x[36_000..<54_000])
        #expect(level(insideX, 6_000) - level(inside, 6_000) > 30)
        #expect(abs(level(insideX, 500) - level(inside, 500)) < 0.2)
        // Outside the box's span (minus the analysis margin and fade): exact.
        #expect(Array(y[0..<(box.lowerBound - 2_048)]) == Array(x[0..<(box.lowerBound - 2_048)]))
        #expect(Array(y[(box.upperBound + 2_048)...]) == Array(x[(box.upperBound + 2_048)...]))
        // 0 dB changes nothing that can be heard (round trip within float error).
        let z = Spectral.attenuate(x, sampleRate: sr, time: box, freq: 5_000...7_000, gainDB: 0)
        #expect(zip(z, x).allSatisfy { abs($0 - $1) < 1e-5 })
    }

    @Test("On the project: the band goes down in the range, the rest of the timeline is bit-exact")
    func project() throws {
        let n = 96_000
        let mono = sines(n, [(500, 0.3), (6_000, 0.3)])
        let (p, pool) = memoryProject(mono.flatMap { [$0, $0] })
        let media = FileManager.default.temporaryDirectory.appending(path: "jammer-spec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: media) }
        let q = try p.applyingSpectralAttenuation(range: 30_000..<60_000, freq: 5_000...7_000, gainDB: -40, pool: pool, media: media)
        func render(_ x: Project) -> [Float] { let plan = PlanCompiler.compile(x, pool: pool); return plan.render(from: 0, frames: Int(plan.length)) }
        let a = render(p), b = render(q)
        #expect(Array(b[0..<60_000]) == Array(a[0..<60_000]))          // before the range (stereo frames × 2)
        #expect(Array(b[120_000...]) == Array(a[120_000...]))           // after it
        let inside = stride(from: 72_000, to: 108_000, by: 2).map { b[$0] }
        let insideA = stride(from: 72_000, to: 108_000, by: 2).map { a[$0] }
        #expect(level(insideA, 6_000) - level(inside, 6_000) > 30)
        #expect(throws: EffectError.self) { try p.applyingSpectralAttenuation(range: 0..<10, freq: 100...30_000, gainDB: -10, pool: pool, media: media) }
    }
}

@Suite("Spectral editing")
struct SpectralEditTests {
    let sr = 48_000.0

    /// A 1 kHz tone at −20 dBFS with a 20 ms noise click at 1.0 s; mono in a stereo file.
    private func clicked(_ dir: TempDir) throws -> (Project, SourcePool, [Float]) {
        let n = Int(sr * 2)
        let w = noise(count: n, seed: 5)
        var x = [Float](repeating: 0, count: n)
        for i in 0..<n {
            x[i] = Float(0.1 * sin(2 * .pi * 1_000 * Double(i) / sr))
            if i >= Int(sr), i < Int(sr * 1.02) { x[i] += 0.3 * w[i] }
        }
        let url = dir.file("c.wav")
        try writeWAV(x.flatMap { [$0, $0] }, to: url)
        var p = Project(source: SourceRef(name: "c", path: url.path, info: try AudioFileReader.info(at: url)))
        p.setTranscript(SourceTranscript(sourceID: p.sources[0].id, language: "sv-SE", engine: "t", words: [Word(text: "klick", start: Frame(0.95 * sr), end: Frame(1.1 * sr))]))
        return (p, SourcePool(), x)
    }

    private func left(_ p: Project, _ pool: SourcePool) -> [Float] {
        let r = PlanCompiler.compile(p, pool: pool).render(from: 0, frames: Int(p.length))
        return stride(from: 0, to: r.count, by: 2).map { r[$0] }
    }

    /// Mean power (dB) in a band over a stretch, from the spectrogram.
    private func band(_ x: [Float], _ t: ClosedRange<Double>, _ f: ClosedRange<Double>) -> Double {
        let cols = Spectral.spectrogram(Array(x[Int(t.lowerBound * sr)..<Int(t.upperBound * sr)]), size: 1_024, hop: 256)
        let k0 = Int(f.lowerBound / (sr / 1_024)), k1 = Int(f.upperBound / (sr / 1_024))
        let p = cols.flatMap { $0[k0...k1] }.map { pow(10, Double($0) / 10) }
        return 10 * log10(p.reduce(0, +) / Double(p.count))
    }

    private func toneAmp(_ x: [Float]) -> Double {
        var c = 0.0, s = 0.0
        for i in 0..<x.count { c += Double(x[i]) * cos(2 * .pi * 1_000 * Double(i) / sr); s += Double(x[i]) * sin(2 * .pi * 1_000 * Double(i) / sr) }
        return 2 * (c * c + s * s).squareRoot() / Double(x.count)
    }

    @Test("Heal removes a click above the tone and leaves the tone; words go with the new file")
    func heal() throws {
        let dir = TempDir()
        let (p, pool, x) = try clicked(dir)
        let q = try p.applyingSpectralEdit(.box(start: 0.995, end: 1.025, low: 2_500, high: 12_000), action: .heal, pool: pool, media: dir.file("m"))
        let y = left(q, pool)
        let before = band(x, 0.99...1.03, 3_000...8_000), after = band(y, 0.99...1.03, 3_000...8_000)
        #expect(before - after >= 30, "click band \(before) → \(after) dB")
        let tb = 20 * log10(toneAmp(Array(x[0..<Int(sr * 0.9)]) )), ta = 20 * log10(toneAmp(Array(y[0..<Int(sr * 0.9)])))
        #expect(abs(tb - ta) < 0.1)
        let mid = 20 * log10(toneAmp(Array(y[Int(sr * 0.95)..<Int(sr * 1.07)]))) - 20 * log10(toneAmp(Array(x[Int(sr * 0.5)..<Int(sr * 0.62)])))
        #expect(abs(mid) < 0.5, "tone through the healed area: \(mid) dB")
        #expect(q.placedWords().map(\.word.text) == ["klick"])
        #expect(q.placedWords()[0].start == Frame(0.95 * sr) && q.placedWords()[0].end == Frame(1.1 * sr) && !q.placedWords()[0].isPartial)
    }

    @Test("A lasso above the tone doesn't touch it; outside its time it's bit for bit")
    func polygon() throws {
        let dir = TempDir()
        let (p, pool, x) = try clicked(dir)
        let lasso = SpectralShape.polygon([.init(t: 0.4, f: 3_000), .init(t: 0.8, f: 3_000), .init(t: 0.8, f: 6_000), .init(t: 0.4, f: 6_000)])
        #expect(lasso.contains(t: 0.6, f: 4_000) && !lasso.contains(t: 0.6, f: 1_000))
        let q = try p.applyingSpectralEdit(lasso, action: .attenuate, gainDB: -40, pool: pool, media: dir.file("m"))
        let y = left(q, pool)
        #expect(Array(y[0..<Int(sr * 0.3)]) == Array(x[0..<Int(sr * 0.3)]))
        #expect(Array(y[Int(sr * 0.9)...]) == Array(x[Int(sr * 0.9)...]))
        let d = 20 * log10(toneAmp(Array(y[Int(sr * 0.45)..<Int(sr * 0.75)]))) - 20 * log10(toneAmp(Array(x[Int(sr * 0.45)..<Int(sr * 0.75)])))
        #expect(abs(d) < 0.1)
        let brush = SpectralShape.brush([.init(t: 0.5, f: 4_000), .init(t: 0.7, f: 5_000)], radius: 300, radiusTime: 0.02)
        #expect(brush.contains(t: 0.6, f: 4_500) && !brush.contains(t: 0.6, f: 2_000))
    }

    @Test("Heal refuses long areas (0.5 s is the limit) and areas with nothing on one side")
    func limits() throws {
        let dir = TempDir()
        let (p, pool, _) = try clicked(dir)
        let m = dir.file("m")
        do {
            _ = try p.applyingSpectralEdit(.box(start: 0.7, end: 1.3, low: 3_000, high: 6_000), action: .heal, pool: pool, media: m)
            Issue.record("0.6 s should be refused")
        } catch let e as SpectralEditError { #expect(e.reason == "too_long") }
        _ = try p.applyingSpectralEdit(.box(start: 0.75, end: 1.25, low: 3_000, high: 6_000), action: .heal, pool: pool, media: m)
        #expect(throws: SpectralEditError.noContext) { try p.applyingSpectralEdit(.box(start: 0, end: 0.1, low: 3_000, high: 6_000), action: .heal, pool: pool, media: m) }
        #expect(throws: SpectralEditError.self) { try p.applyingSpectralEdit(.polygon([.init(t: 1, f: 1), .init(t: 2, f: 2)]), action: .attenuate, pool: pool, media: m) }
        #expect(throws: SpectralEditError.self) { try p.applyingSpectralEdit(.box(start: 5, end: 6, low: 100, high: 200), action: .attenuate, pool: pool, media: m) }
    }
}
