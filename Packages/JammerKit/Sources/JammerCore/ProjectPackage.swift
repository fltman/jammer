import Foundation

/// The `.jammer` document: a folder package.
///
///     Project.jammer/
///       project.json   the Project, versioned
///       Media/         audio Jammer decoded or recorded (sources may also live outside)
///
/// Sources outside the package are referenced by path and bookmark, never copied
/// unless the user asks.
public enum ProjectPackage {
    public static let fileExtension = "jammer"
    public static let typeIdentifier = "com.brattoo.jammer.project"
    public static let manifestName = "project.json"
    public static let mediaFolderName = "Media"

    public static func encode(_ project: Project) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(project)
    }

    public static func decode(_ data: Data) throws -> Project {
        struct Version: Decodable { var formatVersion: Int }
        let v = try JSONDecoder().decode(Version.self, from: data)
        guard v.formatVersion <= Project.formatVersion else {
            throw AudioFileError.unsupported("This project was saved by a newer Jammer (format \(v.formatVersion)).")
        }
        return try JSONDecoder().decode(Project.self, from: data)
    }

    /// The package as a FileWrapper. Media files already inside are kept by reference.
    public static func fileWrapper(_ project: Project, existingMedia: FileWrapper?) throws -> FileWrapper {
        var children = [manifestName: FileWrapper(regularFileWithContents: try encode(project))]
        if let media = existingMedia { children[mediaFolderName] = media }
        return FileWrapper(directoryWithFileWrappers: children)
    }

    public static func read(_ wrapper: FileWrapper, packageURL: URL?) throws -> Project {
        guard let manifest = wrapper.fileWrappers?[manifestName]?.regularFileContents else {
            throw AudioFileError.unreadable("The project has no \(manifestName).")
        }
        var project = try decode(manifest)
        // Sources stored inside the package move with it.
        if let packageURL {
            for i in project.sources.indices {
                if let rel = project.sources[i].packagePath {
                    project.sources[i].path = packageURL.appending(path: rel).path
                    project.sources[i].bookmark = nil
                }
            }
        }
        return project
    }
}

// MARK: Collect and save

extension ProjectPackage {
    /// One file to copy into the package's Media folder.
    public struct MediaCopy: Sendable, Equatable {
        public var from: URL
        /// File name inside Media/.
        public var name: String
    }

    /// The project with every source its clips use moved into the package, and
    /// the copies that takes. Sources already inside, and files that are missing,
    /// are left as they are. `existingMedia` are names already in Media/.
    public static func planCollection(_ project: Project, existingMedia: Set<String>) -> (project: Project, copies: [MediaCopy]) {
        var p = project
        var taken = Set(existingMedia.map { $0.lowercased() })
        var copies: [MediaCopy] = []
        let used = Set(project.tracks.flatMap { $0.clips.map(\.sourceID) })
        for i in p.sources.indices where p.sources[i].packagePath == nil && used.contains(p.sources[i].id) {
            let url = SourcePool.resolve(p.sources[i])
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let name = uniqueName(for: url.lastPathComponent, taken: &taken)
            copies.append(MediaCopy(from: url, name: name))
            p.sources[i].packagePath = "\(mediaFolderName)/\(name)"
            p.sources[i].bookmark = nil
        }
        return (p, copies)
    }

    /// Copies into `package`/Media. On APFS a copy on the same volume is a clone and costs no space.
    public static func copyMedia(_ copies: [MediaCopy], intoPackage package: URL) throws {
        guard !copies.isEmpty else { return }
        let media = package.appending(path: mediaFolderName)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        for c in copies {
            let dest = media.appending(path: c.name)
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            do { try FileManager.default.copyItem(at: c.from, to: dest) } catch {
                throw AudioFileError.unreadable("Couldn't copy \(c.from.lastPathComponent) into the project: \(error.localizedDescription)")
            }
        }
    }

    /// The sources of `project` as they are once the package at `package` holds them.
    public static func resolvedInPackage(_ project: Project, package: URL) -> Project {
        var p = project
        for i in p.sources.indices {
            if let rel = p.sources[i].packagePath {
                p.sources[i].path = package.appending(path: rel).path
                p.sources[i].bookmark = nil
            }
        }
        return p
    }

    static func uniqueName(for original: String, taken: inout Set<String>) -> String {
        // Keep names portable: no slashes or colons, no leading dot.
        var base = original.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while base.hasPrefix(".") { base.removeFirst() }
        if base.isEmpty { base = "audio" }
        let ext = (base as NSString).pathExtension
        let stem = (base as NSString).deletingPathExtension
        var name = base
        var n = 2
        while taken.contains(name.lowercased()) {
            name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            n += 1
        }
        taken.insert(name.lowercased())
        return name
    }
}
