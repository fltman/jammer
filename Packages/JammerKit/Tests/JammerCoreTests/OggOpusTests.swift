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

    @Test("Chapters as CHAPTERxxx comments: ffprobe reads them, also when the tags span pages")
    func chapters() throws {
        let probe = "/opt/homebrew/bin/ffprobe"
        guard FileManager.default.fileExists(atPath: probe) else { return }
        let dir = TempDir()
        let (p, pool) = memoryProject(tone(48_000 * 4, rate: 48_000), sampleRate: 48_000)
        let plan = PlanCompiler.compile(p, pool: pool)
        let few = [Chapter(title: "Intro", start: 0, end: 1.5), Chapter(title: "Ämne två", start: 1.5, end: 4)]
        // 400 chapters with long titles: OpusTags passes 65 KB and must continue onto more pages.
        let many = (0..<400).map { Chapter(title: "Chapter \($0) " + String(repeating: "x", count: 200), start: Double($0) * 0.01, end: Double($0 + 1) * 0.01) }
        #expect(OggOpusWriter.chapterComments(few) == ["CHAPTER000=00:00:00.000", "CHAPTER000NAME=Intro", "CHAPTER001=00:00:01.500", "CHAPTER001NAME=Ämne två"])
        for (name, list) in [("few", few), ("many", many)] {
            let url = dir.file("\(name).opus")
            try EncodedWriter.export(plan, range: 0..<p.length, to: url, options: .init(format: .opus, bitRate: 64_000, chapters: list))
            let r = try run(probe, ["-v", "error", "-show_chapters", "-show_entries", "stream=codec_name", "-of", "json", url.path])
            #expect(r.status == 0, "\(r.output)")
            let json = try JSONSerialization.jsonObject(with: Data(r.output.utf8)) as? [String: Any]
            let chapters = json?["chapters"] as? [[String: Any]] ?? []
            #expect(chapters.count == list.count, "\(name): \(chapters.count) chapters")
            if name == "few" {
                #expect((chapters.last?["tags"] as? [String: String])?["title"] == "Ämne två")
                #expect(abs((Double(chapters.last?["start_time"] as? String ?? "") ?? 0) - 1.5) < 0.001)
            }
        }
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
