import AVFoundation
import Foundation
import Testing
@testable import JammerCore

@Suite("Ogg Opus")
struct OggOpusTests {
    @Test("Ogg's CRC-32 matches its check value")
    func crc() {
        #expect(OggOpusWriter.crc(Data("123456789".utf8)) == 0x89A1_897F)
    }

    func tone(_ frames: Int, rate: Double) -> [Float] {
        (0..<frames).flatMap { i -> [Float] in
            let v = Float(0.4 * sin(2 * .pi * 440 * Double(i) / rate) * min(1, Double(i) / 4_800))
            return [v, v * 0.5]
        }
    }

    func export(_ s: [Float], rate: Double, to url: URL) throws {
        var (p, pool) = memoryProject(s, sampleRate: rate)
        p.sampleRate = rate
        try OggOpusWriter.export(PlanCompiler.compile(p, pool: pool), range: 0..<p.length, to: url, bitRate: 96_000)
    }

    @Test("ffmpeg reads it: Ogg, Opus, the exact length, and the signal in place", arguments: [48_000.0, 44_100.0])
    func ffmpeg(rate: Double) throws {
        let ffmpeg = "/opt/homebrew/bin/ffmpeg"
        guard FileManager.default.fileExists(atPath: ffmpeg) else { return }
        let dir = TempDir()
        let frames = Int(rate * 3)
        let s = tone(frames, rate: rate)
        let url = dir.file("t.opus")
        try export(s, rate: rate, to: url)
        let probe = try run("/opt/homebrew/bin/ffprobe", ["-v", "error", "-show_entries", "format=format_name:stream=codec_name,channels,sample_rate,duration", "-of", "default=nw=1", url.path])
        #expect(probe.status == 0, "\(probe.output)")
        #expect(probe.output.contains("format_name=ogg") && probe.output.contains("codec_name=opus") && probe.output.contains("channels=2"))
        // Decode at the original rate; the length must match (pre-skip and end trim applied).
        let wav = dir.file("d.wav")
        let r = try run(ffmpeg, ["-v", "error", "-y", "-i", url.path, "-ar", String(Int(rate)), "-c:a", "pcm_f32le", wav.path])
        #expect(r.status == 0, "\(r.output)")
        let info = try AudioFileReader.info(at: wav)
        #expect(abs(Int(info.frames) - frames) <= Int(rate / 1_000), "decoded \(info.frames) frames, expected \(frames)")
        // Lined up: the decoded tone correlates best with the original at lag 0.
        let ref = SourceRef(name: "d", path: wav.path, info: info)
        let d = SourcePool().read(ref, from: 0, count: Int(info.frames))
        var best = 0, bestV = -Double.infinity
        for lag in -40...40 {
            var v = 0.0
            for i in stride(from: Int(rate / 2), to: frames - 100, by: 7) where i + lag >= 0 && (i + lag) * 2 < d.count { v += Double(s[i * 2]) * Double(d[(i + lag) * 2]) }
            if v > bestV { bestV = v; best = lag }
        }
        #expect(abs(best) <= 2, "shifted by \(best)")
    }

    @Test("macOS's own decoder reads it (the stack Apple Podcasts and QuickTime use)")
    func apple() throws {
        let dir = TempDir()
        let url = dir.file("t.opus")
        try export(tone(96_000, rate: 48_000), rate: 48_000, to: url)
        let f = try AVAudioFile(forReading: url)
        #expect(f.fileFormat.channelCount == 2)
        #expect(abs(f.length - 96_000) <= 960, "length \(f.length)")
    }
}
