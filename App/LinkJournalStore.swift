import AppKit
import JammerCore

/// Jämmer's own record of linked documents, as the app keeps it (`LinkJournal` in the core; the-apps/
/// SIBLINGS.md §6, point 6). Written when a document is linked and after every step, off the main
/// thread; read once when Jämmer starts, when every entry with changes that were not saved back is
/// opened again, linked and with its changes, whatever the system's own saved windows say. A linked
/// window is not in the system's saved windows and has no autosave of its own: there is one way back,
/// not two.
///
/// Jämmer is not sandboxed, so the link's bookmark is an ordinary one (it follows a file that is moved);
/// there is no security scope to open or close.
@MainActor
enum LinkJournalStore {
    static let journal: LinkJournal = {
        #if DEBUG
        // A test copy keeps its journal to itself: `-linkJournalFolder <absolute path>`.
        if let given = UserDefaults.standard.string(forKey: "linkJournalFolder"), given.hasPrefix("/") { return LinkJournal(folder: URL(fileURLWithPath: given)) }
        #endif
        return LinkJournal(folder: AppData.folder.appending(path: "Link Journal"))
    }()

    /// Writes happen one after another on this queue; only the newest waiting one for a document is made.
    private static let queue = DispatchQueue(label: "com.brattoo.jammer.linkjournal", qos: .utility)
    private final class Latest: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [UUID: Int] = [:]
        func next(_ id: UUID) -> Int { lock.lock(); defer { lock.unlock() }; counts[id, default: 0] += 1; return counts[id]! }
        func isLatest(_ id: UUID, _ n: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return counts[id] == n }
    }
    private static let latest = Latest()
    /// Entries found broken when Jämmer started (left where they are).
    private(set) static var broken = 0

    /// The document as it stands goes into the journal. Called when it is linked and after every step.
    static func note(_ session: EditorSession) {
        guard let record = session.linkRecord else { return }
        let id = session.linkEntryID ?? UUID()
        session.linkEntryID = id
        let project = session.project, name = session.name, edited = session.document?.isDocumentEdited ?? false, steps = session.stepsNotSavedBack
        let n = latest.next(id), journal = journal, latest = latest
        queue.async {
            // A newer state of the same document is already waiting: that one is written, not this.
            guard latest.isLatest(id, n), let data = try? ProjectPackage.encode(project) else { return }
            do { try journal.write(.init(id: id, record: record, name: name, project: data, edited: edited, steps: steps)) }
            catch { NSLog("Jammer: the link journal couldn't be written (%@)", error.localizedDescription) }
        }
    }

    /// The document's changes are kept for later (the window is closing, or Jämmer is quitting): its
    /// entry is written now, before anything goes, and says that it was kept on purpose.
    static func keep(_ session: EditorSession) {
        guard let record = session.linkRecord, let data = try? ProjectPackage.encode(session.project) else { return }
        let id = session.linkEntryID ?? UUID()
        session.linkEntryID = id
        _ = latest.next(id)
        let entry = LinkJournal.Entry(id: id, record: record, name: session.name, project: data, edited: true, kept: true, steps: session.stepsNotSavedBack)
        let journal = journal
        queue.sync {
            do { try journal.write(entry) } catch { NSLog("Jammer: the link journal couldn't be written (%@)", error.localizedDescription) }
        }
    }

    /// The entries that wait without a window: kept for later, or left by a stop. And the files that can't be read.
    static func waiting() -> (entries: [LinkJournal.Read], broken: [URL]) {
        queue.sync {}
        let found = journal.read()
        let open = Set(AgentRegistry.shared.sessions.compactMap(\.linkEntryID))
        return (found.entries.filter { $0.entry.edited && !open.contains($0.entry.id) }, found.broken)
    }

    /// A waiting entry for this file, if there is one: the same file handed over again opens it, with the work in it.
    static func waiting(forPath path: String) -> LinkJournal.Read? {
        waiting().entries.last { URL(fileURLWithPath: $0.entry.record.path).resolvingSymlinksInPath().standardizedFileURL.path == path }
    }

    /// Given up from the list of waiting files: the entry is moved to the Trash, never deleted.
    static func discard(_ id: UUID) -> Bool {
        queue.sync {}
        do { try journal.trash(id); return true } catch { NSLog("Jammer: a link journal entry couldn't be moved to the Trash (%@)", error.localizedDescription); return false }
    }

    /// Opens an entry as a document: linked, with its changes, and said in the window.
    @discardableResult
    static func open(_ read: LinkJournal.Read, because why: String? = nil) -> JammerDocument? {
        guard let controller = NSDocumentController.shared as? JammerDocumentController else { return nil }
        let entry = read.entry
        let doc = controller.open(read.project, name: entry.name)
        guard let session = doc.session else { return nil }
        session.linkEntryID = entry.id
        session.recovered = true
        session.keptFromBefore = entry.kept
        session.stepsNotSavedBack = entry.steps ?? 1
        session.restoreLink(entry.record)
        doc.updateChangeCount(.changeDone)
        // Said after the link's own words (a file that is gone says so first, and this then says the work is here).
        let requester = entry.record.requester
        let what = why ?? (entry.kept ? L10n.text("link.kept.status", requester) : L10n.text("link.recovered.status", requester))
        // A warning: the app that handed the file over doesn't have these changes yet.
        session.say(session.lostLink == nil ? what : L10n.text("link.recovered.lost", what, session.status ?? ""), .warning)
        (doc.windowControllers.first as? EditorWindowController)?.showLink()
        return doc
    }

    /// The document's entry goes: its changes were saved back and it was closed, or the user gave them up.
    static func forget(_ session: EditorSession) {
        guard let id = session.linkEntryID else { return }
        session.linkEntryID = nil
        _ = latest.next(id)          // anything still waiting for it is not written
        let journal = journal
        queue.sync { journal.remove(id) }
    }

    /// Jämmer is quitting: a linked document without changes leaves no entry (it follows the system's
    /// setting like any window). One with changes keeps its entry; everything waiting is written first.
    static func settle() {
        for session in AgentRegistry.shared.sessions where session.linkRecord != nil {
            if session.document?.isDocumentEdited == true { keep(session) } else { forget(session) }
        }
        queue.sync {}
        // Whatever else still waits with changes (a document the system's own question at Quit closed
        // without asking Jämmer) was kept by an orderly quit, not left by a stop: it says so when it comes back.
        let journal = journal
        for read in journal.read().entries where read.entry.edited && !read.entry.kept {
            var entry = read.entry
            entry.kept = true
            try? journal.write(entry)
        }
    }

    /// How many entries wait, and how many can't be read (`GET /api/v1/status`).
    static var counts: (entries: Int, broken: Int) {
        let now = journal.read()
        return (now.entries.count, now.broken.count)
    }

    /// When Jämmer starts: every entry with changes that were not saved back is opened again. An entry
    /// without changes is from a document that was open and clean when Jämmer ended; it goes. A broken
    /// entry is left where it is and said in the log, never removed.
    static func recover() {
        let found = journal.read()
        broken = found.broken.count
        for file in found.broken { NSLog("Jammer: a link journal entry couldn't be read and was left as it is: %@", file.path) }
        for read in found.entries {
            let entry = read.entry
            if AgentRegistry.shared.sessions.contains(where: { $0.linkEntryID == entry.id }) { continue }
            guard entry.edited else { journal.remove(entry.id); continue }
            // A window the system brought back for the same file (its own saved windows, where a linked
            // window can still be from before it was kept out of them). Without changes it is the document
            // as it was before the work: it gives way to the journal's. With changes of its own it stays,
            // and takes over the journal's entry, so that there is one document for the file and not two.
            let same = AgentRegistry.shared.sessions.filter { $0.linkEntryID != entry.id && $0.linkRecord?.path == entry.record.path }
            if let kept = same.first(where: { $0.document?.isDocumentEdited == true }) {
                let own = kept.linkEntryID
                kept.linkEntryID = entry.id
                kept.recovered = true
                if let own { journal.remove(own) }
                note(kept)
                (kept.window?.windowController as? EditorWindowController)?.showLink()
                continue
            }
            for stale in same {
                let own = stale.linkEntryID
                stale.linkEntryID = nil
                if let own { journal.remove(own) }
                stale.stopWatchingLink()
                stale.document?.close()
            }
            open(read)
        }
    }
}
