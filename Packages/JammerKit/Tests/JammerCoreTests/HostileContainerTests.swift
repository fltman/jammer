import Foundation
import Testing
@testable import JammerCore

/// The parts of files that HostileFileTests' sound doesn't reach (the coordinator, 2026-11-27, after Glimmer's
/// HostileImageTests): a WAV's markers, labels and texts, the peak files Jämmer keeps beside the sound, and the ZIP a
/// DAWproject is. Every file is made here by hand; nothing is fetched. None may crash, hang, or read or set aside
/// more than a real file could need; a recording whose labels are broken still opens.
@Suite("Hostile files: markers, labels, texts, peak files and ZIP entries")
struct HostileContainerTests {
    typealias H = Hostile

    func folder() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "jammer-hostile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Opens `data` as a WAV and says how long it took.
    func open(_ data: Data, in dir: URL) throws -> (AudioFileInfo, Double) {
        let url = dir.appending(path: "f-\(UUID().uuidString.prefix(6)).wav")
        try data.write(to: url)
        let t0 = Date()
        let info = try AudioFileReader.info(at: url)
        return (info, Date().timeIntervalSince(t0))
    }

    /// A cue point: its id and its place in the sound (the last of its six fields).
    func cuePoint(_ id: UInt32, at frame: UInt32) -> [UInt8] {
        H.le32(id) + H.le32(frame) + Array("data".utf8) + H.le32(0) + H.le32(0) + H.le32(frame)
    }

    @Test("A cue list that claims four billion points, and holds 150 000, gives the project's limit of markers, at once")
    func manyCues() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        var cue = H.le32(0xFFFF_FFFF)
        for i in 0..<150_000 { cue += cuePoint(UInt32(i), at: UInt32(i % 4_800)) }
        let (info, seconds) = try open(H.wav(extra: H.chunk("cue ", cue)), in: dir)
        #expect(info.markers.count == AudioFileInfo.maxMarkers, "\(info.markers.count) markers")
        #expect(seconds < 5, "\(seconds) s")
    }

    @Test("Labels: one that runs past its list or the file, one of 200 kB, and a list inside the list; the recording opens")
    func brokenLabels() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cue = H.le32(3) + cuePoint(1, at: 100) + cuePoint(2, at: 200) + cuePoint(3, at: 300)
        let first = H.chunk("labl", H.le32(1) + Array("Intro".utf8) + [0])
        let long = H.chunk("labl", H.le32(2) + [UInt8](repeating: 0x41, count: 200_000) + [0])
        let nested = H.chunk("LIST", Array("adtl".utf8) + H.chunk("labl", H.le32(3) + Array("Inner".utf8) + [0]))
        // A label for point 3 that says it is almost 4 GB: past the list and past the file.
        let lying = Array("labl".utf8) + H.le32(0xFFFF_FF00) + H.le32(3) + Array("Lie".utf8)
        let adtl = H.chunk("LIST", Array("adtl".utf8) + first + long + nested + lying)
        let (info, _) = try open(H.wav(extra: H.chunk("cue ", cue) + adtl), in: dir)
        #expect(info.frames == 4_800, "the sound is all there")
        #expect(info.markers.count == 3)
        #expect(info.markers.first?.name == "Intro")
        #expect(info.markers[1].name.utf8.count == AudioFileInfo.maxLabel, "a name is cut at \(AudioFileInfo.maxLabel) bytes, not \(info.markers[1].name.utf8.count)")
        #expect(info.markers[2].name == "Marker 3", "the lying label ends the list; the marker keeps its number")
    }

    @Test("A coding history of 3 MB in bext is read for its first megabyte, and the recording opens")
    func longCodingHistory() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        var bext = [UInt8](repeating: 0, count: 602)
        bext.replaceSubrange(0..<5, with: Array("Hello".utf8))
        bext += [UInt8](repeating: 0x42, count: 3 << 20)
        let (info, _) = try open(H.wav(extra: H.chunk("bext", bext)), in: dir)
        #expect(info.bext?.description == "Hello")
        #expect(info.bext?.codingHistory.utf8.count == AudioFileInfo.maxTextChunk)
        #expect(info.frames == 4_800)
    }

    /// A peak file's header: "JMPK", version 1, channels, frames, count; then `floats` values.
    func peakFile(channels: UInt32, frames: UInt64, count: UInt64, floats: Int) -> Data {
        var b = H.le32(0x4A4D_504B) + H.le32(1) + H.le32(channels) + H.le64(frames) + H.le64(count)
        for _ in 0..<floats { b += H.le32(Float(0.25).bitPattern) }
        return Data(b)
    }

    @Test("A peak file whose figures overflow, lie or don't add up is built again, never read (and never stops Jämmer)")
    func peakFiles() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cases: [(String, Data)] = [
            ("frames and count past Int64", peakFile(channels: 2, frames: .max, count: .max, floats: 4)),
            ("frames at Int64.max", peakFile(channels: 2, frames: UInt64(Int64.max), count: 4, floats: 4)),
            ("a count near Int.max", peakFile(channels: 1, frames: 256, count: UInt64(Int.max) / 2, floats: 2)),
            ("a count that overflows when doubled", peakFile(channels: 64, frames: 1 << 43, count: 1 << 62, floats: 2)),
            ("a count longer than the file", peakFile(channels: 1, frames: 256, count: 2, floats: 1)),
            ("no channels", peakFile(channels: 0, frames: 256, count: 0, floats: 0)),
            ("cut short", peakFile(channels: 1, frames: 256, count: 2, floats: 2).prefix(20)),
        ]
        for (name, data) in cases {
            let url = dir.appending(path: "p.peaks")
            try data.write(to: url)
            #expect(PeakIndex.read(from: url) == nil, "\(name)")
        }
        // A whole one still reads.
        let url = dir.appending(path: "good.peaks")
        try peakFile(channels: 1, frames: 256, count: 2, floats: 2).write(to: url)
        #expect(PeakIndex.read(from: url) != nil)
    }

    /// A one-entry ZIP made by Zip.write, its central directory's method and size then changed.
    func zip(method: UInt16, size: UInt32, count: UInt16? = nil) -> Data {
        var b = [UInt8](Zip.write([("a.wav", Data(repeating: 7, count: 10))]))
        let central = (0..<(b.count - 4)).first { b[$0] == 0x50 && b[$0 + 1] == 0x4B && b[$0 + 2] == 1 && b[$0 + 3] == 2 }!
        b.replaceSubrange((central + 10)..<(central + 12), with: H.le16(method))
        b.replaceSubrange((central + 24)..<(central + 28), with: H.le32(size))
        if let count {
            let eocd = b.count - 22
            b.replaceSubrange((eocd + 8)..<(eocd + 12), with: H.le16(count) + H.le16(count))
        }
        return Data(b)
    }

    @Test("A ZIP entry that claims to unpack ten bytes into 4 GB is refused before anything is set aside")
    func zipBomb() throws {
        let data = zip(method: 8, size: 0xFFFF_FFFF)
        let entries = try Zip.entries(data)
        #expect(entries.count == 1 && entries[0].size == 0xFFFF_FFFF)
        let t0 = Date()
        #expect(throws: Zip.Failure.self) { _ = try Zip.read(entries[0], in: data, limit: 4 << 30) }
        #expect(Date().timeIntervalSince(t0) < 1, "refused without setting aside 4 GB")
        // A directory that says it lists 65 535 entries and holds one is damaged, not read past its end.
        #expect(throws: Zip.Failure.self) { _ = try Zip.entries(zip(method: 0, size: 10, count: 65_535)) }
        // The entry as written still reads.
        let plain = try Zip.entries(zip(method: 0, size: 10))
        #expect(try Zip.read(plain[0], in: zip(method: 0, size: 10), limit: 100) == Data(repeating: 7, count: 10))
    }
}
