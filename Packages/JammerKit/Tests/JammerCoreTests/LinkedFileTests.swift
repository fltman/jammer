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

    @Test("A link is kept across a restart: found again where it is or where it was moved to, and lost in words when it can't be used")
    func acrossRestart() throws {
        let dir = TempDir()
        let file = dir.file("clip.wav")
        try writeWAV(sine(440, amplitudeDB: -12, seconds: 1), to: file, encoding: .int24)
        let link = try #require(LinkedFile(url: file, requester: "Flimmer"))
        // As it is saved with the window, and read again by the next launch.
        let record = try JSONDecoder().decode(LinkedFile.Record.self, from: try JSONEncoder().encode(link.record))
        #expect(record == link.record && record.requester == "Flimmer" && record.bitDepth == 24)
        guard case .linked(let again) = LinkedFile.restore(record) else { Issue.record("not restored"); return }
        #expect(again.url.resolvingSymlinksInPath() == file.resolvingSymlinksInPath() && again.format == .wav && again.requester == "Flimmer" && again.bitDepth == 24)
        // Written back through the restored link: the same file, in place.
        let before = try inode(file)
        var (p, pool) = try project(from: file, dir: dir)
        try p.changeGain(0..<p.length, by: -6)
        try again.write(PlanCompiler.compile(p, pool: pool), range: 0..<p.length, markers: [], scratch: dir.file("scratch"))
        #expect(try inode(file) == before && abs(Double(try samples(file).map(abs).max() ?? 0) - pow(10, -18.0 / 20)) < 0.001)
        // Moved while Jämmer was away: the bookmark follows it.
        let moved = dir.file("renamed clip.wav")
        try FileManager.default.moveItem(at: file, to: moved)
        guard case .linked(let followed) = LinkedFile.restore(record) else { Issue.record("a moved file wasn't followed"); return }
        #expect(followed.fileName == "renamed clip.wav")
        // Read-only: it can't be saved back, and that is said.
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: moved.path)
        #expect(LinkedFile.restore(record) == .lost(name: "renamed clip.wav", requester: "Flimmer", why: "The file can't be written to any more."))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: moved.path)
        // Replaced, at its own path, by a file of another shape (mono): the document no longer fits it.
        let other = dir.file("other.wav")
        try writeWAV(sine(440, amplitudeDB: -12, seconds: 1), to: other, encoding: .int24)
        let second = try #require(LinkedFile(url: other, requester: "Flimmer")).record
        try writeWAV(sine(440, amplitudeDB: -12, seconds: 1, channels: 1), to: other, channels: 1, encoding: .int24)
        if case .lost(let name, _, let why) = LinkedFile.restore(second) { #expect(why.contains("mono") && name == "other.wav") } else { Issue.record("a file of another shape was linked") }
        // The same shape at another bit depth is still a file the document can be written back into.
        try writeWAV(sine(440, amplitudeDB: -12, seconds: 1), to: other, encoding: .int16)
        if case .linked(let l) = LinkedFile.restore(second) { #expect(l.bitDepth == 16) } else { Issue.record("16-bit in place of 24-bit wasn't linked") }
        // Not audio any more, or gone: lost, each with its reason, never an ordinary document by silence.
        try Data("not audio".utf8).write(to: other)
        if case .lost(_, _, let why) = LinkedFile.restore(second) { #expect(why.contains("no longer a file")) } else { Issue.record("text was linked") }
        try FileManager.default.removeItem(at: other)
        #expect(LinkedFile.restore(second) == .lost(name: "other.wav", requester: "Flimmer", why: "The file is no longer where it was."))
        try FileManager.default.removeItem(at: moved)
        // Moved away and turned into something else, and a proper file put back where the first one was: that one is used.
        let third = dir.file("third.wav")
        try writeWAV(sine(440, amplitudeDB: -12, seconds: 1), to: third, encoding: .int24)
        let rec3 = try #require(LinkedFile(url: third, requester: "Flimmer")).record
        try FileManager.default.moveItem(at: third, to: dir.file("third.hidden"))
        if case .lost(let name, _, let why) = LinkedFile.restore(rec3) { #expect(name == "third.hidden" && why.contains("no longer a file")) } else { Issue.record("a file with no audio extension was linked") }
        try writeWAV(sine(440, amplitudeDB: -12, seconds: 1), to: third, encoding: .int24)
        if case .linked(let l) = LinkedFile.restore(rec3) { #expect(l.fileName == "third.wav") } else { Issue.record("the file put back wasn't found") }
        // Without a bookmark (or one that doesn't resolve), the path is what there is.
        var plain = record
        plain.bookmark = Data([1, 2, 3])
        #expect(LinkedFile.restore(plain) == .lost(name: "clip.wav", requester: "Flimmer", why: "The file is no longer where it was."))
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
