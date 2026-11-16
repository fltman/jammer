import Foundation
import Testing
@testable import JammerCore

/// TPDF dither, against what the arithmetic says it must do. One step of 16 bits (1 LSB) is 1/32768.
/// Rounding alone leaves an error that is uniform over ±½ LSB: RMS LSB/√12, −101.1 dBFS. Triangular
/// dither of ±1 LSB adds LSB²/6, so the total is LSB/2: −96.33 dBFS, and the error no longer depends
/// on the signal, which is the point.
@Suite("Dither")
struct DitherTests {
    static func written(_ x: [Float], dither: Bool, bits: WAVWriter.Encoding = .int16) throws -> (samples: [Double], dithered: Int64) {
        let url = FileManager.default.temporaryDirectory.appending(path: "jammer-dither-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let w = try WAVWriter(url: url, options: .init(encoding: bits, channels: 1, sampleRate: 48_000, dither: dither))
        // In odd pieces, as an export does.
        var at = 0
        for size in [1, 7, 4_096, 65_536] where at < x.count { let n = min(size, x.count - at); try w.write(Array(x[at..<(at + n)])); at += n }
        if at < x.count { try w.write(Array(x[at...])) }
        try w.finish()
        let info = try AudioFileReader.info(at: url)
        let data = try Data(contentsOf: url)
        let n = Int(info.frames)
        var out = [Double](repeating: 0, count: n)
        data.withUnsafeBytes { raw in
            for i in 0..<n {
                let o = Int(info.dataOffset) + i * bits.bytes
                if bits == .int16 { out[i] = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: Int16.self))) / 32_768 }
                else { let b0 = Int32(raw[o]), b1 = Int32(raw[o + 1]), b2 = Int32(Int8(bitPattern: raw[o + 2])); out[i] = Double(b0 | b1 << 8 | b2 << 16) / 8_388_608 }
            }
        }
        return (out, w.ditheredSamples)
    }
    static func rmsDB(_ e: [Double]) -> Double { 10 * log10(e.reduce(0) { $0 + $1 * $1 } / Double(e.count)) }

    @Test("The error is LSB/2 with dither and LSB/√12 without, and has no offset")
    func level() throws {
        let n = 48_000 * 10
        let x = (0..<n).map { Float(0.25 * sin(2 * .pi * 997 * Double($0) / 48_000)) }
        let plain = try Self.written(x, dither: false), dithered = try Self.written(x, dither: true)
        let e0 = zip(plain.samples, x).map { $0 - Double($1) }, e1 = zip(dithered.samples, x).map { $0 - Double($1) }
        #expect(abs(Self.rmsDB(e0) - -101.09) < 0.15, "\(Self.rmsDB(e0))")
        #expect(abs(Self.rmsDB(e1) - -96.33) < 0.15, "\(Self.rmsDB(e1))")
        #expect(abs(e1.reduce(0, +) / Double(n)) < 0.02 / 32_768 && plain.dithered == 0 && dithered.dithered > Int64(n) * 99 / 100)
        // 24 bits: 48.16 dB further down would be −144.49. A 32-bit float source has only a few bits under a
        // 24-bit step, though (at this level its own steps are 1/16 of one), so about one sample in ten
        // already sits on a 24-bit step and is left as it is: the error comes out a little lower, −144.9.
        let d24 = try Self.written(x, dither: true, bits: .int24)
        let e24 = Self.rmsDB(zip(d24.samples, x).map { $0 - Double($1) })
        #expect(e24 < -144.49 && e24 > -145.4 && d24.dithered > Int64(n) * 85 / 100 && d24.dithered < Int64(n) * 95 / 100, "\(e24), dithered \(d24.dithered) of \(n)")
    }

    @Test("A tone at −100 dBFS, a third of a step: gone without dither, there with it")
    func linearity() throws {
        let n = 48_000 * 20, amp = pow(10, -100.0 / 20)
        let tone = (0..<n).map { sin(2 * .pi * 1_000 * Double($0) / 48_000) }
        let x = tone.map { Float(amp * $0) }
        let plain = try Self.written(x, dither: false), dithered = try Self.written(x, dither: true)
        #expect(plain.samples.allSatisfy { $0 == 0 })
        // The tone's amplitude in the dithered file, by projecting onto it.
        let found = 2 * zip(dithered.samples, tone).reduce(0) { $0 + $1.0 * $1.1 } / Double(n)
        #expect(abs(found / amp - 1) < 0.1, "\(20 * log10(found)) dBFS")
    }

    @Test("Audio that is already 16 bits is not dithered again; silence stays silence")
    func alreadyThere() throws {
        var rng = SystemRandomNumberGenerator()
        let exact = (0..<48_000).map { _ in Float(Int16.random(in: Int16.min...Int16.max, using: &rng)) / 32_768 }
        let plain = try Self.written(exact, dither: false), dithered = try Self.written(exact, dither: true)
        #expect(dithered.samples == plain.samples && dithered.dithered == 0 && plain.samples == exact.map(Double.init))
        let silence = try Self.written([Float](repeating: 0, count: 10_000), dither: true)
        #expect(silence.samples.allSatisfy { $0 == 0 } && silence.dithered == 0)
        // Exact on the 16-bit steps is exact on the 24-bit ones too.
        #expect(try Self.written(exact, dither: true, bits: .int24).dithered == 0)
        // Half the file exact, half not: only the second half is dithered.
        let mixed = exact + (0..<48_000).map { Float(0.1 * sin(Double($0) * 0.05)) }
        let m = try Self.written(mixed, dither: true)
        #expect(Array(m.samples[0..<48_000]) == Array(plain.samples) && m.dithered > 47_000 && m.dithered <= 48_000)
    }
}
