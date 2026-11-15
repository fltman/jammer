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

    /// A project from bytes, checked (`ProjectSafety`): refused when it can't be a project,
    /// repaired where it can be.
    public static func decode(_ data: Data) throws -> Project { try decodeChecked(data).project }

    public static func decodeChecked(_ data: Data, limits: ProjectSafety.Limits = .init()) throws -> (project: Project, notes: [String]) {
        guard data.count <= limits.bytes else { throw AudioFileError.unreadable("The project file is \(data.count >> 20) MB, larger than any real project.") }
        struct Version: Decodable { var formatVersion: Int }
        var project: Project
        do {
            let v = try JSONDecoder().decode(Version.self, from: data)
            guard v.formatVersion <= Project.formatVersion else {
                throw AudioFileError.unsupported("This project was saved by a newer Jammer (format \(v.formatVersion)).")
            }
            project = try JSONDecoder().decode(Project.self, from: data)
        } catch let e as AudioFileError { throw e } catch {
            // The decoder's own words are about keys and types; say what it means for the user.
            throw AudioFileError.unreadable("The project file is damaged or cut off and can't be opened.")
        }
        let notes = try ProjectSafety.check(&project, limits: limits)
        return (project, notes)
    }

    /// The package as a FileWrapper. Media files already inside are kept by reference.
    public static func fileWrapper(_ project: Project, existingMedia: FileWrapper?) throws -> FileWrapper {
        var children = [manifestName: FileWrapper(regularFileWithContents: try encode(project))]
        if let media = existingMedia { children[mediaFolderName] = media }
        return FileWrapper(directoryWithFileWrappers: children)
    }

    public static func read(_ wrapper: FileWrapper, packageURL: URL?) throws -> Project { try readChecked(wrapper, packageURL: packageURL).project }

    /// The file name of a source kept in the package, when `packagePath` is what Jämmer writes
    /// ("Media/<name>") and nothing else: no "..", no further folders, nothing absolute.
    static func mediaName(_ packagePath: String) -> String? {
        let parts = packagePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts[0] == mediaFolderName, !parts[1].isEmpty, parts[1] != ".", parts[1] != "..", !parts[1].contains("\0") else { return nil }
        return parts[1]
    }

    /// Reads the package and says what had to be left out. A source "in the package" is one that
    /// really is: a plain file directly in Media/, not a link, and not a path that climbs out.
    public static func readChecked(_ wrapper: FileWrapper, packageURL: URL?) throws -> (project: Project, notes: [String]) {
        guard wrapper.isDirectory, let manifestWrapper = wrapper.fileWrappers?[manifestName], manifestWrapper.isRegularFile,
              let manifest = manifestWrapper.regularFileContents else {
            throw AudioFileError.unreadable("The project has no \(manifestName).")
        }
        var (project, notes) = try decodeChecked(manifest)
        let media = wrapper.fileWrappers?[mediaFolderName]
        var outside = 0
        for i in project.sources.indices {
            guard let rel = project.sources[i].packagePath else { continue }
            project.sources[i].bookmark = nil
            // Media must be a real folder in the package and the file a real file in it.
            if let name = mediaName(rel), let media, media.isDirectory, let file = media.fileWrappers?[name], file.isRegularFile, let packageURL {
                project.sources[i].path = packageURL.appending(path: mediaFolderName).appending(path: name).path
            } else {
                // Said to be inside the package but isn't: not looked for anywhere else.
                project.sources[i].path = ""
                project.sources[i].packagePath = nil
                outside += 1
            }
        }
        if outside > 0 { notes.append("\(outside) audio file\(outside == 1 ? "" : "s") said to be inside the project \(outside == 1 ? "isn't" : "aren't") there (or the path points out of it) and \(outside == 1 ? "was" : "were") left out.") }
        return (project, notes)
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
