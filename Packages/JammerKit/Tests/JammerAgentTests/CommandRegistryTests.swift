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

    @Test("Every command has an agent counterpart: an operation in the registry, a route the API has, or an accepted reason")
    func agentCoverage() {
        let ops = Set((Operations.all + Operations.endpoints).map(\.name))
        let routes = AgentAPI.routes
        for c in Commands.all {
            switch c.agent {
            case .operation(let name):
                #expect(ops.contains(name), "\(c.id): no operation \(name)")
            case .route(let method, let path):
                let pattern = AgentAPI.RouteParameters(method, path).pattern
                #expect(routes.contains { $0.method == method && $0.pattern == pattern }, "\(c.id): no route \(method) \(path)")
            case .none(let why):
                #expect(Command.Exemption.allCases.contains(why), "\(c.id)")
            }
        }
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

    @Test("The menus follow Apple's order, the Audio menu is split into Track, Audio, Repair and Speech, and nothing of today's menus is lost")
    func menus() throws {
        let menus = Commands.all.map(\.menu)
        var order: [Command.Menu] = []
        for m in menus where order.last != m { order.append(m) }
        #expect(order == Command.Menu.allCases, "\(order)")
        // Every operation today's menus reach is still reached.
        for name in ["fade_in", "fade_out", "silence", "crop", "insert_silence", "gain", "normalize", "loudness_preset", "level_speakers", "debleed",
                     "detect_tempo", "set_layout", "duck", "limit", "restore", "spectral_attenuate", "spectral_edit", "diarize", "split_speakers",
                     "transcribe_voice_tracks", "separate", "clone_voice", "overdub", "delete_voice", "add_marker", "set_tempo"] {
            #expect(Commands.all.contains { $0.agent == .operation(name) }, "\(name)")
        }
        // The kept list of the app's menus (Config/menus-en.txt) holds no item the registry doesn't.
        let kept = try String(contentsOf: Self.repo.appending(path: "Config/menus-en.txt"), encoding: .utf8)
        #expect(!kept.isEmpty)
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
}
