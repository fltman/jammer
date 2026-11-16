import AppKit
import JammerCore

/// "Edit in Jämmer" from a sibling app (SIBLINGS.md §6). A WAV, AIFF or FLAC that Flimmer
/// (or Glimmer) opens in Jämmer becomes a linked document: it plays from a copy, ⌘S saves
/// the mix back into the same file, in place, and autosave never touches it.
@MainActor
enum LinkedEditing {
    /// Sibling apps by bundle id; debug builds talk to the siblings' debug builds (SIBLINGS.md §1).
    static let siblings: [String: String] = {
        #if DEBUG
        ["com.brattoo.flimmer.debug": "Flimmer", "com.brattoo.glimmer.debug": "Glimmer"]
        #else
        ["com.brattoo.flimmer": "Flimmer", "com.brattoo.glimmer": "Glimmer"]
        #endif
    }()

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
        return siblings[id]
    }

    /// Opens `url` linked when a sibling asked and Jämmer can write the file back exactly;
    /// returns false to open it the ordinary way.
    static func open(_ url: URL, requester: String) -> Bool {
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
            alert.messageText = "\(url.lastPathComponent) couldn't be opened"
            alert.informativeText = error.localizedDescription.replacingOccurrences(of: copyName ?? "", with: url.lastPathComponent)
            alert.runModal()
            return true
        }
    }
}

extension EditorSession {
    /// File › Save Back to clip.wav: the mix as heard, plugins included, into the linked file.
    func saveBack(then done: (@MainActor (Bool) -> Void)? = nil) {
        guard let link = linkedFile else { done?(false); return }
        let project = self.project, pool = self.pool
        let markers = project.markers.map { FileMarker(position: $0.position, length: $0.length, name: $0.cueLabel) }
        status = "Saving \(link.fileName)…"
        Task {
            do {
                let plan = await PlanCompiler.mix(project, pool: pool, outOfProcess: Self.pluginSafeMode)
                try await Task.detached(priority: .userInitiated) {
                    try link.write(plan, range: 0..<project.length, markers: markers,
                                   scratch: FileManager.default.temporaryDirectory.appending(path: "jammer-saveback"))
                }.value
                document?.updateChangeCount(.changeCleared)
                status = "Saved \(link.fileName) for \(link.requester)."
                done?(true)
            } catch {
                status = "Couldn't save \(link.fileName): \(error.localizedDescription)"
                NSSound.beep()
                done?(false)
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
        alert.messageText = "“\(lost.name)” can't be saved back to \(lost.requester)"
        alert.informativeText = "\(lost.why)\n\nYour edit is still here. Save it as a Jämmer project to keep it, or put the file back where it was and press ⌘S again."
        alert.addButton(withTitle: "Save a Jämmer Copy…")
        alert.addButton(withTitle: "Cancel")
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
