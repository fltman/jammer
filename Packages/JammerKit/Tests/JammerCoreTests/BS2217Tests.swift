import Foundation
import Testing
@testable import JammerCore

/// ITU-R BS.2217-2 (10/2016), "Compliance material for Recommendation ITU-R BS.1770": each file reads its
/// value within ±0.1 LKFS (file-based). The files are the ITU's ("All rights reserved"), so they are not in the
/// repository: fetched once by Anders's leave (2026-11-17) and pointed at with JAMMER_BS2217=<folder>.
/// The 8- and 12-channel files carry no channel mask; their order is the report's (BS.2051: L R C LFE Lss Rss
/// Lrs Rrs, then Tfl Tfr Tbl Tbr), which puts the sides before the rears. Jämmer's 7.1 and 7.1.4 are in the
/// WAV mask's order (rears before sides), so the test moves the channels to Jämmer's order, as a mask would.
@Suite("BS.2217: the ITU's compliance files for BS.1770", .enabled(if: ProcessInfo.processInfo.environment["JAMMER_BS2217"] != nil))
struct BS2217Tests {
    static let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JAMMER_BS2217"] ?? "/nonexistent")

    /// 16-bit PCM WAV as floats, with its channel count.
    static func read(_ name: String) throws -> (samples: [Float], channels: Int) {
        let d = try Data(contentsOf: folder.appendingPathComponent(name))
        func u32(_ i: Int) -> Int { Int(d[i]) | Int(d[i + 1]) << 8 | Int(d[i + 2]) << 16 | Int(d[i + 3]) << 24 }
        func u16(_ i: Int) -> Int { Int(d[i]) | Int(d[i + 1]) << 8 }
        var i = 12, channels = 0
        while i + 8 <= d.count {
            let id = String(decoding: d[i..<i + 4], as: UTF8.self), size = u32(i + 4)
            if id == "fmt " { channels = u16(i + 10); #expect(u16(i + 22) == 16 && u32(i + 12) == 48_000) }
            if id == "data" {
                let count = min(size, d.count - i - 8) / 2
                let samples = d.withUnsafeBytes { raw in
                    (0..<count).map { k in Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i + 8 + 2 * k, as: Int16.self))) / 32_768 }
                }
                return (samples, channels)
            }
            i += 8 + size + (size & 1)
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    /// The report's order into Jämmer's: Lss Rss (4, 5) and Lrs Rrs (6, 7) change places.
    static func toJammer(_ x: [Float], channels n: Int) -> [Float] {
        guard n == 8 || n == 12 else { return x }
        let from = (0..<n).map { $0 == 4 ? 6 : $0 == 5 ? 7 : $0 == 6 ? 4 : $0 == 7 ? 5 : $0 }
        var y = x
        for f in 0..<x.count / n { for c in 0..<n { y[f * n + c] = x[f * n + from[c]] } }
        return y
    }

    static func integrated(_ x: [Float], channels n: Int) -> Double? {
        var m = LoudnessMeter(sampleRate: 48_000, channels: n)
        m.process(x)
        return m.result.integrated
    }

    static let cases: [(String, Double)] = [
        ("1770-2 Conf Mono Voice+Music-23LKFS.wav", -23), ("1770-2 Conf Mono Voice+Music-24LKFS.wav", -24),
        ("1770-2 Conf Stereo VinL+R-23LKFS.wav", -23), ("1770-2 Conf Stereo VinL+R-24LKFS.wav", -24),
        ("1770-2 Conf 6ch VinCntr-24LKFS.wav", -24),
        ("1770-2 Conf 6ch VinL+R-23LKFS.wav", -23), ("1770-2 Conf 6ch VinL+R-24LKFS.wav", -24),
        ("1770-2 Conf 6ch VinL-R-C-23LKFS.wav", -23), ("1770-2 Conf 6ch VinL-R-C-24LKFS.wav", -24),
        ("1770Conf-23LKFS-8channel.wav", -23), ("1770Conf-24LKFS-8channel.wav", -24),
        ("1770Conf-23LKFS-12channel.wav", -23),
    ]

    @Test("Mono, stereo, 5.1, 7.1 (0+7+0) and 7.1.4 (4+7+0): each file reads its value within ±0.1 LKFS", arguments: cases)
    func compliance(_ c: (String, Double)) throws {
        let (raw, n) = try Self.read(c.0)
        let ours = try #require(Self.integrated(Self.toJammer(raw, channels: n), channels: n))
        print("BS2217 \(c.0): \(String(format: "%.3f", ours)) (the report: \(c.1))")
        #expect(abs(ours - c.1) <= 0.1, "\(c.0): \(ours)")
        if n == 8 || n == 12 {
            // Read in the WAV mask's order instead (what Jämmer does with a file that has no mask): said, not held.
            let asIs = Self.integrated(raw, channels: n) ?? .nan
            print("BS2217 \(c.0) in the mask's order: \(String(format: "%.3f", asIs))")
        }
    }
}
