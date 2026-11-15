import Foundation
import JammerEngine
import Testing
@testable import JammerCore

@Suite("Audio files")
struct AudioFileTests {
    @Test("WAV round trip keeps samples, bext, iXML, markers and foreign chunks", arguments: WAVWriter.Encoding.allCases)
    func roundTrip(encoding: WAVWriter.Encoding) throws {
        let dir = TempDir()
        let url = dir.file("t.wav")
        // Values exactly representable in every encoding.
        let samples = (0..<20_000).map { Float(($0 * 37) % 65_536 - 32_768) / 32_768 }
        var bext = BroadcastExtension()
        bext.description = "Intervju med Åsa — tagning 3"
        bext.originator = "Jammer"
        bext.originationDate = "2026-11-15"
        bext.originationTime = "06:30:00"
        bext.timeReference = 172_800_000_123
        bext.loudnessValue = -23.05
        bext.maxTruePeakLevel = -1.5
        bext.codingHistory = "A=PCM,F=48000,W=24,M=stereo\r\n"
        let options = WAVWriter.Options(encoding: encoding, channels: 2, sampleRate: 48_000, bext: bext,
                                        ixml: "<BWFXML><PROJECT>Jämmer</PROJECT></BWFXML>",
                                        markers: [FileMarker(position: 1_000, name: "Början"), FileMarker(position: 5_000, length: 2_000, name: "Svar")],
                                        foreignChunks: [(id: "zzzz", payload: Data([1, 2, 3]))])
        let w = try WAVWriter(url: url, options: options)
        try w.write(samples)
        try w.finish()

        let info = try AudioFileReader.info(at: url)
        #expect(info.container == .wav)
        #expect(info.channels == 2)
        #expect(info.sampleRate == 48_000)
        #expect(info.frames == 10_000)
        #expect(info.sampleFormat.bitsPerSample == [WAVWriter.Encoding.int16: 16, .int24: 24, .float32: 32][encoding])
        #expect(info.bext?.description == bext.description)
        #expect(info.bext?.timeReference == bext.timeReference)
        #expect(info.bext?.loudnessValue == -23.05)
        #expect(info.bext?.maxTruePeakLevel == -1.5)
        #expect(info.bext?.loudnessRange == nil)
        #expect(info.bext?.codingHistory == bext.codingHistory)
        #expect(info.ixml == "<BWFXML><PROJECT>Jämmer</PROJECT></BWFXML>")
        #expect(info.markers == options.markers)
        #expect(info.foreignChunks.map(\.id) == ["zzzz"])

        let src = try #require(AudioFileReader.openSource(info, at: url))
        defer { jm_source_release(src) }
        var back = [Float](repeating: 0, count: samples.count)
        #expect(jm_source_read(src, 0, 10_000, &back) == 10_000)
        #expect(back == samples)
    }

    @Test("RF64 files are written and read")
    func rf64() throws {
        let dir = TempDir()
        let url = dir.file("big.wav")
        let samples = noise(count: 4_800 * 2)
        var options = WAVWriter.Options(encoding: .float32, channels: 2, sampleRate: 48_000)
        options.alwaysRF64 = true
        let w = try WAVWriter(url: url, options: options)
        try w.write(samples)
        try w.finish()
        let head = try FileHandle(forReadingFrom: url).read(upToCount: 4)
        #expect(head == Data("RF64".utf8))
        let info = try AudioFileReader.info(at: url)
        #expect(info.container == .rf64)
        #expect(info.frames == 4_800)
    }

    @Test("Apple's tools read what Jammer writes, and Jammer reads Apple's AIFF and WAV")
    func appleInterop() throws {
        let dir = TempDir()
        let wav = dir.file("a.wav")
        let samples = (0..<9_600).map { Float(($0 * 101) % 65_536 - 32_768) / 32_768 }
        try writeWAV(samples, to: wav, encoding: .int16)
        let probe = try run("/usr/bin/afinfo", [wav.path])
        #expect(probe.status == 0)
        #expect(probe.output.contains("4800 frames") || probe.output.contains("audio packets: 4800"))

        for (name, format) in [("b.aif", ["-f", "AIFF", "-d", "BEI16"]), ("c.aif", ["-f", "AIFC", "-d", "BEF32"]),
                               ("d.wav", ["-f", "WAVE", "-d", "LEI24"])] {
            let out = dir.file(name)
            let r = try run("/usr/bin/afconvert", format + [wav.path, out.path])
            #expect(r.status == 0, "\(r.output)")
            let info = try AudioFileReader.info(at: out)
            #expect(info.frames == 4_800)
            #expect(info.channels == 2)
            let src = try #require(AudioFileReader.openSource(info, at: out))
            defer { jm_source_release(src) }
            var back = [Float](repeating: 0, count: samples.count)
            #expect(jm_source_read(src, 0, 4_800, &back) == 4_800)
            #expect(back == samples, "\(name)")
        }
    }

    @Test("Compressed files are decoded into a float WAV with the same length")
    func importCompressed() throws {
        let dir = TempDir()
        let wav = dir.file("src.wav")
        try writeWAV(sine(440, amplitudeDB: -6, seconds: 2), to: wav, encoding: .int16)
        let m4a = dir.file("src.m4a")
        let r = try run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", "-b", "192000", wav.path, m4a.path])
        #expect(r.status == 0, "\(r.output)")
        let result = try AudioImporter.importFile(m4a, mediaFolder: dir.file("Media"))
        #expect(result.decoded)
        #expect(result.source.info.sampleFormat == .float32)
        #expect(abs(result.source.info.frames - 96_000) < 4_096) // AAC priming may pad
        // A PCM file at the same rate is used in place.
        let direct = try AudioImporter.importFile(wav, mediaFolder: dir.file("Media"))
        #expect(!direct.decoded)
        #expect(direct.source.path == wav.path)
        // A different project rate converts.
        let resampled = try AudioImporter.importFile(wav, sampleRate: 44_100, mediaFolder: dir.file("Media"))
        #expect(resampled.decoded)
        #expect(resampled.source.info.sampleRate == 44_100)
        #expect(abs(resampled.source.info.frames - 88_200) < 64)
    }

    @Test("Non-audio files are refused clearly")
    func refuse() throws {
        let dir = TempDir()
        let url = dir.file("x.wav")
        try Data("not audio at all".utf8).write(to: url)
        #expect(throws: AudioFileError.self) { try AudioFileReader.info(at: url) }
    }
}
