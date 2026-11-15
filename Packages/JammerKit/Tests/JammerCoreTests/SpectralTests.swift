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
}
