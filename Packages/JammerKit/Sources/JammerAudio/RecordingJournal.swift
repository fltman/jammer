import Foundation
import JammerCore

/// What a recording going on now has written, kept beside it so a crash (of Jämmer or the Mac) loses at most the
/// last second: one small file per document, under the document's own id (`Project.documentID`), not its path, so
/// it is found again however the document was moved, renamed or copied before it was opened again. Written when
/// recording starts, removed when its takes are on their tracks. Opened with a journal left, the document offers
/// the takes back: each file is taken to its last whole frame (`WAVWriter.recover`) and laid where it was recorded.
public struct RecordingJournal: Codable, Equatable, Sendable {
    public struct Take: Codable, Equatable, Sendable {
        public var track: UUID
        public var path: String
        public var channels: Int
        public init(track: UUID, path: String, channels: Int) { self.track = track; self.path = path; self.channels = channels }
    }

    public var documentID: UUID
    /// Where the document was when it recorded (said in the offer; it is not how it is found).
    public var documentPath: String?
    public var takes: [Take]
    /// Where on the timeline the takes go, and how much of each file comes first (pre-roll and the input's delay).
    public var at: Frame
    public var sourceStart: Frame
    /// The punch-out, as frames of take after `sourceStart` (nil: as long as it ran).
    public var length: Frame?
    public var sampleRate: Double
    public var started: Date

    public init(documentID: UUID, documentPath: String?, takes: [Take], at: Frame, sourceStart: Frame, length: Frame?, sampleRate: Double, started: Date) {
        self.documentID = documentID
        self.documentPath = documentPath
        self.takes = takes
        self.at = at
        self.sourceStart = sourceStart
        self.length = length
        self.sampleRate = sampleRate
        self.started = started
    }

    public static func url(for id: UUID, in folder: URL) -> URL { folder.appending(path: "\(id.uuidString).json") }

    /// Written in full each time (a small file, replaced in one step), so it is never read half written.
    public func write(in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        try e.encode(self).write(to: Self.url(for: documentID, in: folder), options: .atomic)
    }

    /// The journal a document left, if any.
    public static func left(by id: UUID, in folder: URL) -> RecordingJournal? {
        guard let data = try? Data(contentsOf: url(for: id, in: folder)) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(RecordingJournal.self, from: data)
    }

    public static func remove(_ id: UUID, in folder: URL) {
        try? FileManager.default.removeItem(at: url(for: id, in: folder))
    }

    /// A take found again: its file made whole, and how many frames of it go on the timeline.
    public struct Found: Equatable, Sendable {
        public var take: Take
        public var frames: Frame
    }

    /// Makes each take's file whole (to its last whole frame) and says what goes on the timeline; a file that is
    /// gone or holds nothing past `sourceStart` is left out.
    public func recover() -> [Found] {
        takes.compactMap { t in
            let url = URL(fileURLWithPath: t.path)
            guard FileManager.default.fileExists(atPath: t.path), let total = try? WAVWriter.recover(url) else { return nil }
            let usable = Frame(total) - sourceStart
            guard usable > 0 else { return nil }
            return Found(take: t, frames: length.map { min($0, usable) } ?? usable)
        }
    }
}

extension RecordingJournal {
    /// Every journal left in the folder, oldest first (one that can't be read is left where it is).
    public static func all(in folder: URL) -> [RecordingJournal] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent).flatMap { left(by: $0, in: folder) } }
            .sorted { $0.started < $1.started }
    }

    /// A new document for a journal no document claims (a recording in a document that was never saved, or whose
    /// file is gone): one track per take found, named after its file, the takes from the start, kept as takes.
    public func recoveredProject() -> Project? {
        var p = Project(sampleRate: sampleRate, channels: 2, tracks: [], sources: [])
        for found in recover() {
            let url = URL(fileURLWithPath: found.take.path)
            guard let info = try? AudioFileReader.info(at: url) else { continue }
            let source = SourceRef(name: url.deletingPathExtension().lastPathComponent, path: url.path, info: info)
            let track = Track(name: source.name)
            p.tracks.append(track)
            _ = try? p.recordTake(source, frames: found.frames, at: 0, onTrack: track.id, sourceStart: sourceStart)
        }
        return p.tracks.isEmpty ? nil : p
    }
}
