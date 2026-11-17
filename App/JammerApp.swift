#if JAMMER_DEREVERB
import JammerDereverb
#endif
import AppKit
import JammerAgent
import JammerAudio
import JammerCore
import JammerResample
import JammerDenoise
import JammerDiarize
import JammerMP3
import JammerSpeech

/// Operations with preset parameters, for menus and the palette.
enum MenuPresets {
    static var all: [(String, String, [String: JSONValue])] { [
        (L10n.text("audio.fadeIn"), "fade_in", [:]),
        (L10n.text("audio.fadeOut"), "fade_out", [:]),
        (L10n.text("audio.silence"), "silence", [:]),
        (L10n.text("audio.crop"), "crop", [:]),
        (L10n.text("audio.insertSilence"), "insert_silence", ["duration": .number(1)]),
        (L10n.text("audio.gainUp1"), "gain", ["db": .number(1)]),
        (L10n.text("audio.gainDown1"), "gain", ["db": .number(-1)]),
        (L10n.text("audio.gainUp6"), "gain", ["db": .number(6)]),
        (L10n.text("audio.gainDown6"), "gain", ["db": .number(-6)]),
        (L10n.text("audio.normalize16"), "normalize", ["target": .string("loudness"), "level": .number(-16)]),
        (L10n.text("audio.normalize23"), "normalize", ["target": .string("loudness"), "level": .number(-23)]),
        (L10n.text("audio.normalizePeak"), "normalize", ["target": .string("peak"), "level": .number(-1)]),
        (L10n.text("audio.normalizeTruePeak"), "normalize", ["target": .string("true_peak"), "level": .number(-1)]),
    ] }
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
        // Sidechain keys: in every build since 2026-11-17 (Anders's decision), with what hasn't been seen
        // written in the manual (Safe Mode's refusal with an installed plugin). In a release this is about
        // Audio Units, since CLAP and VST 3 are off there.
        Operations.sidechain = true
        #if DEBUG
        // `-registerAudioUnit <path to a .component>`: loads that Audio Unit as a host loads a plugin and
        // registers it in this process only, so a plugin that is not installed on the Mac can be tried in
        // the app (the sidechain test plugin, docs/LICENSES.md "Used in tests only"). Nothing is installed.
        if let path = UserDefaults.standard.string(forKey: "registerAudioUnit") { DebugAudioUnit.register(path) }
        // Automation is in debug builds only until lanes are shown and drawn in the window (docs/MIXER.md):
        // what changes how a project sounds without being seen isn't shipped.
        Operations.automation = true
        // Dialogue-gated loudness: in debug builds only until Anders has measured the test files in a
        // reference meter and the difference is written in the manual.
        Operations.dialogueLoudness = true
        #endif
        NSApp.mainMenu = buildMenu()
        // Our own "open documents" handler: AppKit hands document-based apps' opens straight
        // to the document controller, so this is where the sending app can be seen.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleOpenDocuments(_:reply:)),
                                                     forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenDocuments))
    }

    @objc func showSettings(_ sender: Any?) { SettingsWindow.show() }
    @objc func showLinkedWaiting(_ sender: Any?) { LinkedWaitingWindow.show() }
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
        // Linked documents with changes that were never saved back come back from Jämmer's own journal,
        // whatever the system does with its saved windows (after it has done it).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { LinkJournalStore.recover() }
        #if JAMMER_CLAP
        // CLAP: found by a scan in a helper process, run in helper processes. A build can leave it
        // out (Config/Features.xcconfig), and releases do until it has been tried in a signed build.
        HostedPluginsController.start()
        #endif
        // Tempo and beats: the system's own analysis, on this Mac.
        MusicRhythm.register()
        // The one sample rate converter (exports, batch, imports at another rate).
        Resampler.register()
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
        LinkJournalStore.settle()
        UploadStore.shared.removeAll()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSDocumentController.shared.openDocument(nil) }
        return true
    }

    @objc func showAgentAccess(_ sender: Any?) { AgentSplash.show() }
    @objc func showStorage(_ sender: Any?) { StorageWindow.show() }

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
        let i = NSMenuItem(title: L10n.text("file.sendToFlimmer"), action: #selector(EditorWindowController.sendToFlimmer(_:)), keyEquivalent: "")
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
            item(L10n.text("app.about"), #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item(L10n.text("app.settings"), #selector(AppDelegate.showSettings(_:)), ","),
            .separator(),
            item(L10n.text("app.hide"), #selector(NSApplication.hide(_:)), "h"),
            item(L10n.text("app.hideOthers"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item(L10n.text("app.showAll"), #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            item(L10n.text("app.quit"), #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(submenu(L10n.text("menu.file"), [
            item(L10n.text("file.new"), #selector(NSDocumentController.newDocument(_:)), "n"),
            item(L10n.text("file.open"), #selector(NSDocumentController.openDocument(_:)), "o"),
            .separator(),
            item(L10n.text("file.close"), #selector(NSWindow.performClose(_:)), "w"),
            item(L10n.text("file.save"), #selector(NSDocument.save(_:)), "s"),
            item(L10n.text("file.duplicate"), #selector(NSDocument.duplicate(_:)), "s", [.command, .shift]),
            item(L10n.text("file.revert"), #selector(NSDocument.revertToSaved(_:)), ""),
            item(L10n.text("file.collect"), #selector(JammerDocument.collectAudio(_:)), ""),
            .separator(),
            item(L10n.text("file.importTracks"), #selector(EditorWindowController.importTracks(_:)), "i", [.command, .shift]),
            item(L10n.text("file.importFCPXML"), #selector(AppDelegate.importTimeline(_:)), ""),
            item(L10n.text("file.export"), #selector(EditorWindowController.exportAudio(_:)), "e", [.command, .shift]),
            item(L10n.text("file.batch"), #selector(AppDelegate.showBatch(_:)), "b", [.command, .option]),
            item(L10n.text("file.storage"), #selector(AppDelegate.showStorage(_:)), ""),
            item(L10n.text("menu.file.linkedWaiting"), #selector(AppDelegate.showLinkedWaiting(_:)), ""),
        ] + sendToFlimmerItems))
        main.addItem(submenu(L10n.text("menu.edit"), [
            item(L10n.text("edit.undo"), Selector(("undo:")), "z"),
            item(L10n.text("edit.redo"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(L10n.text("edit.cut"), #selector(TimelineOverlay.cut(_:)), "x"),
            item(L10n.text("edit.copy"), #selector(TimelineOverlay.copy(_:)), "c"),
            item(L10n.text("edit.paste"), #selector(TimelineOverlay.paste(_:)), "v"),
            item(L10n.text("edit.delete"), #selector(TimelineOverlay.delete(_:)), ""),
            item(L10n.text("edit.selectAll"), #selector(TimelineOverlay.selectAll(_:)), "a"),
            .separator(),
            item(L10n.text("edit.palette"), #selector(EditorWindowController.showCommandPalette(_:)), "k"),
        ]))
        main.addItem(submenu(L10n.text("menu.audio"), [
            op(L10n.text("audio.fadeIn"), "fade_in", [:], "i", [.command, .option]),
            op(L10n.text("audio.fadeOut"), "fade_out", [:], "o", [.command, .option]),
            op(L10n.text("audio.silence"), "silence", [:], "l", [.command, .shift]),
            op(L10n.text("audio.crop"), "crop", [:], "t"),
            op(L10n.text("audio.insertSilence"), "insert_silence", ["duration": .number(1)]),
            .separator(),
            op(L10n.text("audio.gainUp1"), "gain", ["db": .number(1)], "]", [.command]),
            op(L10n.text("audio.gainDown1"), "gain", ["db": .number(-1)], "[", [.command]),
            .separator(),
            op(L10n.text("audio.normalize16"), "normalize", ["target": .string("loudness"), "level": .number(-16)]),
            op(L10n.text("audio.normalize23"), "normalize", ["target": .string("loudness"), "level": .number(-23)]),
            op(L10n.text("audio.normalizePeak"), "normalize", ["target": .string("peak"), "level": .number(-1)]),
            op(L10n.text("audio.normalizeTruePeak"), "normalize", ["target": .string("true_peak"), "level": .number(-1)]),
            submenu(L10n.text("audio.loudnessPreset"), LoudnessPreset.allCases.map { op($0.title, "loudness_preset", ["preset": .string($0.rawValue)]) }),
            // The same targets, reached also when the peaks are in the way: the limiter holds them at the preset's ceiling.
            submenu(L10n.text("audio.loudnessPresetLimiter"), LoudnessPreset.allCases.map { op($0.title, "loudness_preset", ["preset": .string($0.rawValue), "limit": .bool(true)]) }),
            submenu(L10n.text("audio.levelSpeakers"), [op(L10n.text("audio.levelSpeakers.static"), "level_speakers"),
                                       op(L10n.text("audio.levelSpeakers.dynamic"), "level_speakers", ["mode": .string("dynamic")])]),
            submenu(L10n.text("audio.debleed"), [op(L10n.text("audio.debleed.gate"), "debleed", ["method": .string("gate")]),
                                     op(L10n.text("audio.debleed.cancel"), "debleed", ["method": .string("cancel")])]),
            item(L10n.text("audio.duck"), #selector(EditorWindowController.duckUnderSpeech(_:))),
            item(L10n.text("audio.limit"), #selector(EditorWindowController.limitPeaks(_:))),
            item(L10n.text("audio.acx"), #selector(EditorWindowController.checkACX(_:))),
            .separator(),
            item(L10n.text("audio.measureLoudness"), #selector(EditorWindowController.analyzeLoudness(_:)), "l", [.command, .option]),
            item(L10n.text("audio.addMarker"), #selector(EditorWindowController.addMarker(_:)), "m", [.command, .option]),
            item(L10n.text("audio.setTempo"), #selector(EditorWindowController.setTempo(_:)), ""),
            op(L10n.text("audio.detectTempo"), "detect_tempo"),
            .separator(),
            restoreItem(L10n.text("audio.dehum"), "dehum"),
            restoreItem(L10n.text("audio.declip"), "declip"),
            restoreItem(L10n.text("audio.declick"), "declick"),
            restoreItem(L10n.text("audio.denoise"), "denoise"),
            restoreItem(L10n.text("audio.dereverb"), "dereverb"),
            item(L10n.text("audio.attenuateFrequencies"), #selector(EditorWindowController.attenuateFrequencies(_:)), ""),
            item(L10n.text("audio.attenuateArea"), #selector(EditorWindowController.attenuateArea(_:)), ""),
            item(L10n.text("audio.healArea"), #selector(EditorWindowController.healArea(_:)), ""),
            item(L10n.text("audio.editSpectrum"), #selector(EditorWindowController.editSpectrumNumerically(_:)), ""),
            .separator(),
            submenu(L10n.text("audio.findSpeakers"), [
                item(L10n.text("audio.findSpeakers.auto"), #selector(EditorWindowController.findSpeakers(_:)), ""),
                .separator(),
            ] + (2...4).map { n in
                let i = item(L10n.count("audio.findSpeakers.count", n), #selector(EditorWindowController.findSpeakers(_:)), "")
                i.representedObject = n
                return i
            }),
            submenu(L10n.text("audio.stems"), ["music4": L10n.text("audio.stems.music"), "dialog": L10n.text("audio.stems.soundtrack")].sorted { $0.key > $1.key }.map { model, title in
                let i = item(title, #selector(EditorWindowController.separateStems(_:)), "")
                i.representedObject = model
                return i
            }),
            item(L10n.text("audio.mixer"), #selector(EditorWindowController.showMixer(_:)), "x", [.command, .option]),
            item(L10n.text("audio.plugins"), #selector(EditorWindowController.showPlugins(_:)), "p", [.command, .option, .shift]),
            item(L10n.text("menu.picture"), #selector(EditorWindowController.showPicture(_:)), ""),
        ]))
        main.addItem(submenu(L10n.text("menu.transport"), [
            // Space and Return are handled by the timeline, so text fields keep them.
            item(L10n.text("transport.play"), #selector(EditorWindowController.togglePlayback(_:)), "p", [.command, .option]),
            item(L10n.text("transport.goToStart"), #selector(EditorWindowController.goToStart(_:)), ""),
        ]))
        // Which lanes the timeline draws. Hidden where automation is (debug builds, until lanes can be drawn by hand too).
        let kinds: [(String?, String)] = [(nil, L10n.text("menu.view.automation.none")), ("gain", L10n.text("menu.view.automation.gain")),
                                          ("pan", L10n.text("menu.view.automation.pan")), ("mute", L10n.text("menu.view.automation.mute")),
                                          ("send", L10n.text("menu.view.automation.send"))]
        let automationMenu = submenu(L10n.text("menu.view.automation"), kinds.map { kind, title in
            let i = item(title, #selector(EditorWindowController.showAutomation(_:)))
            i.representedObject = kind
            return i
        })
        automationMenu.submenu?.addItem(.separator())
        automationMenu.submenu?.addItem(item(L10n.text("menu.view.automation.strips"), #selector(EditorWindowController.toggleStripLanes(_:))))
        automationMenu.isHidden = !Operations.automation
        main.addItem(submenu(L10n.text("menu.view"), [
            item(L10n.text("view.history"), #selector(EditorWindowController.showHistory(_:)), "y", [.command, .option]),
            item(L10n.text("view.zoomIn"), #selector(EditorWindowController.zoomIn(_:)), "+"),
            item(L10n.text("view.zoomOut"), #selector(EditorWindowController.zoomOut(_:)), "-"),
            item(L10n.text("view.zoomToFit"), #selector(EditorWindowController.zoomToFit(_:)), "0"),
            item(L10n.text("view.zoomToSelection"), #selector(EditorWindowController.zoomToSelection(_:)), "e"),
            .separator(),
            item(L10n.text("view.showSpectrogram"), #selector(EditorWindowController.toggleSpectrogram(_:)), "s", [.command, .option]),
            automationMenu,
            item(L10n.text("view.showTranscript"), #selector(EditorWindowController.toggleTranscript(_:)), "t", [.command, .option]),
            item(L10n.text("view.showAssistant"), #selector(EditorWindowController.toggleAssistant(_:)), "a", [.command, .option]),
            .separator(),
            item(L10n.text("view.fullScreen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))
        let window = submenu(L10n.text("menu.window"), [
            item(L10n.text("window.minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            item(L10n.text("window.zoom"), #selector(NSWindow.performZoom(_:)), ""),
            .separator(),
            item(L10n.text("window.bringAllToFront"), #selector(NSApplication.arrangeInFront(_:)), ""),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu
        let help = submenu(L10n.text("menu.help"), [
            item(L10n.text("help.agentAccess"), #selector(showAgentAccess(_:)), "", target: self),
            item(L10n.text("help.agentGuide"), #selector(openAgentGuide(_:)), "", target: self),
            item(L10n.text("help.website"), #selector(openHomepage(_:)), "", target: self),
        ])
        main.addItem(help)
        NSApp.helpMenu = help.submenu
        return main
    }
}

#if DEBUG
import AudioToolbox

enum DebugAudioUnit {
    /// Registers the Audio Unit in the bundle at `path` for this process, from what its Info.plist says it is.
    static func register(_ path: String) {
        let url = URL(fileURLWithPath: path)
        guard let bundle = CFBundleCreate(nil, url as CFURL), CFBundleLoadExecutable(bundle),
              let info = NSDictionary(contentsOf: url.appending(path: "Contents/Info.plist")),
              let c = (info["AudioComponents"] as? [[String: Any]])?.first,
              let type = c["type"] as? String, let subtype = c["subtype"] as? String, let maker = c["manufacturer"] as? String,
              let factoryName = c["factoryFunction"] as? String,
              let pointer = CFBundleGetFunctionPointerForName(bundle, factoryName as CFString) else {
            NSLog("registerAudioUnit: %@ couldn't be loaded as an Audio Unit.", path)
            return
        }
        func code(_ s: String) -> OSType { s.utf8.reduce(0) { $0 << 8 | OSType($1) } }
        var description = AudioComponentDescription(componentType: code(type), componentSubType: code(subtype), componentManufacturer: code(maker),
                                                    componentFlags: 0, componentFlagsMask: 0)
        AudioComponentRegister(&description, (c["name"] as? String ?? "plugin") as CFString, UInt32(c["version"] as? Int ?? 1),
                               unsafeBitCast(pointer, to: AudioComponentFactoryFunction.self))
    }
}
#endif
