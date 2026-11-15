import AppKit
import JammerCore
import UniformTypeIdentifiers

extension UTType {
    static let jammerProject = UTType(exportedAs: ProjectPackage.typeIdentifier, conformingTo: .package)
}

/// Where Jammer keeps audio it decodes or receives, until a project gathers it.
enum MediaStore {
    static var folder: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Jammer/Media")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// A `.jammer` package. Audio files open as new untitled projects (see
/// `JammerDocumentController`), so a WAV is never overwritten by a save.
final class JammerDocument: NSDocument {
    private(set) var session: EditorSession?
    private var mediaWrapper: FileWrapper?
    /// Set before the window opens for documents created from audio.
    var pendingProject: Project?

    override class var autosavesInPlace: Bool { true }
    override class var readableTypes: [String] { [UTType.jammerProject.identifier, UTType.audio.identifier] }
    override class var writableTypes: [String] { [UTType.jammerProject.identifier] }
    override class func isNativeType(_ type: String) -> Bool { type == UTType.jammerProject.identifier }
    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] { [UTType.jammerProject.identifier] }

    override func makeWindowControllers() {
        let project = pendingProject ?? session?.project ?? Project(sampleRate: 48_000, channels: 2, tracks: [Track(name: "Track 1")])
        let s = session ?? EditorSession(project: project)
        s.document = self
        session = s
        let wc = EditorWindowController(session: s)
        addWindowController(wc)
        AgentRegistry.shared.register(s)
    }

    override func close() {
        if let session {
            session.stop()
            AgentRegistry.shared.unregister(session)
        }
        super.close()
    }

    // A project opened from an audio file has nothing autosaved until it's edited,
    // so the project travels in the window restoration state too.
    private static let restoreKey = "jammer.project"

    override func encodeRestorableState(with coder: NSCoder) {
        super.encodeRestorableState(with: coder)
        let project = MainActor.assumeIsolated { session?.project ?? pendingProject }
        if let project, let data = try? ProjectPackage.encode(project) {
            coder.encode(data as NSData, forKey: Self.restoreKey)
            coder.encode(displayName as NSString, forKey: Self.restoreKey + ".name")
        }
    }

    override func restoreState(with coder: NSCoder) {
        super.restoreState(with: coder)
        guard fileURL == nil, !isDocumentEdited,
              let data = coder.decodeObject(of: NSData.self, forKey: Self.restoreKey) as Data?,
              let project = try? ProjectPackage.decode(data) else { return }
        if let name = coder.decodeObject(of: NSString.self, forKey: Self.restoreKey + ".name") as String? { displayName = name }
        MainActor.assumeIsolated {
            if let session { session.load(project) } else { pendingProject = project }
        }
    }

    override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        guard typeName == UTType.jammerProject.identifier || UTType(typeName)?.conforms(to: .jammerProject) == true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let project = try ProjectPackage.read(fileWrapper, packageURL: fileURL)
        mediaWrapper = fileWrapper.fileWrappers?[ProjectPackage.mediaFolderName]
        // NSDocument reads on the main thread (no concurrent reading).
        MainActor.assumeIsolated {
            if let session { session.load(project) } else { pendingProject = project }
        }
    }

    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        let project = MainActor.assumeIsolated { session?.project ?? pendingProject }
        guard let project else { throw CocoaError(.fileWriteUnknown) }
        return try ProjectPackage.fileWrapper(project, existingMedia: mediaWrapper)
    }
}

/// Opens audio files as new projects instead of documents of their own.
final class JammerDocumentController: NSDocumentController {
    override func makeDocument(withContentsOf url: URL, ofType typeName: String) throws -> NSDocument {
        guard let type = UTType(typeName), !type.conforms(to: .jammerProject), type.conforms(to: .audio) else {
            return try super.makeDocument(withContentsOf: url, ofType: typeName)
        }
        let result = try AudioImporter.importFile(url, mediaFolder: MediaStore.folder)
        let doc = JammerDocument()
        doc.pendingProject = Project(source: result.source)
        doc.displayName = url.deletingPathExtension().lastPathComponent
        return doc
    }

    /// Opens a new untitled document around `project` and shows it.
    @MainActor
    @discardableResult
    func open(_ project: Project, name: String) -> JammerDocument {
        let doc = JammerDocument()
        doc.pendingProject = project
        doc.displayName = name
        addDocument(doc)
        doc.makeWindowControllers()
        doc.showWindows()
        return doc
    }
}
