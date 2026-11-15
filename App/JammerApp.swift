import AppKit
import JammerAgent

/// Operations with preset parameters, for menus and the palette.
enum MenuPresets {
    static let all: [(String, String, [String: JSONValue])] = [
        ("Fade In", "fade_in", [:]),
        ("Fade Out", "fade_out", [:]),
        ("Silence", "silence", [:]),
        ("Crop to Selection", "crop", [:]),
        ("Insert 1 Second of Silence", "insert_silence", ["duration": .number(1)]),
        ("Gain +1 dB", "gain", ["db": .number(1)]),
        ("Gain −1 dB", "gain", ["db": .number(-1)]),
        ("Gain +6 dB", "gain", ["db": .number(6)]),
        ("Gain −6 dB", "gain", ["db": .number(-6)]),
        ("Normalize to −16 LUFS (podcast)", "normalize", ["target": .string("loudness"), "level": .number(-16)]),
        ("Normalize to −23 LUFS (EBU R 128)", "normalize", ["target": .string("loudness"), "level": .number(-23)]),
        ("Normalize Peak to −1 dBFS", "normalize", ["target": .string("peak"), "level": .number(-1)]),
        ("Normalize True Peak to −1 dBTP", "normalize", ["target": .string("true_peak"), "level": .number(-1)]),
    ]
}

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Must exist before anything asks for NSDocumentController.shared.
        _ = JammerDocumentController()
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.mainMenu = buildMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AgentServer.shared.start()
        if UserDefaults.standard.object(forKey: AgentSplashView.showAtLaunchKey) as? Bool ?? true {
            Task {
                // Wait for the port so the splash shows the real address.
                for _ in 0..<40 where AgentServer.shared.port == nil && AgentServer.shared.failure == nil {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                AgentSplash.show()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        UploadStore.shared.removeAll()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSDocumentController.shared.openDocument(nil) }
        return true
    }

    @objc func showAgentAccess(_ sender: Any?) { AgentSplash.show() }

    @objc func openAgentGuide(_ sender: Any?) {
        if let s = AgentServer.shared.guideURL, let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }

    @objc func openHomepage(_ sender: Any?) {
        if let s = Bundle.main.object(forInfoDictionaryKey: "JammerHomepage") as? String, let url = URL(string: s) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Menus

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            return i
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            i.submenu = m
            return i
        }
        func op(_ title: String, _ name: String, _ params: [String: JSONValue] = [:], _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = item(title, #selector(EditorWindowController.performOperation(_:)), key, mods)
            i.representedObject = OperationItem(name, params)
            return i
        }

        main.addItem(submenu("Jämmer", [
            item("About Jämmer", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item("Hide Jämmer", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            item("Quit Jämmer", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(submenu("File", [
            item("New", #selector(NSDocumentController.newDocument(_:)), "n"),
            item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"),
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Save…", #selector(NSDocument.save(_:)), "s"),
            item("Duplicate", #selector(NSDocument.duplicate(_:)), "s", [.command, .shift]),
            item("Revert to Saved", #selector(NSDocument.revertToSaved(_:)), ""),
            .separator(),
            item("Export Audio…", #selector(EditorWindowController.exportAudio(_:)), "e", [.command, .shift]),
        ]))
        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(TimelineOverlay.cut(_:)), "x"),
            item("Copy", #selector(TimelineOverlay.copy(_:)), "c"),
            item("Paste", #selector(TimelineOverlay.paste(_:)), "v"),
            item("Delete", #selector(TimelineOverlay.delete(_:)), ""),
            item("Select All", #selector(TimelineOverlay.selectAll(_:)), "a"),
            .separator(),
            item("Command Palette…", #selector(EditorWindowController.showCommandPalette(_:)), "k"),
        ]))
        main.addItem(submenu("Audio", [
            op("Fade In", "fade_in", [:], "i", [.command, .option]),
            op("Fade Out", "fade_out", [:], "o", [.command, .option]),
            op("Silence", "silence", [:], "l", [.command, .shift]),
            op("Crop to Selection", "crop", [:], "t"),
            op("Insert 1 Second of Silence", "insert_silence", ["duration": .number(1)]),
            .separator(),
            op("Gain +1 dB", "gain", ["db": .number(1)], "]", [.command]),
            op("Gain −1 dB", "gain", ["db": .number(-1)], "[", [.command]),
            .separator(),
            op("Normalize to −16 LUFS (podcast)", "normalize", ["target": .string("loudness"), "level": .number(-16)]),
            op("Normalize to −23 LUFS (EBU R 128)", "normalize", ["target": .string("loudness"), "level": .number(-23)]),
            op("Normalize Peak to −1 dBFS", "normalize", ["target": .string("peak"), "level": .number(-1)]),
            op("Normalize True Peak to −1 dBTP", "normalize", ["target": .string("true_peak"), "level": .number(-1)]),
            .separator(),
            item("Measure Loudness", #selector(EditorWindowController.analyzeLoudness(_:)), "l", [.command, .option]),
            item("Add Marker", #selector(EditorWindowController.addMarker(_:)), "m", [.command, .option]),
            item("Set Tempo…", #selector(EditorWindowController.setTempo(_:)), ""),
        ]))
        main.addItem(submenu("Transport", [
            // Space and Return are handled by the timeline, so text fields keep them.
            item("Play", #selector(EditorWindowController.togglePlayback(_:)), "p", [.command, .option]),
            item("Go to Start", #selector(EditorWindowController.goToStart(_:)), ""),
        ]))
        main.addItem(submenu("View", [
            item("Zoom In", #selector(EditorWindowController.zoomIn(_:)), "+"),
            item("Zoom Out", #selector(EditorWindowController.zoomOut(_:)), "-"),
            item("Zoom to Fit", #selector(EditorWindowController.zoomToFit(_:)), "0"),
            item("Zoom to Selection", #selector(EditorWindowController.zoomToSelection(_:)), "e"),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))
        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:)), ""),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), ""),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu
        let help = submenu("Help", [
            item("Agent Access…", #selector(showAgentAccess(_:)), "", target: self),
            item("Open the Agent Guide", #selector(openAgentGuide(_:)), "", target: self),
            item("Jämmer Website", #selector(openHomepage(_:)), "", target: self),
        ])
        main.addItem(help)
        NSApp.helpMenu = help.submenu
        return main
    }
}
