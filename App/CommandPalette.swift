import AppKit
import JammerAgent
import SwiftUI

/// Every command by name, for the omnibar (⌘K). Built from the same operation list as the menus
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
            .init(id: "transcribe_voice_tracks", title: L10n.text("op.transcribe_voice_tracks.title"), detail: L10n.text("menu.audio"), shortcut: "") {
                NSApp.sendAction(#selector(EditorWindowController.transcribeVoiceTracks(_:)), to: nil, from: nil)
            },
            .init(id: "export_transcript", title: L10n.text("op.export_transcript.title"), detail: L10n.text("menu.file"), shortcut: "") {
                NSApp.sendAction(#selector(EditorWindowController.exportTranscript(_:)), to: nil, from: nil)
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
            // The detail is the operation the preset runs, in the window's language (the schema's description is the API's).
            list.append(.init(id: "\(op)-\(title)", title: title, detail: L10n.operation(op), shortcut: "") {
                session.perform(op, params)
            })
        }
        return list
    }
}
