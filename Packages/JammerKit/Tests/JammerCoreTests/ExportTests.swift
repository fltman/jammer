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
