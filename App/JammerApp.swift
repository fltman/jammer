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

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        // Jämmer speaks the Mac's language when it is Swedish, and English otherwise (Anders, 2026-11-17: the
        // Swedish is on). `-language en` or `-language sv` decides instead, for test copies and pictures, which
        // must know which language they get: set among the start arguments' own defaults, before anything asks
        // for a text, so that the system's panels follow too; nothing is written to the app's settings.
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        if let chosen = arguments["language"] as? String, ["en", "sv"].contains(chosen) {
            arguments["AppleLanguages"] = [chosen]
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
        #if DEBUG
        // `-printLanguage YES`: says which language the texts come in, and one text, and ends (for the test of the switch).
        if UserDefaults.standard.bool(forKey: "printLanguage") {
            // A sentence from the packages with numbers in it, as the window says it: the numbers in the Mac's region too.
            let area = SpectralShape.box(start: 4.2, end: 4.6, low: 2_000, high: 6_000).summarySaid.keyed
            print("language \(Bundle.main.preferredLocalizations.first ?? "?"): \(L10n.text("menu.picture")) sentence \(L10n.message(area)) number \(L10n.number(0.25, 2))")
            exit(0)
        }
        #endif
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
        // `-asRelease YES`: what a release has, and no more, for the manual's pictures (scripts/site-shots.sh). It
        // leaves off what follows here and the CLAP/VST 3 helpers (HostedPluginsController.available).
        let asRelease = UserDefaults.standard.bool(forKey: "asRelease")
        // Automation is in every build (Anders tried drawing lanes on 2026-11-18: "funkar").
        Operations.automation = true
        // Dialogue-gated loudness: in debug builds only until Anders has measured the test files in a
        // reference meter and the difference is written in the manual.
        Operations.dialogueLoudness = !asRelease
        #endif
        NSApp.mainMenu = CommandCenter.menuBar()
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
        // Updates: release builds only (Updates.enabled).
        Updates.shared.start()
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

    /// Help › Jämmer Help (⌘?): the manual on the site.
    @objc func openManual(_ sender: Any?) {
        if let s = Bundle.main.object(forInfoDictionaryKey: "JammerHomepage") as? String, let url = URL(string: s)?.appending(path: "manual/01-getting-started.html") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openHomepage(_ sender: Any?) {
        if let s = Bundle.main.object(forInfoDictionaryKey: "JammerHomepage") as? String, let url = URL(string: s) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Menus
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
