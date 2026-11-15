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
