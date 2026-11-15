import AVFoundation
import Foundation
import JammerCore
import Testing
@testable import JammerMP3

@Suite("MP3")
struct MP3Tests {
    func run(_ tool: String, _ args: [String]) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test("Encodes; ffmpeg and macOS read it at the right length and level", arguments: [1, 2])
    func roundTrip(channels: Int) throws {
        MP3Writer.register()
        defer { EncodedWriter.mp3Factory = nil }
        #expect(ExportFormat.available.contains(.mp3))
        let dir = FileManager.default.temporaryDirectory.appending(path: "jammer-mp3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let frames = 48_000 * 3
        let s = (0..<frames).flatMap { i -> [Float] in
            let v = Float(0.4 * sin(2 * .pi * 440 * Double(i) / 48_000))
            return channels == 1 ? [v] : [v, v * 0.7]
        }
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: channels, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: Int64(frames), chunks: [], bext: nil, ixml: nil, markers: [])
        let ref = SourceRef(name: "t", path: "/dev/null", info: info)
        let pool = SourcePool()
        pool.register(ref.id, memory: s, channels: channels)
        var p = Project(source: ref)
        p.channels = channels
        let plan = PlanCompiler.compile(p, pool: pool)
        let url = dir.appending(path: "t.mp3")
        try EncodedWriter.export(plan, range: 0..<plan.length, to: url, options: .init(format: .mp3, bitRate: 160_000))
        // macOS's decoder.
        let f = try AVAudioFile(forReading: url)
        #expect(Int(f.fileFormat.channelCount) == channels)
        #expect(abs(Int(f.length) - frames) <= 1_152, "macOS length \(f.length)")
        // ffmpeg, if installed: codec and gapless length from the LAME tag.
        let ffmpeg = "/opt/homebrew/bin/ffmpeg"
        guard FileManager.default.fileExists(atPath: ffmpeg) else { return }
        let probe = try run("/opt/homebrew/bin/ffprobe", ["-v", "error", "-show_entries", "stream=codec_name", "-of", "default=nw=1", url.path])
        #expect(probe.1.contains("codec_name=mp3"))
        let wav = dir.appending(path: "d.wav")
        _ = try run(ffmpeg, ["-v", "error", "-y", "-i", url.path, "-c:a", "pcm_f32le", wav.path])
        let d = try AudioFileReader.info(at: wav)
        #expect(abs(Int(d.frames) - frames) <= 2, "ffmpeg length \(d.frames)")
        let decoded = SourcePool().read(SourceRef(name: "d", path: wav.path, info: d), from: 0, count: Int(d.frames))
        func rms(_ x: [Float]) -> Double { 10 * log10(x.reduce(0) { $0 + Double($1 * $1) } / Double(max(1, x.count))) }
        #expect(abs(rms(decoded) - rms(s)) < 0.5)
    }
}
