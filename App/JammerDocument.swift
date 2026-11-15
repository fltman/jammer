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
    /// Touched from NSDocument's read/write overrides, which are nonisolated but run
    /// on the main thread here (no asynchronous reading or writing).
    nonisolated(unsafe) private var mediaWrapper: FileWrapper?
    /// Set before the window opens for documents created from audio.
    var pendingProject: Project?
    /// A history read from the package before the window opened.
    var pendingHistory: History?
    static let historyFile = "history.json"

    override class var autosavesInPlace: Bool { true }
    override class var readableTypes: [String] { [UTType.jammerProject.identifier, UTType.audio.identifier] }
    override class var writableTypes: [String] { [UTType.jammerProject.identifier] }
    override class func isNativeType(_ type: String) -> Bool { type == UTType.jammerProject.identifier }
    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] { [UTType.jammerProject.identifier] }

    override func makeWindowControllers() {
        let project = pendingProject ?? session?.project ?? Project(sampleRate: 48_000, channels: 2, tracks: [Track(name: "Track 1")])
        let s = session ?? EditorSession(project: project)
        if session == nil, let h = pendingHistory { s.load(project, history: h) }
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
        let history = fileWrapper.fileWrappers?[Self.historyFile]?.regularFileContents.flatMap { try? JSONDecoder().decode(History.self, from: $0) }
        // NSDocument reads on the main thread (no concurrent reading).
        MainActor.assumeIsolated {
            if let session { session.load(project, history: history) } else { pendingProject = project; pendingHistory = history }
        }
    }

    // MARK: Collect and save

    /// Set by "Collect Audio and Save"; the next save copies the sources into Media/.
    private var collectOnSave = false
    nonisolated(unsafe) private var pendingCopies: [ProjectPackage.MediaCopy] = []
    private var pendingCollected: Project?

    /// Copies every file the project plays from into the package, then saves.
    /// An untitled project is saved first (the save panel), then collected.
    @objc func collectAudio(_ sender: Any?) {
        if fileURL == nil {
            runModalSavePanel(for: .saveOperation, delegate: self, didSave: #selector(document(_:didSaveForCollect:contextInfo:)), contextInfo: nil)
        } else {
            collectOnSave = true
            save(sender)
        }
    }

    @objc private func document(_ document: NSDocument, didSaveForCollect didSave: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard didSave else { return }
        collectOnSave = true
        save(nil)
    }

    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        var project = MainActor.assumeIsolated { session?.project ?? pendingProject }
        guard project != nil else { throw CocoaError(.fileWriteUnknown) }
        pendingCopies = []
        pendingCollected = nil
        if collectOnSave, let p = project {
            let existing = Set(mediaWrapper?.fileWrappers?.keys.map { $0 } ?? [])
            let (collected, copies) = ProjectPackage.planCollection(p, existingMedia: existing)
            project = collected
            pendingCopies = copies
            pendingCollected = collected
        }
        let wrapper = try ProjectPackage.fileWrapper(project!, existingMedia: mediaWrapper)
        // The history tree travels in the package.
        if let h = MainActor.assumeIsolated({ session?.history }), let data = try? JSONEncoder().encode(h) {
            let file = FileWrapper(regularFileWithContents: data)
            file.preferredFilename = Self.historyFile
            wrapper.addFileWrapper(file)
        }
        return wrapper
    }

    override func write(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                        originalContentsURL absoluteOriginalContentsURL: URL?) throws {
        try super.write(to: url, ofType: typeName, for: saveOperation, originalContentsURL: absoluteOriginalContentsURL)
        // project.json already names the copies; put them in place before the save counts.
        try ProjectPackage.copyMedia(pendingCopies, intoPackage: url)
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { return }
                let collecting = self.collectOnSave
                self.collectOnSave = false
                if error == nil, collecting, let collected = self.pendingCollected, let package = self.fileURL {
                    let resolved = ProjectPackage.resolvedInPackage(collected, package: package)
                    self.mediaWrapper = try? FileWrapper(url: package.appending(path: ProjectPackage.mediaFolderName))
                    self.session?.adoptCollected(resolved.sources.filter { $0.packagePath != nil })
                    let n = self.pendingCopies.count
                    self.session?.status = n == 0 ? "Everything is already in the project." : "Collected \(n) file\(n == 1 ? "" : "s") into the project."
                } else if let error, collecting {
                    self.session?.status = "Couldn't collect: \(error.localizedDescription)"
                }
                self.pendingCopies = []
                self.pendingCollected = nil
            }
            completionHandler(error)
        }
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
