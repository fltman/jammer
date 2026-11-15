import Foundation
import Testing
@testable import JammerCore

/// "Edit in Jämmer" (SIBLINGS.md §6): Save Back writes into the same file, same format,
/// rate and bit depth, in place, and an untouched document writes the same audio back.
@Suite("Linked files")
struct LinkedFileTests {
    let sr = 48_000.0

    private func inode(_ url: URL) throws -> UInt64 {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }

    /// The document as the app builds it: from a copy of the file, never the file itself.
    private func project(from url: URL, dir: TempDir) throws -> (Project, SourcePool) {
        let copy = dir.file("copy-\(UUID().uuidString).\(url.pathExtension)")
        try FileManager.default.copyItem(at: url, to: copy)
        let r = try AudioImporter.importFile(copy, mediaFolder: dir.file("media"))
        return (Project(source: r.source), SourcePool())
    }

    private func samples(_ url: URL) throws -> [Float] {
        let info = try AudioFileReader.info(at: url)
        return SourcePool().read(SourceRef(name: "x", path: url.path, info: info), from: 0, count: Int(info.frames))
    }

    @Test("WAV: same inode, same bits when untouched, metadata and foreign chunks kept; edits land")
    func wav() throws {
        let dir = TempDir()
        let url = dir.file("clip.wav")
        let x = sine(440, amplitudeDB: -12, seconds: 1)
        var o = WAVWriter.Options(encoding: .int24, channels: 2, sampleRate: sr)
        o.ixml = "<BWFXML><PROJECT>Flimmer</PROJECT></BWFXML>"
        o.foreignChunks = [("abcd", Data("keep me".utf8)), ("LIST", Data("INFO".utf8) + Data("INAM".utf8) + Data([4, 0, 0, 0]) + Data("Take".utf8))]
        let w = try WAVWriter(url: url, options: o)
        try w.write(x)
        try w.finish()
        let before = try samples(url), node = try inode(url)
        let link = try #require(LinkedFile(url: url, requester: "Flimmer"))
        #expect(link.format == .wav && link.bitDepth == 24 && !link.isFloat)
        var (p, pool) = try project(from: url, dir: dir)
        try link.write(PlanCompiler.compile(p, pool: pool), range: 0..<p.length, markers: [], scratch: dir.file("scratch"))
        #expect(try inode(url) == node)
        #expect(try samples(url) == before)
        let info = try AudioFileReader.info(at: url)
        #expect(info.sampleFormat == .int24 && info.sampleRate == sr && info.channels == 2)
        #expect(info.ixml == o.ixml)
        #expect(info.chunks.contains { $0.id == "abcd" } && info.chunks.contains { $0.id == "LIST" })
        // An edit: 6 dB down, and a marker.
        try p.changeGain(0..<p.length, by: -6)
        try link.write(PlanCompiler.compile(p, pool: pool), range: 0..<p.length, markers: [FileMarker(position: 24_000, length: 0, name: "Here")],
                       scratch: dir.file("scratch"))
        let after = try samples(url)
        #expect(try inode(url) == node)
        #expect(abs((after.map(abs).max() ?? 0) - (before.map(abs).max() ?? 0) * 0.501) < 0.001)
        #expect(try AudioFileReader.info(at: url).markers.map(\.name) == ["Here"])
        #expect(!FileManager.default.fileExists(atPath: dir.file("scratch").appending(path: "x").path))
    }

    @Test("AIFF 16-bit and FLAC 24-bit come back in their own format, bit for bit when untouched")
    func aiffAndFlac() throws {
        let dir = TempDir()
        let x = sine(1_000, amplitudeDB: -6, seconds: 0.5)
        let wav = dir.file("src.wav")
        try writeWAV(x, to: wav, encoding: .int24)
        let srcPlan = PlanCompiler.compile(Project(source: SourceRef(name: "s", path: wav.path, info: try AudioFileReader.info(at: wav))), pool: SourcePool())
        for (name, format, bits) in [("clip.aiff", ExportFormat.aiff, 16), ("clip.flac", .flac, 24)] {
            let url = dir.file(name)
            try EncodedWriter.export(srcPlan, range: 0..<srcPlan.length, to: url, options: .init(format: format, bitDepth: bits))
            let link = try #require(LinkedFile(url: url, requester: "Flimmer"))
            #expect(link.bitDepth == bits)
            let (p, pool) = try project(from: url, dir: dir)
            let before = PlanCompiler.compile(p, pool: pool).render(from: 0, frames: Int(p.length))
            let node = try inode(url)
            try link.write(PlanCompiler.compile(p, pool: pool), range: 0..<p.length, markers: [], scratch: dir.file("scratch"))
            #expect(try inode(url) == node)
            let again = try #require(LinkedFile(url: url, requester: "Flimmer"))
            #expect(again.format == link.format && again.bitDepth == bits && again.sampleRate == sr)
            let (q, qpool) = try project(from: url, dir: dir)
            let after = PlanCompiler.compile(q, pool: qpool).render(from: 0, frames: Int(q.length))
            #expect(after == before, "\(name)")
        }
    }

    @Test("Formats Jämmer can't write back exactly aren't linked")
    func unsupported() throws {
        let dir = TempDir()
        let mp3ish = dir.file("clip.m4a")
        try Data("not audio".utf8).write(to: mp3ish)
        #expect(LinkedFile(url: mp3ish, requester: "Flimmer") == nil)
        let six = dir.file("six.wav")
        try writeWAV([Float](repeating: 0, count: 6 * 4_800), to: six, channels: 6)
        #expect(LinkedFile(url: six, requester: "Flimmer") == nil)
    }
}
