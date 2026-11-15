import Foundation

/// Chapters for podcasts, from the document's markers: each marker starts a chapter that
/// runs to the next one (or the end). Written as ID3v2.4 CHAP/CTOC frames in MP3 (the ID3
/// chapter addendum) and as Podcasting 2.0 JSON chapters.
public struct Chapter: Sendable, Equatable, Codable {
    public var title: String
    public var start: Double
    public var end: Double

    public init(title: String, start: Double, end: Double) {
        self.title = title
        self.start = start
        self.end = end
    }
}

extension Project {
    /// Chapters within `range` (seconds relative to its start), from the markers in it.
    /// A first chapter is added at 0 when the first marker comes later, so the whole
    /// file is covered.
    public func chapters(in range: Range<Frame>? = nil) -> [Chapter] {
        let r = range ?? 0..<length
        let starts = markers.filter { r.contains($0.position) && $0.kind != .shot }.sorted { $0.position < $1.position }
        guard !starts.isEmpty else { return [] }
        var list: [(String, Frame)] = starts.map { ($0.name, $0.position - r.lowerBound) }
        if list[0].1 > 0 { list.insert(("Start", 0), at: 0) }
        let total = Frame(r.count)
        return list.enumerated().map { i, c in
            let end = i + 1 < list.count ? list[i + 1].1 : total
            return Chapter(title: c.0, start: seconds(c.1), end: seconds(end))
        }
    }
}

public enum ChapterFormats {
    /// Podcasting 2.0 JSON chapters (podcast namespace, version 1.2.0).
    public static func podcastingJSON(_ chapters: [Chapter]) throws -> Data {
        struct File: Encodable {
            struct C: Encodable { var startTime: Double; var endTime: Double; var title: String }
            var version = "1.2.0"
            var chapters: [C]
        }
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(File(chapters: chapters.map { .init(startTime: ($0.start * 1_000).rounded() / 1_000, endTime: ($0.end * 1_000).rounded() / 1_000, title: $0.title) }))
    }

    /// An ID3v2.4 tag holding a title (optional), a CTOC listing the chapters in order,
    /// and one CHAP frame per chapter with its title.
    public static func id3Tag(_ chapters: [Chapter], title: String? = nil) -> Data {
        var frames = Data()
        if let title { frames.append(frame("TIT2", text(title))) }
        let ids = chapters.indices.map { "chp\($0)" }
        if !chapters.isEmpty {
            var toc = Data("toc".utf8)
            toc.append(0)
            toc.append(0x03) // top level, ordered
            toc.append(UInt8(min(255, chapters.count)))
            for id in ids.prefix(255) { toc.append(contentsOf: Array(id.utf8)); toc.append(0) }
            frames.append(frame("CTOC", toc))
        }
        for (i, c) in chapters.enumerated() {
            var chap = Data(ids[i].utf8)
            chap.append(0)
            chap.be32(UInt32(max(0, (c.start * 1_000).rounded())))
            chap.be32(UInt32(max(0, (c.end * 1_000).rounded())))
            chap.be32(0xFFFF_FFFF)
            chap.be32(0xFFFF_FFFF)
            chap.append(frame("TIT2", text(c.title)))
            frames.append(frame("CHAP", chap))
        }
        var tag = Data("ID3".utf8)
        tag.append(contentsOf: [4, 0, 0]) // v2.4.0, no flags
        tag.append(synchsafe(frames.count))
        tag.append(frames)
        return tag
    }

    static func text(_ s: String) -> Data {
        var d = Data([3]) // UTF-8
        d.append(contentsOf: Array(s.utf8))
        return d
    }

    static func frame(_ id: String, _ body: Data) -> Data {
        var d = Data(id.utf8)
        d.append(synchsafe(body.count))
        d.append(contentsOf: [0, 0])
        d.append(body)
        return d
    }

    /// ID3v2.4 sizes: 4 bytes of 7 bits each.
    static func synchsafe(_ n: Int) -> Data {
        Data([UInt8((n >> 21) & 0x7F), UInt8((n >> 14) & 0x7F), UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)])
    }
}

extension Data {
    mutating func be32(_ v: UInt32) { append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
}
