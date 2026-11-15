import Foundation
import Testing
@testable import JammerCore

/// Calibration: how far does a decoded file sit from the source, for libopus (ffmpeg,
/// the reference) and for our writer? `JAMMER_OPUS_PROBE=1`.
@Suite("Opus delay probe", .enabled(if: ProcessInfo.processInfo.environment["JAMMER_OPUS_PROBE"] != nil))
struct OpusDelayProbe {
    func lag(_ a: [Float], _ b: [Float], frames: Int) -> Int {
        var best = 0, bestV = -Double.infinity
        for l in -40...40 {
            var v = 0.0
            for i in stride(from: 24_000, to: frames - 100, by: 3) where i + l >= 0 && (i + l) * 2 < b.count { v += Double(a[i * 2]) * Double(b[(i + l) * 2]) }
            if v > bestV { bestV = v; best = l }
        }
        return best
    }

    @Test("libopus vs Apple's encoder")
    func probe() throws {
        let dir = TempDir()
        let frames = 144_000
        // A tone plus clicks: sharp features pin the alignment.
        let s = (0..<frames).flatMap { i -> [Float] in
            var v = Float(0.3 * sin(2 * .pi * 440 * Double(i) / 48_000))
            if i % 4_800 == 0 { v += 0.5 }
            return [v, v]
        }
        let src = dir.file("s.wav")
        try writeWAV(s, to: src)
        let ref = dir.file("ref.opus"), ours = dir.file("ours.opus")
        _ = try run("/opt/homebrew/bin/ffmpeg", ["-v", "error", "-y", "-i", src.path, "-c:a", "libopus", "-b:a", "96k", ref.path])
        var (p, pool) = memoryProject(s)
        p.sampleRate = 48_000
        try OggOpusWriter.export(PlanCompiler.compile(p, pool: pool), range: 0..<p.length, to: ours, bitRate: 96_000)
        for (name, url) in [("libopus (ffmpeg)", ref), ("Apple encoder + our Ogg", ours)] {
            let wav = dir.file("\(name.prefix(4)).wav")
            _ = try run("/opt/homebrew/bin/ffmpeg", ["-v", "error", "-y", "-i", url.path, "-ar", "48000", "-c:a", "pcm_f32le", wav.path])
            let info = try AudioFileReader.info(at: wav)
            let d = SourcePool().read(SourceRef(name: "d", path: wav.path, info: info), from: 0, count: Int(info.frames))
            print("OPUS  \(name): \(info.frames) frames (source \(frames)), lag \(lag(s, d, frames: frames))")
        }
    }
}
