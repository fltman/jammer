import AppKit
import JammerAgent
import JammerCore

/// "Edit in Jämmer" from a sibling app (SIBLINGS.md §6). A WAV, AIFF or FLAC that Flimmer
/// (or Glimmer) opens in Jämmer becomes a linked document: it plays from a copy, ⌘S saves
/// the mix back into the same file, in place, and autosave never touches it.
@MainActor
enum LinkedEditing {

    /// The sibling app that sent an "open" Apple event, or nil (Finder, Dock…).
    static func requester(of event: NSAppleEventDescriptor) -> String? {
        #if DEBUG
        // Tests hand files over from a script: `-linkAnyOpen YES`, or `-linkAnyOpen Flimmer`.
        if let any = UserDefaults.standard.string(forKey: "linkAnyOpen"), !["", "NO", "0", "false"].contains(any) {
            return ["YES", "1", "true"].contains(any) ? "Test" : any
        }
        #endif
        guard let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value,
              let app = NSRunningApplication(processIdentifier: pid), let id = app.bundleIdentifier else { return nil }
        // Only a sibling of exactly this copy's kind hands a file over (SIBLINGS §5).
        return AgentAPI.siblingName(forBundle: id, own: AgentAPI.ownKind)
    }

    /// Opens `url` linked when a sibling asked and Jämmer can write the file back exactly;
    /// returns false to open it the ordinary way.
    static func open(_ url: URL, requester: String) -> Bool {
        // The same file handed over again (SIBLINGS.md §6, point 6): the window that is already open for it
        // comes forward, with the work in it. "The same" is the path: a sibling may delete and write its
        // copy again on every hand-over, so it is a new file on disk each time.
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let open = NSDocumentController.shared.documents.compactMap { $0 as? JammerDocument }.filter { d in
            guard let r = d.session?.linkRecord else { return false }
            return URL(fileURLWithPath: r.path).resolvingSymlinksInPath().standardizedFileURL.path == path
        }
        if let edited = open.first(where: { $0.isDocumentEdited }) ?? (open.count > 1 ? open.first : nil) {
            edited.session?.checkLink()
            edited.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            if edited.isDocumentEdited { edited.session?.status = L10n.text("link.alreadyOpen", url.lastPathComponent, requester) }
            return true
        }
        // Open without changes: what the sibling sent now may differ from what was opened then, so the
        // document is opened afresh from the file as it is, in place of the old window.
        // Work on this file that waits in the journal (kept for later, or left by a stop) is what opens: the
        // same file handed over again is the same job, not a new one beside it.
        if let waiting = LinkJournalStore.waiting(forPath: path) {
            for d in open { d.session?.stopWatchingLink(); d.close() }
            let doc = LinkJournalStore.open(waiting, because: L10n.text("link.waiting.reopened", url.lastPathComponent, requester))
            doc?.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return true
        }
        for d in open { d.session?.stopWatchingLink(); d.close() }
        guard let link = LinkedFile(url: url, requester: requester) else {
            NSLog("Jammer: %@ can't be linked (format, bit depth or channels)", url.lastPathComponent)
            return false
        }
        var copyName: String?
        do {
            // The document plays from a copy (a clone on APFS), so writing the file back
            // never changes what the edit list reads.
            let copy = MediaStore.folder.appending(path: "\(UUID().uuidString.prefix(8)) \(url.lastPathComponent)")
            copyName = copy.lastPathComponent
            try FileManager.default.copyItem(at: url, to: copy)
            let r: AudioImporter.Result
            do { r = try AudioImporter.importFile(copy, mediaFolder: MediaStore.folder) } catch {
                // A file that can't be opened doesn't leave its copy behind.
                try? FileManager.default.removeItem(at: copy)
                throw error
            }
            var source = r.source
            source.name = url.deletingPathExtension().lastPathComponent
            var project = Project(source: source)
            project.tracks[0].name = source.name
            guard let controller = NSDocumentController.shared as? JammerDocumentController else { return false }
            let doc = controller.open(project, name: url.deletingPathExtension().lastPathComponent)
            doc.session?.linkedFile = link
            if let w = r.warning { doc.session?.status = w.replacingOccurrences(of: copy.lastPathComponent, with: url.lastPathComponent) }
            doc.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return true
        } catch {
            // In the words of the file the sibling sent, not of the copy made of it.
            let alert = NSAlert()
            alert.messageText = L10n.text("open.failed.title", url.lastPathComponent)
            alert.informativeText = L10n.error(error).replacingOccurrences(of: copyName ?? "", with: url.lastPathComponent)
            alert.runModal()
            return true
        }
    }
}

extension EditorSession {
    /// File › Save Back to clip.wav: the mix as heard, plugins included, into the linked file. It is rendered and
    /// written in the background; `done` is told when the file is written (nil) or why it isn't (an agent's save
    /// answers only then: scripts/check-agent-waits.py).
    func saveBack(then done: (@MainActor (Error?) -> Void)? = nil) {
        guard let link = linkedFile else { done?(CocoaError(.fileNoSuchFile)); return }
        let project = self.project, pool = self.pool
        let markers = project.markers.map { FileMarker(position: $0.position, length: $0.length, name: $0.cueLabel) }
        status = L10n.text("link.saving", link.fileName)
        Task {
            do {
                let plan = await PlanCompiler.mix(project, pool: pool, outOfProcess: Self.pluginSafeMode)
                try await Task.detached(priority: .userInitiated) {
                    try link.write(plan, range: 0..<project.length, markers: markers,
                                   scratch: FileManager.default.temporaryDirectory.appending(path: "jammer-saveback"))
                }.value
                document?.updateChangeCount(.changeCleared)
                // Saved back: nothing waits in the journal but the clean document, and it is no longer "recovered".
                recovered = false
                stepsNotSavedBack = 0
                LinkJournalStore.note(self)
                (window?.windowController as? EditorWindowController)?.showLink()
                status = L10n.text("link.saved", link.fileName, link.requester)
                done?(nil)
            } catch {
                status = L10n.text("link.saveFailed", link.fileName, L10n.error(error))
                NSSound.beep()
                done?(error)
            }
        }
    }

    /// ⌘S in a document whose link was lost: the file may be back (a disk mounted again, a file put
    /// back), and then it is linked again and saved; otherwise the user is told why it can't be, and
    /// offered the one thing that keeps the edit. Never the ordinary Save As by silence.
    func saveBackOrExplain(in window: NSWindow) {
        if let record = linkRecord, case .linked(let link) = LinkedFile.restore(record) {
            linkedFile = link
            saveBack()
            return
        }
        guard let lost = lostLink else { return }
        let alert = NSAlert()
        alert.messageText = L10n.text("link.lost.title", lost.name, lost.requester)
        alert.informativeText = L10n.text("link.lost.text", lost.why)
        alert.addButton(withTitle: L10n.text("link.lost.saveCopy"))
        alert.addButton(withTitle: L10n.text("button.cancel"))
        alert.beginSheetModal(for: window) { [weak self] answer in
            MainActor.assumeIsolated { if answer == .alertFirstButtonReturn { self?.saveJammerCopy() } }
        }
    }

    /// File › Save a Jämmer Copy…: the project as a `.jammer` package; the linked file is
    /// still what ⌘S writes.
    func saveJammerCopy() {
        guard let document, wasLinked else { return }
        document.runModalSavePanel(for: .saveToOperation, delegate: nil, didSave: nil, contextInfo: nil)
    }
}
