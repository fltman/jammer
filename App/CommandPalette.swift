import AppKit
import JammerAgent
import SwiftUI

/// ⌘K: every command by name. Built from the same operation list as the menus
/// and the agent API, plus the app's own commands.
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let detail: String
    let shortcut: String
    let run: @MainActor () -> Void
}

@MainActor
enum CommandPalette {
    private static var panel: NSPanel?

    static func commands(session: EditorSession, timeline: TimelineView) -> [PaletteCommand] {
        var list: [PaletteCommand] = [
            .init(id: "play", title: session.isPlaying ? L10n.text("transport.stop") : L10n.text("transport.play"), detail: L10n.text("menu.transport"), shortcut: L10n.text("key.space")) { session.togglePlay() },
            .init(id: "start", title: L10n.text("transport.goToStart"), detail: L10n.text("menu.transport"), shortcut: "↩") { session.seek(0) },
            .init(id: "fit", title: L10n.text("view.zoomToFit"), detail: L10n.text("menu.view"), shortcut: "⌘0") { timeline.zoomToFit() },
            .init(id: "zsel", title: L10n.text("view.zoomToSelection"), detail: L10n.text("menu.view"), shortcut: "⌘E") { timeline.zoomToSelection() },
            .init(id: "export", title: L10n.text("file.export"), detail: L10n.text("menu.file"), shortcut: "⇧⌘E") {
                NSApp.sendAction(#selector(EditorWindowController.exportAudio(_:)), to: nil, from: nil)
            },
            .init(id: "loud", title: L10n.text("audio.measureLoudness"), detail: L10n.text("palette.group.analysis"), shortcut: "⌥⌘L") {
                NSApp.sendAction(#selector(EditorWindowController.analyzeLoudness(_:)), to: nil, from: nil)
            },
            .init(id: "collect", title: L10n.text("file.collect"), detail: L10n.text("palette.collect.detail"), shortcut: "") {
                NSApp.sendAction(#selector(JammerDocument.collectAudio(_:)), to: nil, from: nil)
            },
            .init(id: "mixer", title: L10n.text("audio.mixer"), detail: L10n.text("palette.mixer.detail"), shortcut: "⌥⌘X") {
                NSApp.sendAction(#selector(EditorWindowController.showMixer(_:)), to: nil, from: nil)
            },
            .init(id: "limit", title: L10n.text("audio.limit"), detail: L10n.text("palette.limit.detail"), shortcut: "") {
                NSApp.sendAction(#selector(EditorWindowController.limitPeaks(_:)), to: nil, from: nil)
            },
            .init(id: "assistant", title: L10n.text("assistant.ask"), detail: L10n.text("palette.assistant.detail"), shortcut: "⌥⌘A") {
                NSApp.sendAction(#selector(EditorWindowController.askAssistant(_:)), to: nil, from: nil)
            },
            .init(id: "transcript", title: L10n.text("palette.transcript"), detail: L10n.text("menu.view"), shortcut: "⌥⌘T") {
                NSApp.sendAction(#selector(EditorWindowController.toggleTranscript(_:)), to: nil, from: nil)
            },
            .init(id: "restore", title: L10n.text("palette.restore"), detail: L10n.text("menu.audio"), shortcut: "") {
                NSApp.sendAction(#selector(EditorWindowController.showRestore(_:)), to: nil, from: nil)
            },
            .init(id: "tempo", title: L10n.text("audio.setTempo"), detail: L10n.text("menu.audio"), shortcut: "") {
                NSApp.sendAction(#selector(EditorWindowController.setTempo(_:)), to: nil, from: nil)
            },
            .init(id: "agent", title: L10n.text("help.agentAccess"), detail: L10n.text("menu.help"), shortcut: "") { AgentSplash.show() },
        ]
        for (title, op, params) in MenuPresets.all {
            let spec = Operations.named(op)
            list.append(.init(id: "\(op)-\(title)", title: title, detail: spec?.description ?? "", shortcut: "") {
                session.perform(op, params)
            })
        }
        return list
    }

    static func show(over window: NSWindow, session: EditorSession, timeline: TimelineView) {
        close()
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360), styleMask: [.titled, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.appearance = NSAppearance(named: .darkAqua)
        p.backgroundColor = Theme.ink
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: PaletteView(commands: commands(session: session, timeline: timeline)) { cmd in
            close()
            window.makeKeyAndOrderFront(nil)
            cmd?.run()
        })
        window.beginSheet(p)
        panel = p
    }

    static func close() {
        if let panel, let parent = panel.sheetParent { parent.endSheet(panel) }
        panel = nil
    }
}

struct PaletteView: View {
    let commands: [PaletteCommand]
    let finish: (PaletteCommand?) -> Void
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    private var matches: [PaletteCommand] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return commands }
        return commands.filter { c in
            let t = c.title.lowercased()
            var i = t.startIndex
            for ch in q {
                guard let f = t[i...].firstIndex(of: ch) else { return false }
                i = t.index(after: f)
            }
            return true
        }.sorted { a, b in a.title.lowercased().hasPrefix(q) && !b.title.lowercased().hasPrefix(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField(L10n.text("palette.placeholder"), text: $query)
                .textFieldStyle(.plain)
                .accessibilityLabel(L10n.text("palette.field.ax"))
                .font(.title3)
                .padding(14)
                .focused($focused)
                .onSubmit { finish(matches[safe: index]) }
                .onKeyPress(.downArrow) { index = min(index + 1, max(0, matches.count - 1)); return .handled }
                .onKeyPress(.upArrow) { index = max(0, index - 1); return .handled }
                .onKeyPress(.escape) { finish(nil); return .handled }
                .onChange(of: query) { index = 0 }
            Divider()
            ScrollViewReader { proxy in
                List(Array(matches.enumerated()), id: \.element.id) { i, c in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title).foregroundStyle(i == index ? Theme.neonColor : .primary)
                            Text(c.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(c.shortcut).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { finish(c) }
                    .listRowBackground(i == index ? Theme.neonColor.opacity(0.12) : Color.clear)
                    .id(i)
                }
                .scrollContentBackground(.hidden)
                .onChange(of: index) { proxy.scrollTo(index) }
            }
        }
        .frame(width: 520, height: 360)
        .background(Theme.inkColor)
        .onAppear { focused = true }
    }
}
