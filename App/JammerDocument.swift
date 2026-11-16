import AppKit
import JammerCore
import UniformTypeIdentifiers

extension UTType {
    static let jammerProject = UTType(exportedAs: ProjectPackage.typeIdentifier, conformingTo: .package)
}

/// Where Jammer keeps audio it decodes or receives, until a project gathers it.
/// Where this copy of Jämmer keeps its own files. Debug builds have a folder of their own, so what
/// tests leave behind can be cleared without touching anything of the real app's.
enum AppData {
    static var folder: URL {
        #if DEBUG
        // A copy started by a test, or by another session, keeps its files to itself:
        // `-dataFolder <absolute path>` (media, recipes, the plugin catalogue all go under it). And a copy
        // whose bundle id ends in ".guest" (a visitor's clone, see docs/RELEASE.md) has a folder of its
        // own without being told, as it has its own settings, autosave and saved windows by that id.
        if let given = UserDefaults.standard.string(forKey: "dataFolder"), given.hasPrefix("/") { return URL(fileURLWithPath: given) }
        let name = (Bundle.main.bundleIdentifier ?? "").hasSuffix(".guest") ? "Jammer Debug Guest" : "Jammer Debug"
        #else
        let name = "Jammer"
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: name)
    }
}

enum MediaStore {
    static var folder: URL {
        let url = AppData.folder.appending(path: "Media")
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
    /// Something to say in the status bar once the window is up (the file opened cut short).
    var pendingStatus: String?
    /// True for a document read from a project file: its audio is then read only where it may be.
    var readFromPackage = false
    /// A history read from the package before the window opened.
    var pendingHistory: History?
    /// A link read from the saved window state before the window opened.
    var pendingLink: LinkedFile.Record?
    static let historyFile = "history.json"
    /// In Jämmer's own autosaves only: the link of a document a sibling app handed over.
    static let linkFile = "link.json"

    /// The file being read, while it is being read.
    nonisolated(unsafe) private var readingURL: URL?

    override func read(from url: URL, ofType typeName: String) throws {
        readingURL = url
        defer { readingURL = nil }
        try super.read(from: url, ofType: typeName)
    }

    /// True while reading one of Jämmer's own autosaved documents back (a file in the system's
    /// Autosave Information folder). A link names the file that ⌘S writes into, so it is taken only
    /// from there: never from a project file that was opened, which could name any file it liked.
    private var readingOwnAutosave: Bool {
        guard let url = readingURL, let folder = FileManager.default.urls(for: .autosavedInformationDirectory, in: .userDomainMask).first else { return false }
        return url.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/")
    }

    override func makeWindowControllers() {
        let project = pendingProject ?? session?.project ?? Project(sampleRate: 48_000, channels: 2, tracks: [Track(name: "Track 1")])
        let s = session ?? EditorSession(project: project, fromPackage: readFromPackage, package: fileURL)
        if session == nil, let h = pendingHistory { s.load(project, history: h) }
        s.document = self
        if let pendingStatus { s.status = pendingStatus }
        pendingStatus = nil
        if let pendingLink { s.restoreLink(pendingLink) }
        pendingLink = nil
        session = s
        let wc = EditorWindowController(session: s)
        addWindowController(wc)
        if readFromPackage {
            // Once the window is up: audio the project names outside itself is asked about, not just read.
            DispatchQueue.main.async { [weak wc, weak s] in
                if let w = wc?.window, let s {
                    s.askAboutFilesOutside(in: w)
                    // And settings it brings for plugins are not loaded into them unasked.
                    s.askAboutPluginSettings(in: w)
                }
            }
        }
        AgentRegistry.shared.register(s)
    }

    /// Closing or quitting with changes. An ordinary document gets AppKit's question and its Save
    /// panel. A linked one must not: its changes belong in the file the sibling app handed over, so
    /// the question is about that file, and the Save panel never appears on its own.
    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        let linked = MainActor.assumeIsolated { session?.wasLinked ?? false }
        guard linked, isDocumentEdited, let window = windowControllers.first?.window else {
            super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
            return
        }
        let answer: @MainActor (Bool) -> Void = { [weak self] should in
            guard let self, let selector = shouldCloseSelector, let target = delegate as? NSObject else { return }
            if should { self.updateChangeCount(.changeCleared) }
            typealias Callback = @convention(c) (AnyObject, Selector, NSDocument, Bool, UnsafeMutableRawPointer?) -> Void
            unsafeBitCast(target.method(for: selector), to: Callback.self)(target, selector, self, should, contextInfo)
        }
        MainActor.assumeIsolated {
            guard let session else { return }
            let alert = NSAlert()
            if let link = session.linkedFile {
                alert.messageText = "Save your changes back to “\(link.fileName)”?"
                alert.informativeText = "\(link.requester) is waiting for this file. If you don't save, the file stays as it was and the changes are lost."
                alert.addButton(withTitle: "Save Back")
            } else {
                let lost = session.lostLink
                alert.messageText = "“\(lost?.name ?? "The file")” can't be saved back to \(lost?.requester ?? "the other app")"
                alert.informativeText = "\(lost?.why ?? "")\n\nSave your changes as a Jämmer project to keep them, or close without saving."
                alert.addButton(withTitle: "Save a Jämmer Copy…")
            }
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")
            alert.buttons[1].hasDestructiveAction = true
            window.makeKeyAndOrderFront(nil)
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated {
                    switch response {
                    case .alertFirstButtonReturn where session.linkedFile != nil:
                        session.saveBack { saved in answer(saved) }
                    case .alertFirstButtonReturn:
                        // The copy is saved through the ordinary panel; the document stays open until that is done.
                        session.saveJammerCopy()
                        answer(false)
                    case .alertSecondButtonReturn: answer(true)
                    default: answer(false)
                    }
                }
            }
        }
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
        if let project, let data = try? ProjectPackage.encode(project) { coder.encode(data as NSData, forKey: Self.restoreKey) }
        coder.encode(displayName as NSString, forKey: Self.restoreKey + ".name")
        // A linked document stays linked across a quit, a crash or a kill (SIBLINGS.md §6).
        let record = MainActor.assumeIsolated { session?.linkRecord ?? pendingLink }
        if let record, let data = try? JSONEncoder().encode(record) { coder.encode(data as NSData, forKey: Self.restoreKey + ".link") }
    }

    override func restoreState(with coder: NSCoder) {
        super.restoreState(with: coder)
        // The link first, and whatever else is restored: also a document that comes back from its autosave.
        if let data = coder.decodeObject(of: NSData.self, forKey: Self.restoreKey + ".link") as Data?,
           let record = try? JSONDecoder().decode(LinkedFile.Record.self, from: data) {
            MainActor.assumeIsolated {
                if let session { session.restoreLink(record) } else { pendingLink = record }
            }
        }
        // The name too, whichever way the document came back: one that returns from its autosave would
        // otherwise be "Untitled".
        if fileURL == nil, let name = coder.decodeObject(of: NSString.self, forKey: Self.restoreKey + ".name") as String?, !name.isEmpty { displayName = name }
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
        let (project, notes): (Project, [String])
        do { (project, notes) = try ProjectPackage.readChecked(fileWrapper, packageURL: fileURL) } catch { throw OpenFailure.saying(error) }
        // A Media folder that is a link to somewhere else is not this project's media.
        let media = fileWrapper.fileWrappers?[ProjectPackage.mediaFolderName]
        mediaWrapper = media?.isDirectory == true ? media : nil
        readFromPackage = true
        if !notes.isEmpty { pendingStatus = notes.joined(separator: " ") }
        let history = fileWrapper.fileWrappers?[Self.historyFile]?.regularFileContents.flatMap { try? JSONDecoder().decode(History.self, from: $0) }
        let link = readingOwnAutosave ? fileWrapper.fileWrappers?[Self.linkFile]?.regularFileContents.flatMap { try? JSONDecoder().decode(LinkedFile.Record.self, from: $0) } : nil
        // NSDocument reads on the main thread (no concurrent reading).
        MainActor.assumeIsolated {
            if let session {
                // The rule first, the project after: loading opens the files.
                session.restrictReading(package: self.fileURL)
                session.load(project, history: history)
                if !notes.isEmpty { session.status = notes.joined(separator: " ") }
                if let link { session.restoreLink(link) }
            } else {
                pendingProject = project; pendingHistory = history
                if let link { pendingLink = link }
            }
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
        // What this document plays from now was opened under the user's hand: saving it makes a
        // project that may read those files again. (Files it was refused stay refused.)
        MainActor.assumeIsolated {
            guard let s = session else { return }
            let refused = Set(s.pool.refused.keys).union(s.pool.missing)
            ProjectAccess.approve(s.project.sources.filter { !refused.contains($0.id) && $0.packagePath == nil && !$0.path.isEmpty }.map { SourcePool.resolve($0) })
        }
        pendingCopies = []
        pendingCollected = nil
        if collectOnSave, let p = project {
            let existing = Set(mediaWrapper?.fileWrappers?.keys.map { $0 } ?? [])
            // Only what the document is actually reading goes into the package: a file it was refused isn't copied in.
            let skip = MainActor.assumeIsolated { session.map { Set($0.pool.refused.keys).union($0.pool.missing) } ?? [] }
            let (collected, copies) = ProjectPackage.planCollection(p, existingMedia: existing, skipping: skip)
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
        // An autosave of a linked document carries its link, so the document that comes back from it
        // (after a crash, when the window's own state is gone) is still linked. A project the user
        // saves does not: a Jämmer Copy is a project of its own.
        let autosave = saveOperation == .autosaveElsewhereOperation || saveOperation == .autosaveAsOperation || saveOperation == .autosaveInPlaceOperation
        if autosave, let record = MainActor.assumeIsolated({ session?.linkRecord ?? pendingLink }), let data = try? JSONEncoder().encode(record) {
            try? data.write(to: url.appending(path: Self.linkFile))
        }
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

/// AppKit's alert for a file that won't open is its own headline ("The document … could not be
/// opened.") followed by the error's failure reason, and nothing of a plain description. So the
/// reader's words go in as the reason, or the alert says that it failed and not why.
enum OpenFailure {
    static func saying(_ error: Error, replacing copy: String? = nil, with name: String? = nil) -> NSError {
        let e = error as NSError
        guard e.localizedFailureReason == nil else { return e }
        var why = error.localizedDescription
        if let copy, let name { why = why.replacingOccurrences(of: copy, with: name) }
        return NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError,
                       userInfo: [NSLocalizedDescriptionKey: why, NSLocalizedFailureReasonErrorKey: why, NSUnderlyingErrorKey: e])
    }
}

/// Opens audio files as new projects instead of documents of their own.
final class JammerDocumentController: NSDocumentController {
    override func makeDocument(withContentsOf url: URL, ofType typeName: String) throws -> NSDocument {
        guard let type = UTType(typeName), !type.conforms(to: .jammerProject), type.conforms(to: .audio) else {
            return try super.makeDocument(withContentsOf: url, ofType: typeName)
        }
        let result: AudioImporter.Result
        do { result = try AudioImporter.importFile(url, mediaFolder: MediaStore.folder) } catch { throw OpenFailure.saying(error) }
        let doc = JammerDocument()
        doc.pendingProject = Project(source: result.source)
        doc.pendingStatus = result.warning
        // The user picked this file: a project saved from it may read it again.
        MainActor.assumeIsolated { ProjectAccess.approve([url]) }
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
