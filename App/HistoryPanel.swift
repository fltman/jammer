import AppKit
import JammerCore
import SwiftUI

/// View › History: the document's history as a tree. The branch you're on is bright,
/// other branches dim; click a step to go there (one undo step back).
@MainActor
enum HistoryPanel {
    private static var windows: [ObjectIdentifier: NSWindow] = [:]

    static func show(_ session: EditorSession) {
        let key = ObjectIdentifier(session)
        if let w = windows[key] { w.makeKeyAndOrderFront(nil); return }
        let w = EscClosingWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 460), styleMask: [.titled, .closable, .resizable, .utilityWindow],
                                 backing: .buffered, defer: false)
        w.title = "History — \(session.name)"
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: HistoryView(session: session))
        w.center()
        w.makeKeyAndOrderFront(nil)
        windows[key] = w
    }
}

struct HistoryView: View {
    let session: EditorSession

    struct Row: Identifiable {
        var id: UUID
        var action: String
        var time: Date
        var depth: Int
        var active: Bool
        var current: Bool
    }

    /// Depth-first, oldest child first, so each branch reads top to bottom.
    private var rows: [Row] {
        _ = session.historyVersion
        guard let h = session.history else { return [] }
        let active = Set(h.activePath)
        var out: [Row] = []
        func visit(_ n: History.Node, _ depth: Int) {
            out.append(Row(id: n.id, action: n.action, time: n.time, depth: depth, active: active.contains(n.id), current: n.id == h.current))
            let kids = h.children(of: n.id).sorted { $0.time < $1.time }
            for (i, k) in kids.enumerated() { visit(k, depth + (kids.count > 1 && i > 0 ? 1 : 0)) }
        }
        for root in h.nodes.filter({ $0.parent == nil }) { visit(root, 0) }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let pruned = session.history?.pruned, pruned > 0 {
                Label("\(pruned) older step\(pruned == 1 ? " was" : "s were") removed to keep the history at \(session.history?.limit ?? 500) steps.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).padding(10)
            }
            List(rows) { r in
                Button { try? session.jump(to: r.id) } label: {
                    HStack(spacing: 6) {
                        Text(r.action).fontWeight(r.current ? .semibold : .regular)
                        Spacer()
                        Text(r.time, style: .time).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.leading, CGFloat(r.depth) * 14)
                    .foregroundStyle(r.current ? Theme.neonColor : (r.active ? Color.primary : Color.secondary))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(r.action)\(r.current ? ", current" : "")\(r.active ? "" : ", other branch")")
            }
        }
        .frame(minWidth: 300, minHeight: 300)
    }
}
