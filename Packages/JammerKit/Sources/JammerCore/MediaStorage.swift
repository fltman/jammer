import Foundation

/// What Jämmer knows about the files in its media folder that it made itself: effects, repairs and
/// frozen strips bounced into new files. It is the only ground on which a file may ever be offered for
/// removal: a file without a row here is treated as an original and is never touched, and that includes
/// files Jämmer made before this register existed. It lives in the media folder, so it follows it.
public struct MediaRegister: Codable, Sendable, Equatable {
    public struct Row: Codable, Sendable, Equatable {
        /// What sort of file: "frozen", "duck", "echo", "limit", "dehum", … (the step's own word).
        public var kind: String
        public var created: Date
        /// Every project that has been seen to use the file, by where it is (a package's path, or
        /// "untitled:<id>" for a document that has never been saved), and when it was last seen to.
        public var projects: [String: Date]
    }
    public struct Trashed: Codable, Sendable, Equatable {
        public var name: String
        public var bytes: Int64
        public var when: Date
    }

    public var files: [String: Row] = [:]
    public var trashed: [Trashed] = []

    public static let fileName = ".jammer-media-register.json"
    public init() {}

    public enum State: Equatable {
        case none            // no register yet: nothing in the folder has a row
        case broken          // there is a file and it can't be read: nothing is touched, and it isn't written over
        case read(MediaRegister)
    }

    public static func state(_ media: URL) -> State {
        let url = media.appending(path: fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return .none }
        guard let data = try? Data(contentsOf: url), let r = try? JSONDecoder.iso.decode(MediaRegister.self, from: data) else { return .broken }
        return .read(r)
    }

    /// Written whole, to a file beside it that then takes its place: never half a register.
    public func save(_ media: URL) throws {
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try JSONEncoder.iso.encode(self).write(to: media.appending(path: Self.fileName), options: .atomic)
    }

    private static let lock = NSLock()

    /// Changes the register of `media` under a lock. A register that can't be read is left exactly as
    /// it is (and then nothing in the folder can be offered for removal).
    @discardableResult
    public static func update(_ media: URL, _ change: (inout MediaRegister) -> Void) -> Bool {
        lock.withLock {
            var r: MediaRegister
            switch state(media) {
            case .none: r = MediaRegister()
            case .broken: return false
            case .read(let read): r = read
            }
            let before = r
            change(&r)
            if r != before || !FileManager.default.fileExists(atPath: media.appending(path: fileName).path) { return (try? r.save(media)) != nil }
            return true
        }
    }

    /// A file Jämmer has just made in the media folder. Files anywhere else are not registered.
    public static func made(_ url: URL, kind: String, in media: URL, at date: Date = Date()) {
        guard url.deletingLastPathComponent().standardizedFileURL.path == media.standardizedFileURL.path else { return }
        update(media) { $0.files[url.lastPathComponent] = Row(kind: kind, created: date, projects: [:]) }
    }

    /// The registered files that `project`, wherever it is kept (`location`), uses now: seen today.
    public static func seen(_ names: Set<String>, usedBy location: String, in media: URL, at date: Date = Date()) {
        guard !names.isEmpty else { return }
        update(media) { r in for n in names where r.files[n] != nil { r.files[n]!.projects[location] = date } }
    }

    /// A project that is gone for certain (an untitled document closed without saving) no longer holds anything.
    public static func forget(project location: String, in media: URL) {
        update(media) { r in for n in r.files.keys { r.files[n]!.projects[location] = nil } }
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys, .prettyPrinted]; return e }
}
extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

/// What takes room in the media folder, and what of it could be let go. Looking never changes anything.
public enum MediaStorage {
    /// A project Jämmer can look into right now: where it is kept, and every state of it that could be
    /// gone back to (as it is now, and every step in its history, on every branch).
    public struct Known: Sendable {
        public var name: String
        public var location: String
        public var states: [Project]
        public init(name: String, location: String, states: [Project]) {
            self.name = name
            self.location = location
            self.states = states
        }
    }

    public enum Group: String, Sendable, Codable {
        /// A project that can be read uses it, now or somewhere in its history.
        case inUse
        /// Jämmer made it, and no project that has ever been seen to use it uses it any more.
        case canBeFreed
        /// Jämmer made it, and a project that used it can't be read just now (another disk, moved):
        /// it can't be chosen until that project has been seen again.
        case unknown
        /// No row in the register: an original, or something made before the register. Never touched.
        case unregistered
    }

    public struct File: Sendable, Equatable {
        public var name: String
        public var bytes: Int64
        public var group: Group
        public var kind: String?
        public var created: Date?
        /// The projects that use it (in use), or that used it and can't be read (unknown).
        public var projects: [String]
    }

    public struct Report: Sendable, Equatable {
        public var files: [File]
        /// "none" (no register yet), "broken" (it can't be read: nothing can be freed), or "read".
        public var register: String
        public var trashed: [MediaRegister.Trashed]
        public init(files: [File] = [], register: String = "none", trashed: [MediaRegister.Trashed] = []) {
            self.files = files
            self.register = register
            self.trashed = trashed
        }
        public func bytes(_ group: Group) -> Int64 { files.filter { $0.group == group }.reduce(0) { $0 + $1.bytes } }
        public func names(_ group: Group) -> [String] { files.filter { $0.group == group }.map(\.name) }
    }

    /// The file names in `media` that a project state plays from, or could go back to: its sources
    /// there, what a ducked track played before, a frozen strip's file.
    public static func names(usedBy project: Project, in media: URL) -> Set<String> {
        let folder = media.standardizedFileURL.path
        var out = Set<String>()
        for s in project.sources where s.packagePath == nil && !s.path.isEmpty {
            let url = URL(fileURLWithPath: s.path).standardizedFileURL
            if url.deletingLastPathComponent().path == folder { out.insert(url.lastPathComponent) }
        }
        return out
    }

    /// Reads the folder and sorts what is in it. `known`: every project that can be read now (open
    /// ones, recent ones, autosaved ones, and those the register names, where they could be read).
    public static func report(media: URL, known: [Known]) -> Report {
        let state = MediaRegister.state(media)
        var register = MediaRegister(), registerState = "none"
        switch state {
        case .none: break
        case .broken: registerState = "broken"
        case .read(let r): register = r; registerState = "read"
        }
        var users: [String: [String]] = [:]
        var readable = Set<String>()
        for k in known {
            readable.insert(k.location)
            var names = Set<String>()
            for s in k.states { names.formUnion(Self.names(usedBy: s, in: media)) }
            for n in names { users[n, default: []].append(k.name) }
        }
        var files: [File] = []
        let listing = (try? FileManager.default.contentsOfDirectory(at: media, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        for url in listing.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let name = url.lastPathComponent, bytes = Int64(values?.fileSize ?? 0)
            guard registerState == "read", let row = register.files[name] else {
                files.append(File(name: name, bytes: bytes, group: .unregistered, kind: nil, created: nil, projects: users[name] ?? []))
                continue
            }
            if let by = users[name], !by.isEmpty {
                files.append(File(name: name, bytes: bytes, group: .inUse, kind: row.kind, created: row.created, projects: by.sorted()))
            } else {
                // Nobody who can be read uses it. Has anyone who can't be read used it?
                let unseen = row.projects.keys.filter { !readable.contains($0) }.sorted()
                files.append(File(name: name, bytes: bytes, group: unseen.isEmpty ? .canBeFreed : .unknown, kind: row.kind, created: row.created, projects: unseen))
            }
        }
        return Report(files: files, register: registerState, trashed: register.trashed)
    }

    public struct Moved: Sendable, Equatable {
        public var names: [String]
        public var bytes: Int64
        public var dryRun: Bool
    }

    public enum Refusal: Error, LocalizedError, Equatable {
        case notFreeable([String])
        public var errorDescription: String? {
            switch self {
            case .notFreeable(let names): "These can't be moved to the Trash, because they are in use, were not made by Jämmer, or belong to a project that can't be read just now: \(names.joined(separator: ", "))."
            }
        }
    }

    /// Moves files to the Trash (nothing is ever deleted): only ones that the folder, read again here
    /// and now, says can be freed. Asked for anything else, nothing is moved at all. With `dryRun`, says
    /// what would be moved and moves nothing.
    public static func moveToTrash(_ names: [String], media: URL, known: [Known], dryRun: Bool,
                                   trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws -> Moved {
        let now = report(media: media, known: known)
        let freeable = Dictionary(uniqueKeysWithValues: now.files.filter { $0.group == .canBeFreed }.map { ($0.name, $0.bytes) })
        let wanted = Array(Set(names)).sorted()
        let refused = wanted.filter { freeable[$0] == nil }
        guard refused.isEmpty else { throw Refusal.notFreeable(refused) }
        let bytes = wanted.reduce(Int64(0)) { $0 + (freeable[$1] ?? 0) }
        guard !dryRun else { return Moved(names: wanted, bytes: bytes, dryRun: true) }
        var moved: [String] = []
        for name in wanted {
            try trash(media.appending(path: name))
            moved.append(name)
        }
        MediaRegister.update(media) { r in
            for name in moved {
                r.trashed.append(.init(name: name, bytes: freeable[name] ?? 0, when: Date()))
                r.files[name] = nil
            }
        }
        return Moved(names: moved, bytes: moved.reduce(Int64(0)) { $0 + (freeable[$1] ?? 0) }, dryRun: false)
    }

    /// For a file a project needs and can't find: when Jämmer itself moved a file of that name to the
    /// Trash, and so where to look.
    public static func trashedHint(for path: String, media: URL) -> String? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.deletingLastPathComponent().path == media.standardizedFileURL.path, case .read(let r) = MediaRegister.state(media),
              let t = r.trashed.last(where: { $0.name == url.lastPathComponent }) else { return nil }
        return "\(t.name) was moved to the Trash from Jämmer's storage on \(t.when.formatted(date: .abbreviated, time: .shortened)). If the Trash hasn't been emptied it is still there: put it back and open the project again."
    }
}
