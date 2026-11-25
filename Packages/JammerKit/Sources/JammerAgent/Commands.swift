import Foundation
import JammerCore

/// Every command a user can give in the window, in one registry (the comfort block, 2026-11-25): the menu bar,
/// the context menus, ⌘K and the tool palette are built from it, so a name, a shortcut or the reason a command
/// is off can't differ between them. Each command says what the agent does for the same thing: an operation, a
/// route, or why there is none (a test fails a command without one of the three).
public struct Command: Sendable, Identifiable {
    public enum Menu: String, CaseIterable, Sendable { case app, file, edit, view, track, audio, repair, speech, transport, window, help }

    /// Where else the command is offered: the context menus of these things.
    public enum Context: String, CaseIterable, Sendable { case timeline, clip, track, marker, word, area, strip }

    public enum Modifier: String, CaseIterable, Sendable, Comparable {
        case control, option, shift, command
        public static func < (a: Modifier, b: Modifier) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
    }

    /// How the title is made; the window says it in its language.
    public enum Title: Sendable, Equatable {
        case key(String)
        case count(String, Int)
        case loudnessPreset(LoudnessPreset)
        case layout(ChannelLayout)
    }

    /// Why a command has no agent counterpart. Only these reasons are accepted.
    public enum Exemption: String, CaseIterable, Sendable {
        /// macOS's own (hide, quit, minimize, full screen): not Jämmer's to offer.
        case system
        /// What the window shows (panels, zoom, lanes, the spectrogram): view state, never part of the document.
        case view
        /// A window or sheet whose content the API already gives in its own call (the mixer, the history, storage).
        case window
        /// Consent and payment are the user's own answer, in the window (SIBLINGS).
        case consent
        /// The listener's own headphones and head: this Mac's listening, not the document.
        case listening
        /// A file panel or the user's own unsaved work.
        case userFiles
        /// The omnibar and the assistant: the agent's own counterpart is the API itself.
        case assistant
    }

    public enum Agent: Sendable, Equatable {
        case operation(String)
        case route(String, String)
        case none(Exemption)
    }

    public var id: String
    public var menu: Menu
    /// The submenu's title key, when the command sits in one.
    public var submenu: String?
    /// Commands with the same menu and section stand together; a separator stands between sections.
    public var section: Int
    public var title: Title
    public var key: String = ""
    public var modifiers: Set<Modifier> = []
    public var agent: Agent
    public var contexts: Set<Context> = []
    /// What the window passes with it (an operation's parameters, a model, a count).
    public var payload: [String: JSONValue] = [:]
    /// Offered in ⌘K (a submenu's items are, each by its own title).
    public var inPalette = true

    public var shortcut: String {
        guard !key.isEmpty else { return "" }
        let marks: [Modifier: String] = [.control: "⌃", .option: "⌥", .shift: "⇧", .command: "⌘"]
        return modifiers.sorted().map { marks[$0]! }.joined() + key.uppercased()
    }
}

public enum Commands {
    typealias C = Command

    /// Every command, in menu order (made once; titles are said by the window when shown).
    public static let all: [Command] = make()

    private static let byID: [String: Command] = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    private static func make() -> [Command] {
        var out: [Command] = []
        func add(_ id: String, _ menu: C.Menu, _ section: Int, _ title: C.Title, key: String = "", _ mods: Set<C.Modifier> = [], agent: C.Agent,
                 submenu: String? = nil, contexts: Set<C.Context> = [], payload: [String: JSONValue] = [:], palette: Bool = true) {
            out.append(Command(id: id, menu: menu, submenu: submenu, section: section, title: title, key: key, modifiers: key.isEmpty ? [] : mods.union([.command]),
                               agent: agent, contexts: contexts, payload: payload, inPalette: palette))
        }
        func key(_ k: String) -> C.Title { .key(k) }
        let op = C.Agent.operation
        let doc = "/api/v1/documents/{id}"

        // Jämmer
        add("app.about", .app, 0, key("app.about"), agent: .none(.system), palette: false)
        add("app.checkForUpdates", .app, 0, key("app.checkForUpdates"), agent: .none(.system))
        add("app.settings", .app, 1, key("app.settings"), key: ",", agent: .route("POST", "/api/v1/settings/open"))
        add("app.hide", .app, 2, key("app.hide"), key: "h", agent: .none(.system), palette: false)
        add("app.hideOthers", .app, 2, key("app.hideOthers"), key: "h", [.option], agent: .none(.system), palette: false)
        add("app.showAll", .app, 2, key("app.showAll"), agent: .none(.system), palette: false)
        add("app.quit", .app, 3, key("app.quit"), key: "q", agent: .none(.system), palette: false)

        // File
        add("file.new", .file, 0, key("file.new"), key: "n", agent: .route("POST", "/api/v1/documents"))
        add("file.open", .file, 0, key("file.open"), key: "o", agent: .route("POST", "/api/v1/documents"))
        add("file.close", .file, 1, key("file.close"), key: "w", agent: .route("DELETE", doc))
        add("file.save", .file, 1, key("file.save"), key: "s", agent: .route("POST", doc + "/save"))
        add("file.saveAs", .file, 1, key("file.saveAs"), key: "s", [.shift], agent: .none(.userFiles))
        add("file.duplicate", .file, 1, key("file.duplicate"), key: "s", [.option, .shift], agent: .none(.userFiles))
        add("file.revert", .file, 1, key("file.revert"), agent: .none(.userFiles))
        add("file.importTracks", .file, 2, key("file.importTracks"), key: "i", [.shift], agent: .route("POST", doc + "/tracks"))
        add("file.importTimeline", .file, 2, key("file.importTimeline"), agent: .operation("import_timeline"))
        add("file.export", .file, 3, key("file.export"), key: "e", [.shift], agent: .operation("export"))
        add("file.exportTranscript", .file, 3, key("file.exportTranscript"), agent: .operation("export_transcript"))
        add("file.exportTimeline", .file, 3, key("file.exportTimeline"), agent: .operation("export_timeline"))
        add("file.sendToFlimmer", .file, 4, key("file.sendToFlimmer"), agent: .none(.window))
        add("file.collect", .file, 5, key("file.collect"), agent: .none(.userFiles))
        add("file.linkedWaiting", .file, 5, key("menu.file.linkedWaiting"), agent: .none(.userFiles))
        add("file.batch", .file, 5, key("file.batch"), key: "b", [.option], agent: .operation("batch"))
        add("file.storage", .file, 5, key("file.storage"), agent: .route("GET", "/api/v1/storage"))

        // Edit
        add("edit.undo", .edit, 0, key("edit.undo"), key: "z", agent: .route("POST", doc + "/undo"), palette: false)
        add("edit.redo", .edit, 0, key("edit.redo"), key: "z", [.shift], agent: .route("POST", doc + "/redo"), palette: false)
        add("edit.cut", .edit, 1, key("edit.cut"), key: "x", agent: op("cut"), contexts: [.timeline, .clip, .word])
        add("edit.copy", .edit, 1, key("edit.copy"), key: "c", agent: op("copy"), contexts: [.timeline, .clip, .word])
        add("edit.paste", .edit, 1, key("edit.paste"), key: "v", agent: op("paste"), contexts: [.timeline])
        add("edit.delete", .edit, 1, key("edit.delete"), agent: op("delete"), contexts: [.timeline, .clip, .word])
        add("edit.selectAll", .edit, 1, key("edit.selectAll"), key: "a", agent: op("select_all"))
        add("edit.split", .edit, 1, key("edit.split"), key: "b", agent: op("split"), contexts: [.timeline, .clip])
        add("edit.deselectAll", .edit, 1, key("edit.deselectAll"), key: "a", [.shift], agent: op("deselect"), contexts: [.timeline])
        add("edit.findInTranscript", .edit, 2, key("edit.findInTranscript"), key: "f", agent: .route("GET", doc + "/transcript"))
        add("edit.findNext", .edit, 2, key("edit.findNext"), key: "g", agent: .route("GET", doc + "/transcript"), palette: false)
        add("edit.correctWord", .edit, 3, key("edit.correctWord"), agent: op("correct_word"), contexts: [.word])
        add("edit.removeFillers", .edit, 3, key("edit.removeFillers"), agent: op("delete_words"), contexts: [.word])
        add("edit.omnibar", .edit, 4, key("edit.palette"), key: "k", agent: .none(.assistant), palette: false)

        // View
        add("view.transcript", .view, 0, key("view.showTranscript"), key: "t", [.option], agent: .none(.view))
        add("view.assistant", .view, 0, key("view.showAssistant"), key: "a", [.option], agent: .none(.assistant))
        add("view.history", .view, 0, key("view.history"), key: "y", [.option], agent: .route("GET", doc + "/history"))
        add("view.toolPalette", .view, 0, key("view.toolPalette"), agent: .none(.view))
        add("view.spectrogram", .view, 1, key("view.showSpectrogram"), key: "s", [.option], agent: .none(.view))
        // The tools (the palette's): the single letter works while the timeline has the keys. A tool is how the
        // window answers the mouse, never part of the document.
        for t in Commands.tools {
            add("view.tool." + t.id, .view, 1, key(t.title), agent: .none(.view), submenu: "view.tool", payload: ["tool": .string(t.id), "letter": .string(t.letter)])
        }
        for (kind, title) in [("none", "menu.view.automation.none"), ("gain", "menu.view.automation.gain"), ("pan", "menu.view.automation.pan"),
                              ("mute", "menu.view.automation.mute"), ("send", "menu.view.automation.send"), ("azimuth", "menu.view.automation.azimuth"),
                              ("elevation", "menu.view.automation.elevation"), ("yaw", "menu.view.automation.yaw"), ("pitch", "menu.view.automation.pitch"),
                              ("roll", "menu.view.automation.roll"), ("plugin", "menu.view.automation.plugin")] {
            add("view.automation." + kind, .view, 1, key(title), agent: .none(.view), submenu: "menu.view.automation", payload: ["kind": .string(kind)])
        }
        add("view.automation.strips", .view, 1, key("menu.view.automation.strips"), agent: .none(.view), submenu: "menu.view.automation")
        add("view.zoomIn", .view, 2, key("view.zoomIn"), key: "+", agent: .none(.view))
        add("view.zoomOut", .view, 2, key("view.zoomOut"), key: "-", agent: .none(.view))
        add("view.zoomToFit", .view, 2, key("view.zoomToFit"), key: "0", agent: .none(.view))
        add("view.zoomToSelection", .view, 2, key("view.zoomToSelection"), key: "e", [.option], agent: .none(.view), contexts: [.timeline])
        add("view.focusMode", .view, 3, key("view.focusMode"), key: "f", [.control, .shift], agent: .none(.view))
        add("view.fullScreen", .view, 3, key("view.fullScreen"), key: "f", [.control], agent: .none(.system))

        // Track
        add("track.rename", .track, 0, key("track.rename"), agent: op("set_track"), contexts: [.track, .strip])
        add("track.mute", .track, 1, key("track.mute"), agent: op("set_track"), contexts: [.track, .strip])
        add("track.solo", .track, 1, key("track.solo"), agent: .route("POST", doc + "/solo"), contexts: [.track, .strip])
        for l in ChannelLayout.allCases {
            add("track.layout.\(l.rawValue)", .track, 2, .layout(l), agent: op("set_layout"), submenu: "menu.layout", payload: ["layout": .string(l.rawValue)])
        }
        for (o, title) in [(ChannelOrder.bs2051, "menu.layout.order.bs2051"), (.wav, "menu.layout.order.wav")] {
            add("track.layout.order." + o.rawValue, .track, 2, key(title), agent: op("set_layout"), submenu: "menu.layout", payload: ["order": .string(o.rawValue)])
        }
        add("track.mixer", .track, 3, key("audio.mixer"), key: "x", [.option], agent: .route("GET", doc + "/mixer"), contexts: [.strip])
        add("track.plugins", .track, 3, key("audio.plugins"), key: "p", [.option, .shift], agent: op("add_insert"), contexts: [.track, .strip])

        // Audio (editing the sound and its loudness)
        add("audio.fadeIn", .audio, 0, key("audio.fadeIn"), key: "i", [.option], agent: op("fade_in"), contexts: [.timeline, .clip], payload: ["op": .string("fade_in")])
        add("audio.fadeOut", .audio, 0, key("audio.fadeOut"), key: "o", [.option], agent: op("fade_out"), contexts: [.timeline, .clip], payload: ["op": .string("fade_out")])
        add("audio.silence", .audio, 0, key("audio.silence"), key: "l", [.shift], agent: op("silence"), contexts: [.timeline], payload: ["op": .string("silence")])
        add("audio.crop", .audio, 0, key("audio.crop"), key: "t", agent: op("crop"), contexts: [.timeline], payload: ["op": .string("crop")])
        add("audio.insertSilence", .audio, 0, key("audio.insertSilence"), agent: op("insert_silence"), payload: ["op": .string("insert_silence"), "duration": .number(1)])
        add("audio.gainUp1", .audio, 1, key("audio.gainUp1"), key: "]", agent: op("gain"), contexts: [.timeline, .clip], payload: ["op": .string("gain"), "db": .number(1)])
        add("audio.gainDown1", .audio, 1, key("audio.gainDown1"), key: "[", agent: op("gain"), contexts: [.timeline, .clip], payload: ["op": .string("gain"), "db": .number(-1)])
        add("audio.normalize16", .audio, 2, key("audio.normalize16"), agent: op("normalize"), payload: ["op": .string("normalize"), "target": .string("loudness"), "level": .number(-16)])
        add("audio.normalize23", .audio, 2, key("audio.normalize23"), agent: op("normalize"), payload: ["op": .string("normalize"), "target": .string("loudness"), "level": .number(-23)])
        add("audio.normalizePeak", .audio, 2, key("audio.normalizePeak"), agent: op("normalize"), payload: ["op": .string("normalize"), "target": .string("peak"), "level": .number(-1)])
        add("audio.normalizeTruePeak", .audio, 2, key("audio.normalizeTruePeak"), agent: op("normalize"), payload: ["op": .string("normalize"), "target": .string("true_peak"), "level": .number(-1)])
        for p in LoudnessPreset.allCases {
            add("audio.loudnessPreset.\(p.rawValue)", .audio, 2, .loudnessPreset(p), agent: op("loudness_preset"), submenu: "audio.loudnessPreset",
                payload: ["op": .string("loudness_preset"), "preset": .string(p.rawValue)])
        }
        for p in LoudnessPreset.allCases {
            add("audio.loudnessPresetLimiter.\(p.rawValue)", .audio, 2, .loudnessPreset(p), agent: op("loudness_preset"), submenu: "audio.loudnessPresetLimiter",
                payload: ["op": .string("loudness_preset"), "preset": .string(p.rawValue), "limit": .bool(true)])
        }
        add("audio.limit", .audio, 2, key("audio.limit"), agent: op("limit"))
        add("audio.duck", .audio, 2, key("audio.duck"), agent: op("duck"))
        add("audio.levelSpeakers.static", .audio, 2, key("audio.levelSpeakers.static"), agent: op("level_speakers"), submenu: "audio.levelSpeakers", payload: ["op": .string("level_speakers")])
        add("audio.levelSpeakers.dynamic", .audio, 2, key("audio.levelSpeakers.dynamic"), agent: op("level_speakers"), submenu: "audio.levelSpeakers",
            payload: ["op": .string("level_speakers"), "mode": .string("dynamic")])
        add("audio.measureLoudness", .audio, 3, key("audio.measureLoudness"), key: "l", [.option], agent: op("measure_loudness"))
        add("audio.acx", .audio, 3, key("audio.acx"), agent: .route("GET", doc + "/analysis/acx"))
        add("audio.stems.music4", .audio, 4, key("audio.stems.music"), agent: op("separate"), submenu: "audio.stems", payload: ["model": .string("music4")])
        add("audio.stems.dialog", .audio, 4, key("audio.stems.soundtrack"), agent: op("separate"), submenu: "audio.stems", payload: ["model": .string("dialog")])

        // Repair
        for (kind, k) in [("dehum", "audio.dehum"), ("declip", "audio.declip"), ("declick", "audio.declick"), ("denoise", "audio.denoise"), ("dereverb", "audio.dereverb")] {
            add("repair.\(kind)", .repair, 0, key(k), agent: op("restore"), payload: ["kind": .string(kind)])
        }
        add("repair.debleed.gate", .repair, 0, key("audio.debleed.gate"), agent: op("debleed"), submenu: "audio.debleed", payload: ["op": .string("debleed"), "method": .string("gate")])
        add("repair.debleed.cancel", .repair, 0, key("audio.debleed.cancel"), agent: op("debleed"), submenu: "audio.debleed", payload: ["op": .string("debleed"), "method": .string("cancel")])
        add("repair.attenuateFrequencies", .repair, 1, key("audio.attenuateFrequencies"), agent: op("spectral_attenuate"), contexts: [.timeline])
        add("repair.attenuateArea", .repair, 1, key("audio.attenuateArea"), agent: op("spectral_edit"), contexts: [.area])
        add("repair.healArea", .repair, 1, key("audio.healArea"), agent: op("spectral_edit"), contexts: [.area])
        add("repair.editSpectrum", .repair, 1, key("audio.editSpectrum"), agent: op("spectral_edit"))

        // Speech
        add("speech.transcribe", .speech, 0, key("speech.transcribe"), agent: op("transcribe"))
        add("speech.transcribeVoiceTracks", .speech, 0, key("op.transcribe_voice_tracks.title"), agent: op("transcribe_voice_tracks"))
        add("speech.findSpeakers.auto", .speech, 1, key("audio.findSpeakers.auto"), agent: op("diarize"), submenu: "audio.findSpeakers")
        for n in 2...4 {
            add("speech.findSpeakers.\(n)", .speech, 1, .count("audio.findSpeakers.count", n), agent: op("diarize"), submenu: "audio.findSpeakers", payload: ["count": .number(Double(n))])
        }
        add("speech.splitSpeakers", .speech, 1, key("op.split_speakers.title"), agent: op("split_speakers"), contexts: [.track])
        add("speech.splitAndTranscribe", .speech, 1, key("voiceTranscribe.split"), agent: op("transcribe_voice_tracks"), contexts: [.track])
        add("speech.saveVoiceProfile", .speech, 1, key("voiceProfiles.menu.save"), agent: op("request_voice_profile"))
        add("speech.cloneVoice", .speech, 2, key("menu.overdub.clone"), agent: op("clone_voice"))
        add("speech.overdub", .speech, 2, key("menu.overdub"), agent: op("overdub"), contexts: [.word])
        add("speech.deleteVoice", .speech, 2, key("menu.overdub.delete"), agent: op("delete_voice"))

        // Transport
        add("transport.play", .transport, 0, key("transport.play"), key: "p", [.option], agent: .route("POST", doc + "/play"))
        add("transport.goToStart", .transport, 0, key("transport.goToStart"), agent: op("set_playhead"))
        add("transport.goToEnd", .transport, 0, key("transport.goToEnd"), agent: op("set_playhead"))
        add("transport.previousMarker", .transport, 1, key("transport.previousMarker"), agent: op("set_playhead"))
        add("transport.nextMarker", .transport, 1, key("transport.nextMarker"), agent: op("set_playhead"))
        add("transport.addMarker", .transport, 1, key("audio.addMarker"), key: "m", [.shift], agent: op("add_marker"), contexts: [.timeline])
        add("transport.setTempo", .transport, 2, key("audio.setTempo"), agent: op("set_tempo"))
        add("transport.detectTempo", .transport, 2, key("audio.detectTempo"), agent: op("detect_tempo"), payload: ["op": .string("detect_tempo")])
        add("transport.binaural", .transport, 3, key("menu.listen.binaural"), agent: .none(.listening))
        add("transport.followHead", .transport, 3, key("menu.listen.followHead"), agent: .none(.listening))
        add("transport.centerHead", .transport, 3, key("menu.listen.recenterHead"), agent: .none(.listening))

        // Window
        add("window.minimize", .window, 0, key("window.minimize"), key: "m", agent: .none(.system), palette: false)
        add("window.zoom", .window, 0, key("window.zoom"), agent: .none(.system), palette: false)
        add("window.picture", .window, 1, key("menu.picture"), agent: op("set_video_reference"))
        add("window.bringAllToFront", .window, 2, key("window.bringAllToFront"), agent: .none(.system), palette: false)

        // Help
        add("help.manual", .help, 0, key("help.manual"), key: "?", agent: .route("GET", "/jammer"))
        add("help.agentAccess", .help, 0, key("help.agentAccess"), agent: .route("GET", "/jammer"))
        add("help.agentGuide", .help, 0, key("help.agentGuide"), agent: .route("GET", "/jammer"))
        add("help.website", .help, 0, key("help.website"), agent: .route("GET", "/jammer"))
        return out
    }

    public static func command(_ id: String) -> Command? { byID[id] }

    /// The tool palette's tools, in its order, with the letter that picks each and its symbol (Anders chose all of
    /// them, 2026-11-25; Glimmer's pattern).
    public struct Tool: Sendable { public let id: String, letter: String, title: String, symbol: String, spectral: Bool }
    public static let tools: [Tool] = [
        Tool(id: "select", letter: "a", title: "tool.select", symbol: "cursorarrow", spectral: false),
        Tool(id: "split", letter: "s", title: "tool.split", symbol: "scissors", spectral: false),
        Tool(id: "trim", letter: "t", title: "tool.trim", symbol: "arrow.left.and.right", spectral: false),
        Tool(id: "fade", letter: "f", title: "tool.fade", symbol: "line.diagonal", spectral: false),
        Tool(id: "gain", letter: "g", title: "tool.gain", symbol: "speaker.wave.2", spectral: false),
        Tool(id: "box", letter: "b", title: "view.spectralTool.box", symbol: "rectangle.dashed", spectral: true),
        Tool(id: "lasso", letter: "l", title: "view.spectralTool.lasso", symbol: "lasso", spectral: true),
        Tool(id: "brush", letter: "p", title: "view.spectralTool.brush", symbol: "paintbrush.pointed", spectral: true),
        Tool(id: "zoom", letter: "z", title: "tool.zoom", symbol: "plus.magnifyingglass", spectral: false),
        Tool(id: "hand", letter: "h", title: "tool.hand", symbol: "hand.raised", spectral: false),
    ]

    /// Shortcuts macOS keeps for itself, and the one command each may belong to (nil: none of Jämmer's).
    /// "⌃⌘F is Full Screen, ⌘H Hide, ⌘M Minimize" (SIBLINGS, comfort list).
    public static let reserved: [String: String?] = [
        "⌘H": "app.hide", "⌥⌘H": "app.hideOthers", "⌘M": "window.minimize", "⌥⌘M": nil, "⌘Q": "app.quit", "⌥⌘Q": nil,
        "⌘W": "file.close", "⌥⌘W": nil, "⌃⌘F": "view.fullScreen", "⌘,": "app.settings", "⌘?": "help.manual",
        "⌘`": nil, "⌘ ": nil, "⌃⌘Q": nil, "⌃⌘ ": nil, "⌥⌘D": nil, "⌥⌘ ": nil, "⇧⌘3": nil, "⇧⌘4": nil, "⇧⌘5": nil,
        "⌘E": nil, "⌘F": "edit.findInTranscript", "⌘G": "edit.findNext", "⌘P": nil, "⌘.": nil, "⌘Z": "edit.undo", "⇧⌘Z": "edit.redo",
        "⌘X": "edit.cut", "⌘C": "edit.copy", "⌘V": "edit.paste", "⌘A": "edit.selectAll", "⌘N": "file.new", "⌘O": "file.open", "⌘S": "file.save",
        "⇧⌘S": "file.saveAs", "⇧⌘A": "edit.deselectAll",
    ]
}
