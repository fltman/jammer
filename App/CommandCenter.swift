import AppKit
import JammerAgent
import JammerCore

/// The window's side of the command registry (`Commands` in JammerAgent): each command's title in the window's
/// language, the action it sends, and the menu bar, context menus and ⌘K rows built from them. A menu item carries
/// its command's id as its identifier, so the window can say whether it is available and, if not, why.
@MainActor
enum CommandCenter {
    static func title(_ c: Command) -> String {
        switch c.title {
        case .key(let k): L10n.text(k)
        case .count(let k, let n): L10n.count(k, n)
        case .loudnessPreset(let p): p.title
        case .layout(let l): L10n.layoutTitle(l)
        }
    }

    /// The menu's own title.
    static func menuTitle(_ m: Command.Menu) -> String {
        switch m {
        case .app: "Jämmer"
        case .file: L10n.text("menu.file")
        case .edit: L10n.text("menu.edit")
        case .view: L10n.text("menu.view")
        case .track: L10n.text("menu.track")
        case .audio: L10n.text("menu.audio")
        case .repair: L10n.text("menu.repair")
        case .speech: L10n.text("menu.speech")
        case .transport: L10n.text("menu.transport")
        case .window: L10n.text("menu.window")
        case .help: L10n.text("menu.help")
        }
    }

    /// The action and, for the app's own commands, the target; nil target: the responder chain (the window).
    static func action(_ c: Command) -> (Selector, AnyObject?) {
        typealias W = EditorWindowController
        let app = NSApp.delegate as AnyObject?
        switch c.id {
        case "app.about": return (#selector(NSApplication.orderFrontStandardAboutPanel(_:)), nil)
        case "app.checkForUpdates": return (#selector(Updates.checkForUpdates(_:)), Updates.shared)
        case "app.settings": return (#selector(AppDelegate.showSettings(_:)), nil)
        case "app.hide": return (#selector(NSApplication.hide(_:)), nil)
        case "app.hideOthers": return (#selector(NSApplication.hideOtherApplications(_:)), nil)
        case "app.showAll": return (#selector(NSApplication.unhideAllApplications(_:)), nil)
        case "app.quit": return (#selector(NSApplication.terminate(_:)), nil)
        case "file.new": return (#selector(NSDocumentController.newDocument(_:)), nil)
        case "file.open": return (#selector(NSDocumentController.openDocument(_:)), nil)
        case "file.close": return (#selector(NSWindow.performClose(_:)), nil)
        case "file.save": return (#selector(NSDocument.save(_:)), nil)
        case "file.saveAs": return (#selector(NSDocument.saveAs(_:)), nil)
        case "file.duplicate": return (#selector(NSDocument.duplicate(_:)), nil)
        case "file.revert": return (#selector(NSDocument.revertToSaved(_:)), nil)
        case "file.importTracks": return (#selector(W.importTracks(_:)), nil)
        case "file.importTimeline": return (#selector(AppDelegate.importTimeline(_:)), nil)
        case "file.export": return (#selector(W.exportAudio(_:)), nil)
        case "file.exportTranscript": return (#selector(W.exportTranscript(_:)), nil)
        case "file.exportTimeline": return (#selector(W.exportTimeline(_:)), nil)
        case "file.sendToFlimmer": return (#selector(W.sendToFlimmer(_:)), nil)
        case "file.collect": return (#selector(JammerDocument.collectAudio(_:)), nil)
        case "file.linkedWaiting": return (#selector(AppDelegate.showLinkedWaiting(_:)), nil)
        case "file.batch": return (#selector(AppDelegate.showBatch(_:)), nil)
        case "file.storage": return (#selector(AppDelegate.showStorage(_:)), nil)
        case "edit.undo": return (Selector(("undo:")), nil)
        case "edit.redo": return (Selector(("redo:")), nil)
        case "edit.cut": return (#selector(TimelineOverlay.cut(_:)), nil)
        case "edit.copy": return (#selector(TimelineOverlay.copy(_:)), nil)
        case "edit.paste": return (#selector(TimelineOverlay.paste(_:)), nil)
        case "edit.delete": return (#selector(TimelineOverlay.delete(_:)), nil)
        case "edit.selectAll": return (#selector(TimelineOverlay.selectAll(_:)), nil)
        case "edit.deselectAll": return (#selector(W.deselectAllCommand(_:)), nil)
        case "edit.split": return (#selector(W.splitAtPlayhead(_:)), nil)
        case "edit.stopJob": return (#selector(W.stopJob(_:)), nil)
        case "view.toolPalette": return (#selector(W.toggleToolPalette(_:)), nil)
        case "edit.findInTranscript": return (#selector(W.findInTranscript(_:)), nil)
        case "edit.findNext": return (#selector(W.findNextInTranscript(_:)), nil)
        case "edit.correctWord": return (#selector(W.correctWord(_:)), nil)
        case "edit.removeFillers": return (#selector(W.removeFillerWords(_:)), nil)
        case "edit.omnibar": return (#selector(W.showCommandPalette(_:)), nil)
        case "view.transcript": return (#selector(W.toggleTranscript(_:)), nil)
        case "view.assistant": return (#selector(W.toggleAssistant(_:)), nil)
        case "view.history": return (#selector(W.showHistory(_:)), nil)
        case "view.spectrogram": return (#selector(W.toggleSpectrogram(_:)), nil)
        case "view.automation.strips": return (#selector(W.toggleStripLanes(_:)), nil)
        case "view.automation.addPoint", "view.automation.previousPoint", "view.automation.nextPoint",
             "view.automation.previousLane", "view.automation.nextLane": return (#selector(W.automationKeyCommand(_:)), nil)
        case "view.zoomIn": return (#selector(W.zoomIn(_:)), nil)
        case "view.zoomOut": return (#selector(W.zoomOut(_:)), nil)
        case "view.zoomToFit": return (#selector(W.zoomToFit(_:)), nil)
        case "view.zoomToSelection": return (#selector(W.zoomToSelection(_:)), nil)
        case "view.tracksTaller": return (#selector(W.tracksTaller(_:)), nil)
        case "view.tracksShorter": return (#selector(W.tracksShorter(_:)), nil)
        case "view.tracksFit": return (#selector(W.tracksFit(_:)), nil)
        case "view.focusMode": return (#selector(W.toggleFocusMode(_:)), nil)
        case "view.fullScreen": return (#selector(NSWindow.toggleFullScreen(_:)), nil)
        case "track.rename": return (#selector(W.renameTrack(_:)), nil)
        case "track.mute": return (#selector(W.toggleTrackMute(_:)), nil)
        case "track.solo": return (#selector(W.toggleTrackSolo(_:)), nil)
        case "track.lock": return (#selector(W.toggleTrackLock(_:)), nil)
        case "track.duplicate": return (#selector(W.duplicateTrack(_:)), nil)
        case "track.moveUp": return (#selector(W.moveTrackUp(_:)), nil)
        case "track.moveDown": return (#selector(W.moveTrackDown(_:)), nil)
        case "track.delete": return (#selector(W.deleteTrack(_:)), nil)
        case "track.mixer": return (#selector(W.showMixer(_:)), nil)
        case "track.plugins": return (#selector(W.showPlugins(_:)), nil)
        case "audio.limit": return (#selector(W.limitPeaks(_:)), nil)
        case "audio.duck": return (#selector(W.duckUnderSpeech(_:)), nil)
        case "audio.measureLoudness": return (#selector(W.analyzeLoudness(_:)), nil)
        case "audio.acx": return (#selector(W.checkACX(_:)), nil)
        case "audio.matchACX": return (#selector(W.matchACX(_:)), nil)
        case "repair.attenuateFrequencies": return (#selector(W.attenuateFrequencies(_:)), nil)
        case "repair.attenuateArea": return (#selector(W.attenuateArea(_:)), nil)
        case "repair.healArea": return (#selector(W.healArea(_:)), nil)
        case "repair.editSpectrum": return (#selector(W.editSpectrumNumerically(_:)), nil)
        case "speech.transcribe": return (#selector(W.transcribeCommand(_:)), nil)
        case "speech.transcribeVoiceTracks": return (#selector(W.transcribeVoiceTracks(_:)), nil)
        case "speech.splitSpeakers": return (#selector(W.splitSpeakers(_:)), nil)
        case "speech.splitAndTranscribe": return (#selector(W.splitAndTranscribeSpeakers(_:)), nil)
        case "speech.saveVoiceProfile": return (#selector(W.saveVoiceProfile(_:)), nil)
        case "speech.cloneVoice": return (#selector(W.cloneVoice(_:)), nil)
        case "speech.overdub": return (#selector(W.overdubSelection(_:)), nil)
        case "speech.deleteVoice": return (#selector(W.deleteClonedVoice(_:)), nil)
        case "transport.play": return (#selector(W.togglePlayback(_:)), nil)
        case "transport.goToStart": return (#selector(W.goToStart(_:)), nil)
        case "transport.goToEnd": return (#selector(W.goToEnd(_:)), nil)
        case "transport.previousMarker": return (#selector(W.previousMarker(_:)), nil)
        case "transport.nextMarker": return (#selector(W.nextMarker(_:)), nil)
        case "transport.addMarker": return (#selector(W.addMarker(_:)), nil)
        case "transport.record": return (#selector(W.toggleRecording(_:)), nil)
        case "track.arm": return (#selector(W.toggleArm(_:)), nil)
        case "transport.renameMarker": return (#selector(W.renameMarker(_:)), nil)
        case "transport.deleteMarker": return (#selector(W.deleteMarker(_:)), nil)
        case "transport.setTempo": return (#selector(W.setTempo(_:)), nil)
        case "transport.binaural": return (#selector(W.toggleBinaural(_:)), nil)
        case "transport.followHead": return (#selector(W.toggleFollowHead(_:)), nil)
        case "transport.centerHead": return (#selector(W.recenterHead(_:)), nil)
        case "window.minimize": return (#selector(NSWindow.performMiniaturize(_:)), nil)
        case "window.zoom": return (#selector(NSWindow.performZoom(_:)), nil)
        case "window.picture": return (#selector(W.showPicture(_:)), nil)
        case "window.bringAllToFront": return (#selector(NSApplication.arrangeInFront(_:)), nil)
        case "help.manual": return (#selector(AppDelegate.openManual(_:)), app)
        case "help.agentAccess": return (#selector(AppDelegate.showAgentAccess(_:)), app)
        case "help.agentGuide": return (#selector(AppDelegate.openAgentGuide(_:)), app)
        case "help.website": return (#selector(AppDelegate.openHomepage(_:)), app)
        default: break
        }
        if c.payload["op"] != nil { return (#selector(W.performOperation(_:)), nil) }
        if c.id.hasPrefix("view.tool.") { return (#selector(W.chooseToolCommand(_:)), nil) }
        if c.id.hasPrefix("view.automation.") { return (#selector(W.showAutomation(_:)), nil) }
        if c.id.hasPrefix("track.layout.") { return (#selector(W.performOperation(_:)), nil) }
        if c.id.hasPrefix("audio.stems.") { return (#selector(W.separateStems(_:)), nil) }
        if c.id.hasPrefix("repair.") { return (#selector(W.showRestore(_:)), nil) }
        if c.id.hasPrefix("speech.findSpeakers.") { return (#selector(W.findSpeakers(_:)), nil) }
        if c.id == "transport.detectTempo" { return (#selector(W.performOperation(_:)), nil) }
        preconditionFailure("command \(c.id) has no action")
    }

    /// What the action reads from its sender: the operation and its parameters, a kind, a model or a count.
    static func object(_ c: Command) -> Any? {
        var p = c.payload
        if let op = p.removeValue(forKey: "op")?.string { return OperationItem(op, p) }
        if c.id.hasPrefix("track.layout.") { return OperationItem("set_layout", p) }
        if let kind = p["kind"]?.string { return c.id.hasPrefix("view.automation.") && kind == "none" ? nil : kind }
        if let model = p["model"]?.string { return model }
        if let n = p["count"]?.double { return Int(n) }
        if let tool = p["tool"]?.string { return tool }
        return nil
    }

    static func item(_ c: Command, inContext: Bool = false) -> NSMenuItem {
        let (action, target) = action(c)
        let i = NSMenuItem(title: title(c), action: action, keyEquivalent: inContext ? "" : c.key)
        if !inContext {
            var mods: NSEvent.ModifierFlags = []
            if c.modifiers.contains(.command) { mods.insert(.command) }
            if c.modifiers.contains(.option) { mods.insert(.option) }
            if c.modifiers.contains(.shift) { mods.insert(.shift) }
            if c.modifiers.contains(.control) { mods.insert(.control) }
            i.keyEquivalentModifierMask = mods
        }
        i.target = target
        i.representedObject = object(c)
        i.identifier = NSUserInterfaceItemIdentifier(c.id)
        if c.id == "repair.dereverb" { i.isHidden = Restoration.dereverber == nil }
        return i
    }

    /// Commands grouped as they stand: sections, and inside them submenus in the order they first appear.
    private static func entries(_ commands: [Command], inContext: Bool) -> [NSMenuItem] {
        var out: [NSMenuItem] = []
        var section: Int?
        var submenus: [String: NSMenu] = [:]
        for c in commands {
            if let s = section, s != c.section { out.append(.separator()) }
            section = c.section
            if let sub = c.submenu {
                if let m = submenus[sub] { m.addItem(item(c, inContext: inContext)); continue }
                let m = NSMenu(title: L10n.text(sub))
                m.addItem(item(c, inContext: inContext))
                submenus[sub] = m
                let holder = NSMenuItem(title: L10n.text(sub), action: nil, keyEquivalent: "")
                holder.submenu = m
                if sub == "menu.view.automation" { holder.isHidden = !Operations.automation }
                out.append(holder)
            } else {
                out.append(item(c, inContext: inContext))
            }
        }
        return out
    }

    static func menuBar() -> NSMenu {
        let main = NSMenu()
        let all = Commands.all
        for m in Command.Menu.allCases {
            let menu = NSMenu(title: menuTitle(m))
            entries(all.filter { $0.menu == m }, inContext: false).forEach(menu.addItem)
            let holder = NSMenuItem(title: menuTitle(m), action: nil, keyEquivalent: "")
            holder.submenu = menu
            main.addItem(holder)
            if m == .window { NSApp.windowsMenu = menu }
            if m == .help { NSApp.helpMenu = menu }
        }
        return main
    }

    /// A context menu: the commands offered for that kind of thing, with the menu bar's names and the same checks
    /// (the window validates them by id), without the menu bar's shortcuts.
    static func contextMenu(_ context: Command.Context) -> NSMenu {
        let menu = NSMenu()
        entries(Commands.all.filter { $0.contexts.contains(context) }, inContext: true).forEach(menu.addItem)
        return menu
    }
}
