import Foundation
import Testing
@testable import JammerAgent
import JammerCore

/// The command registry (the comfort block, 2026-11-25): one list for the menu bar, the context menus, ⌘K and the
/// tool palette, and what the agent does for each command.
@Suite("Command registry")
struct CommandRegistryTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    @Test("Every command and window control has an agent counterpart: an operation in the registry, a route the API has, an accepted reason, or a known gap")
    func agentCoverage() {
        let ops = Set((Operations.all + Operations.endpoints).map(\.name))
        let routes = AgentAPI.routes
        let everything = Commands.all.map { ($0.id, $0.agent) } + WindowControls.all.map { ($0.id, $0.agent) }
        var gaps: Set<String> = []
        for (id, agent) in everything {
            switch agent {
            case .operation(let name):
                #expect(ops.contains(name), "\(id): no operation \(name)")
            case .route(let method, let path):
                let pattern = AgentAPI.RouteParameters(method, path).pattern
                #expect(routes.contains { $0.method == method && $0.pattern == pattern }, "\(id): no route \(method) \(path)")
            case .none(let why):
                #expect(Command.Exemption.allCases.contains(why), "\(id)")
            case .gap(let missing):
                #expect(!missing.isEmpty, "\(id): a gap says what is missing")
                gaps.insert(id)
            }
        }
        // The known gaps are exactly the gaps, and the list only shrinks (SIBLINGS, "Agenten når allt som fönstret gör").
        #expect(gaps == Commands.knownGaps, "gaps \(gaps.sorted()) against knownGaps \(Commands.knownGaps.sorted())")
        #expect(Commands.knownGaps.count <= 0, "knownGaps may only shrink")
        // Exemptions closed (the coordinator, 2026-11-28): each is a route now, and stays one.
        #expect(Commands.command("file.duplicate")?.agent == .route("POST", "/api/v1/documents/{id}/duplicate"))
        // Consent and payment are answered by the user; nothing else may claim it.
        #expect(Commands.all.filter { $0.agent == .none(.consent) }.allSatisfy { ["speech.cloneVoice", "speech.overdub"].contains($0.id) })
    }

    @Test("Ids are unique; a shortcut belongs to one command; a key macOS keeps for itself belongs only to its own command")
    func shortcuts() {
        let ids = Commands.all.map(\.id)
        #expect(Set(ids).count == ids.count, "\(Dictionary(grouping: ids) { $0 }.filter { $0.value.count > 1 }.keys)")
        let withKeys = Commands.all.filter { !$0.shortcut.isEmpty }
        let byShortcut = Dictionary(grouping: withKeys, by: \.shortcut)
        for (s, cs) in byShortcut { #expect(cs.count == 1, "\(s): \(cs.map(\.id))") }
        for c in withKeys {
            if let owner = Commands.reserved[c.shortcut] {
                #expect(owner == c.id, "\(c.shortcut) is macOS's (\(owner ?? "kept by the system")), not \(c.id)'s")
            }
        }
        // The clashes the sweep found are gone.
        #expect(Commands.command("transport.addMarker")?.shortcut != "⌥⌘M" && Commands.command("view.zoomToSelection")?.shortcut != "⌘E")
        #expect(Commands.command("view.fullScreen")?.shortcut == "⌃⌘F")
    }

    @Test("No menu takes a key a view keeps (Space, Return, Esc, Tab, ⌫, Home, End, the arrows) but the named exceptions, and macOS's find and Dock keys stay free")
    func viewKeys() {
        let onViewKeys = Commands.all.filter { c in Commands.viewKeys.contains { $0.key == c.key && $0.modifiers == c.modifiers } }
        #expect(Set(onViewKeys.map(\.id)) == Set(Commands.viewKeyMenus.keys),
                "on a view's key: \(onViewKeys.map { "\($0.id) \($0.shortcut)" }); named: \(Commands.viewKeyMenus.keys.sorted())")
        for (id, why) in Commands.viewKeyMenus { #expect(!why.isEmpty, "\(id) says why the view keeps its key") }
        // Flimmer's K2a: Find Next/Previous, Use Selection for Find, Jump to Selection, the Dock.
        for key in ["⌘G", "⇧⌘G", "⌘E", "⌘J", "⌥⌘D"] {
            #expect(Commands.reserved.keys.contains(key), "\(key) is macOS's")
            if let c = Commands.all.first(where: { $0.shortcut == key }) { #expect(Commands.reserved[key] == c.id, "\(key) belongs to \(c.id)") }
        }
    }

    @Test("The menus follow Apple's order, the Audio menu is split into Track, Audio, Repair and Speech, and nothing of today's menus is lost")
    func menus() throws {
        let menus = Commands.all.map(\.menu)
        var order: [Command.Menu] = []
        for m in menus where order.last != m { order.append(m) }
        #expect(order == Command.Menu.allCases, "\(order)")
        // Every operation today's menus reach is still reached.
        for name in ["fade_in", "fade_out", "silence", "crop", "insert_silence", "gain", "normalize", "loudness_preset", "level_speakers", "debleed",
                     "detect_tempo", "set_layout", "duck", "limit", "restore", "spectral_attenuate", "spectral_edit", "diarize", "split_speakers",
                     "transcribe_voice_tracks", "separate", "clone_voice", "overdub", "add_marker", "set_tempo"] {
            #expect(Commands.all.contains { $0.agent == .operation(name) }, "\(name)")
        }
        // The kept list of the app's menus (Config/menus-en.txt) holds no item the registry doesn't.
        let kept = try String(contentsOf: Self.repo.appending(path: "Config/menus-en.txt"), encoding: .utf8)
        #expect(!kept.isEmpty)
    }

    @Test("The window controls: ids unique and apart from the commands', each in a file that exists")
    func windowControls() {
        let ids = WindowControls.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(Set(ids).isDisjoint(with: Commands.all.map(\.id)))
        for c in WindowControls.all {
            #expect(FileManager.default.fileExists(atPath: Self.repo.appending(path: c.file).path), "\(c.id): \(c.file)")
        }
    }

    @Test("Every command is reachable from ⌘K unless it is the system's own")
    func palette() {
        for c in Commands.all where !c.inPalette {
            switch c.agent {
            case .none(.system), .none(.assistant): break
            default: #expect(["edit.undo", "edit.redo", "edit.findNext"].contains(c.id), "\(c.id) is left out of ⌘K")
            }
        }
    }

    @Test("The palette's tools: ten, each with its own letter and a View › Tool item, the letters free of the menus' plain keys")
    func tools() {
        let tools = Commands.tools
        #expect(tools.map(\.id) == ["select", "split", "trim", "fade", "gain", "box", "lasso", "brush", "zoom", "hand"])
        #expect(Set(tools.map(\.letter)).count == tools.count && tools.allSatisfy { $0.letter.count == 1 })
        for t in tools {
            let c = Commands.command("view.tool." + t.id)
            #expect(c?.submenu == "view.tool" && c?.payload["letter"] == .string(t.letter), "view.tool.\(t.id)")
        }
        // A letter that picks a tool on the timeline is no menu shortcut without a modifier.
        let plain = Commands.all.filter { !$0.key.isEmpty && $0.modifiers.isEmpty }.map(\.key)
        #expect(Set(plain).isDisjoint(with: tools.map(\.letter)), "plain-key shortcuts: \(plain)")
    }

    /// Recording is the person's in the window (SIBLINGS §5): arming and Record have no agent counterpart, as commands
    /// or as window controls, and the API's only recording route reads.
    @Test
    func recordingStaysInTheWindow() {
        for id in ["transport.record", "track.arm"] {
            #expect(Commands.all.first { $0.id == id }?.agent == .none(.microphone), "\(id)")
        }
        for id in ["header.arm", "transport.recordButton", "clip.deleteTake", "recording.recover"] {
            #expect(WindowControls.all.first { $0.id == id }?.agent == .none(.microphone), "\(id)")
        }
        let routes = AgentAPI.routes.filter { $0.path.hasSuffix("/recording") }
        #expect(routes.map(\.method) == ["GET"])
        #expect(WindowControls.all.first { $0.id == "clip.takes" }?.agent == .operation("set_take"), "choosing among takes is a step")
    }

    /// The sweep of the window's controls (SIBLINGS, "Agenten når allt som fönstret gör"; the coordinator,
    /// 2026-11-26): every labeled control found is covered by a control the table lists or by a registry command,
    /// its key still stands in its file, and none drops out (150 found; more may come).
    @Test("Every labeled control in the window is covered, by a listed control or a command; none drops out")
    func theWindowActionsFoundAreAllListed() throws {
        let controls = Set(WindowControls.all.map(\.id)), commands = Set(Commands.all.map(\.id))
        #expect(WindowControls.found.count >= 150, "a control dropped out of the table: \(WindowControls.found.count)")
        for (control, covered) in WindowControls.found.sorted(by: { $0.key < $1.key }) {
            #expect(controls.contains(covered) || commands.contains(covered), "\(control) → \(covered), which is neither a control nor a command")
            let parts = control.split(separator: ":", maxSplits: 1).map(String.init)
            let file = Self.repo.appending(path: "App/\(parts[0]).swift")
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(text.contains("\"\(parts[1])\""), "\(control): the key is no longer in \(parts[0]).swift")
        }
    }

    /// Deleting a cloned voice removes paid work that can only be got back by paying again: the person's own, in
    /// the window (the coordinator, 2026-11-26). The agent lists the voices and can suggest one; it can't delete.
    @Test("The agent can't delete a cloned voice: no operation, the menu item the window's alone, the old call gone with a pointer to the window")
    func deletingAVoiceIsThePersons() {
        let every = Operations.all + Operations.endpoints
        #expect(!every.contains { $0.name == "delete_voice" })
        #expect(!every.contains { $0.call?.method == "DELETE" && $0.call?.path.contains("/voices/") == true })
        #expect(Commands.all.first { $0.id == "speech.deleteVoice" }?.agent == .none(.paidWork))
        #expect(AgentAPI.deleteVoiceGone.contains("Speech › Delete Cloned Voice"))
        #expect(every.contains { $0.name == "list_voices" }, "the agent still sees the voices")
    }

    /// Anders, 2026-11-25: when others' voices are recorded, one line in the window about consent is enough. It is
    /// in both languages and stands beside Record while a track is armed.
    @Test("Recording: the line about consent is in English and Swedish, shown while a track is armed")
    func recordingConsentLine() throws {
        let data = try Data(contentsOf: Self.repo.appending(path: "App/Localizable.xcstrings"))
        let strings = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["strings"] as? [String: Any])
        let entry = try #require(strings["record.consent"] as? [String: Any], "the line is in the catalogue")
        let l = try #require(entry["localizations"] as? [String: Any])
        func value(_ lang: String) -> String? { ((l[lang] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String }
        #expect(value("en")?.contains("consent") == true && value("sv")?.contains("samtycke") == true, "\(value("en") ?? "") / \(value("sv") ?? "")")
        let bar = try String(contentsOf: Self.repo.appending(path: "App/EditorWindowController.swift"), encoding: .utf8)
        let at = try #require(bar.range(of: "L10n.text(\"record.consent\")"), "the transport bar shows it")
        #expect(bar[..<at.lowerBound].suffix(200).contains("!session.armed.isEmpty"), "while a track is armed")
    }
}
