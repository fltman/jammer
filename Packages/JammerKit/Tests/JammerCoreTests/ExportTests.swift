import AVFoundation
import Foundation
import Testing
@testable import JammerCore

@Suite("Encoded export")
struct ExportTests {
    /// Values exact in 16-bit, so lossless formats must give them back unchanged.
    func signal(_ frames: Int) -> [Float] {
        (0..<(frames * 2)).map { i in Float(Int(32_000 * sin(Double(i / 2) * 0.031 + Double(i % 2))) ) / 32_768 }
    }

    func decode(_ url: URL) throws -> (samples: [Float], rate: Double, channels: Int) {
        let f = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        let n = Int(buf.frameLength) * Int(f.processingFormat.channelCount)
        return (Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: n)), f.processingFormat.sampleRate, Int(f.processingFormat.channelCount))
    }

    @Test("Lossless formats decode to exactly the samples that went in", arguments: [ExportFormat.aiff, .flac, .alac])
    func lossless(format: ExportFormat) throws {
        let dir = TempDir()
        let s = signal(48_000)
        let (p, pool) = memoryProject(s)
        let plan = PlanCompiler.compile(p, pool: pool)
        let url = dir.file("out.\(format.fileExtension)")
        try EncodedWriter.export(plan, range: 0..<plan.length, to: url, options: .init(format: format, bitDepth: 16))
        let d = try decode(url)
        #expect(d.rate == 48_000 && d.channels == 2)
        #expect(d.samples == s, "\(format) changed samples")
    }

    @Test("AAC keeps length and level")
    func aac() throws {
        let dir = TempDir()
        let s = signal(96_000)
        let (p, pool) = memoryProject(s)
        let plan = PlanCompiler.compile(p, pool: pool)
        let url = dir.file("out.m4a")
        try EncodedWriter.export(plan, range: 0..<plan.length, to: url, options: .init(format: .aac, bitRate: 192_000))
        let d = try decode(url)
        #expect(abs(d.samples.count / 2 - 96_000) < 4_096)
        // Lossy: compare loudness (RMS), not peaks, which a codec may overshoot.
        func rms(_ x: [Float]) -> Double { 10 * log10(x.reduce(0) { $0 + Double($1 * $1) } / Double(x.count)) }
        #expect(abs(rms(d.samples) - rms(s)) < 1)
        #expect(throws: ExportError.self) { try EncodedWriter(url: dir.file("x.flac"), options: .init(format: .flac, bitDepth: 32), channels: 2, sampleRate: 48_000) }
    }
}


@Suite("M4A chapters")
struct M4AChapterTests {
    @Test("AAC and ALAC carry a chapter track that AVFoundation and ffprobe read; ALAC stays lossless")
    func chapters() async throws {
        let dir = TempDir()
        let x = sine(440, amplitudeDB: -12, seconds: 6)
        let wav = dir.file("s.wav")
        try writeWAV(x, to: wav, encoding: .int24)
        let p = Project(source: SourceRef(name: "s", path: wav.path, info: try AudioFileReader.info(at: wav)))
        let plan = PlanCompiler.compile(p, pool: SourcePool())
        let list = [Chapter(title: "Intro", start: 0, end: 2), Chapter(title: "Ämne två", start: 2, end: 4.5), Chapter(title: "Slut", start: 4.5, end: 6)]
        for format in [ExportFormat.aac, .alac] {
            let url = dir.file("c-\(format.rawValue).m4a")
            try EncodedWriter.export(plan, range: 0..<p.length, to: url, options: .init(format: format, bitDepth: 24, bitRate: 128_000, chapters: list, language: "sv-SE"))
            let asset = AVURLAsset(url: url)
            let groups = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: ["sv"])
            let titles = try await groups.asyncMap { g in try await g.items.first?.load(.stringValue) ?? "" }
            let locales = try await asset.load(.availableChapterLocales)
            #expect(!locales.isEmpty && locales.allSatisfy { $0.language.languageCode?.identifier == "sv" }, "\(locales.map(\.identifier))")
            #expect(titles == ["Intro", "Ämne två", "Slut"], "\(format)")
            #expect(groups.map { ($0.timeRange.start.seconds * 1_000).rounded() / 1_000 } == [0, 2, 4.5], "\(format)")
            let duration = try await asset.load(.duration).seconds
            #expect(abs(duration - 6) < 0.05, "\(format) duration \(duration)")
            let probe = "/opt/homebrew/bin/ffprobe"
            if FileManager.default.fileExists(atPath: probe) {
                let r = try run(probe, ["-v", "error", "-show_chapters", "-of", "csv=p=0", url.path])
                #expect(r.output.contains("Intro") && r.output.contains("Slut"), "\(r.output)")
            }
            if format == .alac {
                let file = try AVAudioFile(forReading: url)
                let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
                try file.read(into: buf)
                #expect(Int(file.length) == x.count / 2)
                let l = UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))
                let ref = stride(from: 0, to: x.count, by: 2).map { (Float(Int32(($0 < x.count ? x[$0] : 0) * 8_388_608).clamped(to: -8_388_608...8_388_607)) / 8_388_608) }
                #expect(zip(l, ref).allSatisfy { abs($0 - $1) < 1e-6 }, "ALAC must decode to the 24-bit samples")
            }
        }
    }
}

extension Sequence {
    func asyncMap<T>(_ f: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []
        for e in self { out.append(try await f(e)) }
        return out
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}
