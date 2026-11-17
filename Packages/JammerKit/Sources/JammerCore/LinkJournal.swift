import Foundation

/// Jämmer's own record of the documents a sibling app handed over (the-apps/SIBLINGS.md §6, point 6):
/// one small file a document, in the app's own data folder, with the link and the document as it stands.
/// It is written when the document is linked and after every step, whole or not at all, so that a crash
/// costs at most the step that was being made; and it does not depend on the system's saved windows or
/// on autosave, which a Mac may have switched off and which go by the clock.
///
/// An entry carries the changes, not the sound: the project (its edit list, lanes, transcript), which
/// plays from files that are already on the disk. Reading is careful: each entry goes through the same
/// checks as a project opened from outside, and one that can't be read is left where it is and counted,
/// never removed and never a reason to stop.
public struct LinkJournal: Sendable {
    public struct Entry: Codable, Sendable, Equatable {
        public var id: UUID
        public var record: LinkedFile.Record
        /// The document's name in the window.
        public var name: String
        /// The project, as `ProjectPackage.encode` writes it.
        public var project: Data
        /// Whether the document has changes that haven't been saved back.
        public var edited: Bool
        /// The user chose to keep the changes for later when closing the window.
        public var kept: Bool
        public var written: Date

        public init(id: UUID, record: LinkedFile.Record, name: String, project: Data, edited: Bool, kept: Bool = false, written: Date = Date()) {
            self.id = id
            self.record = record
            self.name = name
            self.project = project
            self.edited = edited
            self.kept = kept
            self.written = written
        }
    }

    /// One entry read back: what it says, and the project after the checks (with what they noted).
    public struct Read: Sendable {
        public var entry: Entry
        public var project: Project
        public var notes: [String]
    }

    public static let fileExtension = "jammerlink"
    public let folder: URL

    public init(folder: URL) { self.folder = folder }

    public func url(of id: UUID) -> URL { folder.appending(path: "\(id.uuidString).\(Self.fileExtension)") }

    /// Writes an entry whole: to a file beside it first, then moved into place, so that a crash in the
    /// middle leaves the entry as it was before.
    public func write(_ entry: Entry) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entry).write(to: url(of: entry.id), options: .atomic)
    }

    /// Takes an entry away: its changes were saved back, or the user gave them up.
    public func remove(_ id: UUID) { try? FileManager.default.removeItem(at: url(of: id)) }

    /// Moves an entry to the Trash (never deletes it): work the user gave up from the list of waiting files.
    @discardableResult
    public func trash(_ id: UUID) throws -> URL? {
        var out: NSURL?
        try FileManager.default.trashItem(at: url(of: id), resultingItemURL: &out)
        return out as URL?
    }

    /// Every entry that can be read, oldest first, and the files that can't (left as they are).
    public func read() -> (entries: [Read], broken: [URL]) {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == Self.fileExtension }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var good: [Read] = [], broken: [URL] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for file in files {
            // Nothing in a journal file is taken on trust: its size, its shape, its project.
            guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= Self.maxBytes,
                  let data = try? Data(contentsOf: file), let entry = try? decoder.decode(Entry.self, from: data),
                  file.deletingPathExtension().lastPathComponent == entry.id.uuidString,
                  let checked = try? ProjectPackage.decodeChecked(entry.project) else { broken.append(file); continue }
            good.append(Read(entry: entry, project: checked.project, notes: checked.notes))
        }
        return (good.sorted { $0.entry.written < $1.entry.written }, broken)
    }

    /// No entry is this large: a two-hour conversation with its transcript is a few megabytes.
    public static let maxBytes = 256 * 1024 * 1024
}
