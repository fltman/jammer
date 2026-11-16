#if JAMMER_DEREVERB
import JammerDereverb
#endif
import AppKit
import JammerAgent
import JammerAudio
import JammerCore
import JammerDenoise
import JammerDiarize
import JammerMP3
import JammerSpeech

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
        #if JAMMER_DEREVERB
        // Reverb reduction (WPE); a build can leave it out (Config/Features.xcconfig). Before the menu, which follows it.
        WPEDereverb.register()
        #endif
        #if !JAMMER_SPECTRAL_FREEFORM
        // Lasso and brush can be left out of a build (Config/Features.xcconfig): only the box then.
        Operations.spectralFreeform = false
        #endif
        NSApp.mainMenu = buildMenu()
        // Our own "open documents" handler: AppKit hands document-based apps' opens straight
        // to the document controller, so this is where the sending app can be seen.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleOpenDocuments(_:reply:)),
                                                     forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenDocuments))
    }

    @objc func showSettings(_ sender: Any?) { SettingsWindow.show() }
    @objc func showBatch(_ sender: Any?) { BatchWindow.show() }
    @objc func importTimeline(_ sender: Any?) { TimelineImporter.choose() }

    @objc func handleOpenDocuments(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let list = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        let items = list.numberOfItems > 0 ? (1...list.numberOfItems).compactMap { list.atIndex($0) } : [list]
        open(items.compactMap { $0.coerce(toDescriptorType: typeFileURL)?.fileURLValue ?? $0.fileURLValue }, requester: LinkedEditing.requester(of: event))
    }

    /// Files from Finder open the ordinary way; from Flimmer or Glimmer, WAV, AIFF and FLAC
    /// open linked (SIBLINGS.md §6).
    func open(_ urls: [URL], requester: String?) {
        for url in urls {
            if let requester, LinkedEditing.open(url, requester: requester) { continue }
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Noise reduction: DeepFilterNet 3 with the model that ships in the app.
        if let model = Bundle.main.url(forResource: "DeepFilterNet3_onnx", withExtension: "tar.gz"), let d = try? Denoiser(modelPath: model) {
            d.register()
        }
        // Saved plugin settings a project brings from elsewhere are asked about before they are loaded.
        PluginStateTrust.install()
        #if JAMMER_CLAP
        // CLAP: found by a scan in a helper process, run in helper processes. A build can leave it
        // out (Config/Features.xcconfig), and releases do until it has been tried in a signed build.
        HostedPluginsController.start()
        #endif
        // Tempo and beats: the system's own analysis, on this Mac.
        MusicRhythm.register()
        // MP3 through LAME, a separate dynamic framework (LGPL).
        MP3Writer.register()
        // Diarisation: the Community-1 model, fetched from the user's model source on first use.
        let store = ModelStore.standard()
        Diarization.engine = FluidDiarizer(folder: store.folder.appending(path: "diarisation"), source: store.source)
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

    /// Flimmer doesn't have the receiving side yet, so the command is in debug builds only;
    /// it moves into every build (and the guide and manual) when it has been tried against Flimmer.
    private var sendToFlimmerItems: [NSMenuItem] {
        #if DEBUG
        let i = NSMenuItem(title: "Send to Flimmer…", action: #selector(EditorWindowController.sendToFlimmer(_:)), keyEquivalent: "")
        return [i]
        #else
        return []
        #endif
    }

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

        func restoreItem(_ title: String, _ kind: String) -> NSMenuItem {
            let i = item(title, #selector(EditorWindowController.showRestore(_:)))
            i.representedObject = kind
            if kind == "dereverb" { i.isHidden = Restoration.dereverber == nil }
            return i
        }

        main.addItem(submenu("Jämmer", [
            item("About Jämmer", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item("Settings…", #selector(AppDelegate.showSettings(_:)), ","),
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
            item("Collect Audio and Save", #selector(JammerDocument.collectAudio(_:)), ""),
            .separator(),
            item("Import Tracks…", #selector(EditorWindowController.importTracks(_:)), "i", [.command, .shift]),
            item("Import Final Cut Pro XML…", #selector(AppDelegate.importTimeline(_:)), ""),
            item("Export Audio…", #selector(EditorWindowController.exportAudio(_:)), "e", [.command, .shift]),
            item("Batch…", #selector(AppDelegate.showBatch(_:)), "b", [.command, .option]),
        ] + sendToFlimmerItems))
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
            submenu("Loudness Preset", LoudnessPreset.allCases.map { op($0.title, "loudness_preset", ["preset": .string($0.rawValue)]) }),
            submenu("Level Speakers", [op("One Gain per Speaker", "level_speakers"),
                                       op("Ride Each Speaker's Level", "level_speakers", ["mode": .string("dynamic")])]),
            submenu("Remove Bleed", [op("Gate Each Track Outside Its Speaker", "debleed", ["method": .string("gate")]),
                                     op("Cancel the Other Tracks' Leak", "debleed", ["method": .string("cancel")])]),
            item("Duck Under Speech…", #selector(EditorWindowController.duckUnderSpeech(_:))),
            item("Limit Peaks…", #selector(EditorWindowController.limitPeaks(_:))),
            .separator(),
            item("Measure Loudness", #selector(EditorWindowController.analyzeLoudness(_:)), "l", [.command, .option]),
            item("Add Marker", #selector(EditorWindowController.addMarker(_:)), "m", [.command, .option]),
            item("Set Tempo…", #selector(EditorWindowController.setTempo(_:)), ""),
            op("Detect Tempo", "detect_tempo"),
            .separator(),
            restoreItem("Remove Hum…", "dehum"),
            restoreItem("Repair Clipping…", "declip"),
            restoreItem("Remove Clicks…", "declick"),
            restoreItem("Reduce Noise…", "denoise"),
            restoreItem("Reduce Reverb…", "dereverb"),
            item("Attenuate Frequencies…", #selector(EditorWindowController.attenuateFrequencies(_:)), ""),
            item("Attenuate Area…", #selector(EditorWindowController.attenuateArea(_:)), ""),
            item("Heal Area", #selector(EditorWindowController.healArea(_:)), ""),
            item("Edit Spectrum Numerically…", #selector(EditorWindowController.editSpectrumNumerically(_:)), ""),
            .separator(),
            submenu("Find Speakers", [
                item("Automatically", #selector(EditorWindowController.findSpeakers(_:)), ""),
                .separator(),
            ] + (2...4).map { n in
                let i = item("\(n) Speakers", #selector(EditorWindowController.findSpeakers(_:)), "")
                i.representedObject = n
                return i
            }),
            submenu("Separate Stems", ["music4": "Vocals, Drums, Bass, Other (music)", "dialog": "Speech, Music, Effects (soundtrack)"].sorted { $0.key > $1.key }.map { model, title in
                let i = item(title, #selector(EditorWindowController.separateStems(_:)), "")
                i.representedObject = model
                return i
            }),
            item("Plugins…", #selector(EditorWindowController.showPlugins(_:)), "p", [.command, .option, .shift]),
        ]))
        main.addItem(submenu("Transport", [
            // Space and Return are handled by the timeline, so text fields keep them.
            item("Play", #selector(EditorWindowController.togglePlayback(_:)), "p", [.command, .option]),
            item("Go to Start", #selector(EditorWindowController.goToStart(_:)), ""),
        ]))
        main.addItem(submenu("View", [
            item("Show History", #selector(EditorWindowController.showHistory(_:)), "y", [.command, .option]),
            item("Zoom In", #selector(EditorWindowController.zoomIn(_:)), "+"),
            item("Zoom Out", #selector(EditorWindowController.zoomOut(_:)), "-"),
            item("Zoom to Fit", #selector(EditorWindowController.zoomToFit(_:)), "0"),
            item("Zoom to Selection", #selector(EditorWindowController.zoomToSelection(_:)), "e"),
            .separator(),
            item("Show Spectrogram", #selector(EditorWindowController.toggleSpectrogram(_:)), "s", [.command, .option]),
            item("Show Transcript", #selector(EditorWindowController.toggleTranscript(_:)), "t", [.command, .option]),
            item("Show Assistant", #selector(EditorWindowController.toggleAssistant(_:)), "a", [.command, .option]),
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
