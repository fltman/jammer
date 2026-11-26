import AppKit
import JammerAudio
import JammerCore
import Observation
import SwiftUI

/// Recordings that didn't finish and that no open document claims: a recording in a document that was never saved
/// (the most common case: a first recording in a new window), or whose file is gone. Once the saved windows are back
/// after a launch, they are listed in a window of their own (never an alert that holds up the launch, COMFORT):
/// each one can be opened as a new document, its takes on tracks of their own, or forgotten (the journal only; the
/// files stay in the media folder). A document that opens later with its id still gets its own offer.
@MainActor
enum RecoveredRecordings {
    private static var window: NSWindow?
    private static let model = Model()
    private static var checked = false

    @MainActor @Observable
    final class Model {
        var left: [RecordingJournal] = []
    }

    /// After the system's saved windows: when they are restored, or a few seconds in if there were none.
    static func checkAfterLaunch() {
        let token = NotificationCenter.default.addObserver(forName: NSApplication.didFinishRestoringWindowsNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { check() } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            NotificationCenter.default.removeObserver(token)
            check()
        }
    }

    /// The journals left that no open document has, and none recording now.
    static func unclaimed() -> [RecordingJournal] {
        let open = Set(AgentRegistry.shared.sessions.compactMap(\.project.documentID))
        return RecordingJournal.all(in: EditorSession.journalFolder).filter { !open.contains($0.documentID) }
    }

    static func check() {
        guard !checked else { return }
        checked = true
        let left = unclaimed()
        guard !left.isEmpty else { return }
        model.left = left
        show()
    }

    private static func show() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 260), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = L10n.text("recovered.window")
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: RecoveredView(model: model, open: open, forget: forget))
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    private static func done(_ j: RecordingJournal) {
        model.left.removeAll { $0.documentID == j.documentID }
        if model.left.isEmpty { window?.close(); window = nil }
    }

    /// Opened as a new document. If the document itself came back meanwhile, its own offer has it instead.
    static func open(_ j: RecordingJournal) {
        guard RecordingJournal.left(by: j.documentID, in: EditorSession.journalFolder) != nil, unclaimed().contains(where: { $0.documentID == j.documentID }) else {
            done(j)
            return
        }
        guard let p = j.recoveredProject(), let controller = NSDocumentController.shared as? JammerDocumentController else {
            NSSound.beep()
            window.map { w in
                let a = NSAlert()
                a.messageText = L10n.text("recovered.nothing")
                a.beginSheetModal(for: w)
            }
            return
        }
        let doc = controller.open(p, name: L10n.text("recovered.docName"))
        doc.session?.say(L10n.count("recover.done", p.tracks.count), .success)
        if let s = doc.session { StorageScanner.note(s) }
        RecordingJournal.remove(j.documentID, in: EditorSession.journalFolder)
        done(j)
    }

    static func forget(_ j: RecordingJournal) {
        RecordingJournal.remove(j.documentID, in: EditorSession.journalFolder)
        done(j)
    }
}

private struct RecoveredView: View {
    let model: RecoveredRecordings.Model
    let open: (RecordingJournal) -> Void
    let forget: (RecordingJournal) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("recovered.text")).fixedSize(horizontal: false, vertical: true)
            List(model.left, id: \.documentID) { j in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(DateFormatter.localizedString(from: j.started, dateStyle: .medium, timeStyle: .short))
                        Group {
                            Text(L10n.count("recovered.row.takes", j.takes.count))
                            if let path = j.documentPath {
                                Text(L10n.text("recovered.row.saved", (path as NSString).lastPathComponent))
                            } else {
                                Text(L10n.text("recovered.row.untitled"))
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L10n.text("recovered.open")) { open(j) }
                    Button(L10n.text("recover.forget")) { forget(j) }
                        .help(L10n.text("recovered.forget.help"))
                }
                .accessibilityElement(children: .contain)
            }
        }
        .padding(16)
        .frame(minWidth: 460, minHeight: 200)
    }
}
