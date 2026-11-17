import Foundation
import Testing
@testable import JammerCore

/// ITU-R BS.2217-2 (10/2016), "Compliance material for Recommendation ITU-R BS.1770": each file reads its
/// value within ±0.1 LKFS (file-based). The files are the ITU's ("All rights reserved"), so they are not in the
/// repository: fetched once by Anders's leave (2026-11-17) and pointed at with JAMMER_BS2217=<folder>.
/// The 8- and 12-channel files carry no channel mask; their order is the report's (BS.2051: L R C LFE Lss Rss
/// Lrs Rrs, then Tfl Tfr Tbl Tbr), which puts the sides before the rears: what a file without a mask is heard
/// as when opened (`SourceRef.opened()`, Anders's choice). The test reads them as the app does, through a
/// project's render, and measures what the document plays.
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

    /// The file opened as a document is, in the order chosen, and what the document plays.
    static func played(_ name: String, order: ChannelOrder?) throws -> (samples: [Float], channels: Int) {
        let url = folder.appendingPathComponent(name)
        var ref = SourceRef(name: name, path: url.path, info: try AudioFileReader.info(at: url)).opened()
        if let order, ref.needsOrder { ref.unmaskedOrder = order }
        let p = Project(source: ref)
        return (PlanCompiler.compile(p, pool: SourcePool()).render(from: 0, frames: Int(ref.info.frames)), p.channels)
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
        let (x, docChannels) = try Self.played(c.0, order: nil)
        #expect(docChannels == n)
        let ours = try #require(Self.integrated(x, channels: n))
        print("BS2217 \(c.0): \(String(format: "%.3f", ours)) (the report: \(c.1))")
        #expect(abs(ours - c.1) <= 0.1, "\(c.0): \(ours)")
        if n == 8 || n == 12 {
            // Heard in the WAV order instead (the other choice): said, not held; the same as the raw file measured.
            let (w, _) = try Self.played(c.0, order: .wav)
            let asIs = Self.integrated(w, channels: n) ?? .nan
            #expect(abs(asIs - (Self.integrated(raw, channels: n) ?? .nan)) < 1e-9)
            print("BS2217 \(c.0) in the WAV order: \(String(format: "%.3f", asIs))")
        }
    }
}
