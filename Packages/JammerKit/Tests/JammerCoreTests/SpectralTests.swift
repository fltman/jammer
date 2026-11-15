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
