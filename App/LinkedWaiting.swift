import AppKit
import JammerCore
import SwiftUI

/// File › Linked Files Waiting…: the work on files a sibling app handed over that was kept for later (or
/// left by a stop) and has no window now. Each can be opened again, or given up; giving up asks once,
/// says what is lost, and moves the work to the Trash. A record that can't be read is shown and left alone.
@MainActor
enum LinkedWaitingWindow {
    private static var window: NSWindow?

    static func show() {
        let w = window ?? {
            let w = EscClosingWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = L10n.text("link.waiting.title")
            w.isReleasedWhenClosed = false
            w.identifier = NSUserInterfaceItemIdentifier("linked.waiting")
            window = w
            return w
        }()
        // Read afresh every time it is shown.
        w.contentViewController = NSHostingController(rootView: LinkedWaitingList(close: { w.close() }))
        w.center()
        w.makeKeyAndOrderFront(nil)
    }
}

private struct LinkedWaitingList: View {
    let close: () -> Void
    @State private var found = LinkJournalStore.waiting()
    @State private var asking: LinkJournal.Read?

    private static func age(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
    private func lost(_ r: LinkJournal.Read) -> String {
        L10n.text("link.waiting.lost", L10n.count("link.close.steps", max(1, r.entry.steps ?? 1)), r.entry.record.requester)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("link.waiting.about")).fixedSize(horizontal: false, vertical: true)
            if found.entries.isEmpty && found.broken.isEmpty {
                Text(L10n.text("link.waiting.none")).foregroundStyle(.secondary).accessibilityIdentifier("linked.waiting.none")
            }
            ForEach(found.entries, id: \.entry.id) { r in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("link.waiting.row", URL(fileURLWithPath: r.entry.record.path).lastPathComponent, r.entry.record.requester)).fontWeight(.medium)
                        Text(L10n.text("link.waiting.row.detail", L10n.count("link.close.steps", max(1, r.entry.steps ?? 1)), Self.age(r.entry.written)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer()
                    Button(L10n.text("link.waiting.open")) {
                        LinkJournalStore.open(r)
                        close()
                    }
                    .accessibilityIdentifier("linked.waiting.open")
                    Button(L10n.text("link.waiting.discard")) { asking = r }
                        .accessibilityIdentifier("linked.waiting.discard")
                }
            }
            ForEach(found.broken, id: \.self) { file in
                VStack(alignment: .leading, spacing: 2) {
                    StateLine(kind: .error, text: L10n.text("link.waiting.broken"), font: .body)
                    Text(file.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            HStack { Spacer(); Button(L10n.text("link.waiting.done")) { close() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 560)
        .frame(minHeight: 200)
        .confirmationDialog(asking.map { L10n.text("link.waiting.discard.title", URL(fileURLWithPath: $0.entry.record.path).lastPathComponent) } ?? "",
                            isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }), presenting: asking) { r in
            Button(L10n.text("link.waiting.discard.yes"), role: .destructive) {
                _ = LinkJournalStore.discard(r.entry.id)
                found = LinkJournalStore.waiting()
            }
            Button(L10n.text("link.close.cancel"), role: .cancel) {}
        } message: { r in
            Text(lost(r))
        }
    }
}
