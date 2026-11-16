import AppKit
import CryptoKit
import JammerCore

/// Which saved plugin settings may be loaded into a plugin. Settings are bytes that someone
/// else's code reads, and a project is passed between people: settings that were made in this
/// Jämmer (by the plugin itself, when the user or an agent changed something) are remembered by
/// their digest and loaded without a word; settings a project brings from elsewhere are not
/// loaded until the user has said yes. The same for Audio Units, CLAP and VST 3.
enum PluginStateTrust {
    private static let key = "plugins.knownSettings"
    private static let most = 5_000
    private static let lock = NSLock()
    nonisolated(unsafe) private static var order: [String] = UserDefaults.standard.stringArray(forKey: key) ?? []
    nonisolated(unsafe) private static var known = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])

    static func digest(_ plugin: PluginID, _ state: Data) -> String {
        var h = SHA256()
        h.update(data: Data(plugin.description.utf8))
        h.update(data: Data([0]))
        h.update(data: state)
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func isKnown(_ plugin: PluginID, _ state: Data) -> Bool {
        let d = digest(plugin, state)
        return lock.withLock { known.contains(d) }
    }

    /// At launch: from now on the plugin host asks here before it loads saved settings.
    static func install() {
        InsertUnits.withheld = { plugin, state in !isKnown(plugin, state) }
    }

    /// These settings were made here, or the user allowed them.
    static func allow(_ inserts: [Insert]) {
        let add = inserts.compactMap { i in i.state.map { digest(i.plugin, $0) } }
        guard !add.isEmpty else { return }
        lock.withLock {
            let new = add.filter { !known.contains($0) }
            guard !new.isEmpty else { return }
            order += new
            if order.count > most { order.removeFirst(order.count - most) }
            known = Set(order)
            UserDefaults.standard.set(order, forKey: key)
        }
    }

    /// A change made in this Jämmer: the settings in `new` that `old` didn't have came out of a
    /// plugin running here (there is no way to hand a plugin's settings in from outside in an edit).
    static func noteMade(from old: Project, to new: Project) {
        let before = Set(old.tracks.flatMap(\.inserts).compactMap(\.state))
        allow(new.tracks.flatMap(\.inserts).filter { $0.state.map { !before.contains($0) } ?? false })
    }
}

extension EditorSession {
    /// The plugins of this document whose saved settings haven't been allowed.
    var insertsWithUnknownSettings: [(track: String, insert: Insert)] {
        project.tracks.flatMap { t in t.inserts.filter { i in i.state.map { !PluginStateTrust.isKnown(i.plugin, $0) } ?? false }.map { (t.name, $0) } }
    }

    /// Asks once, when a project that came from somewhere else brings settings for plugins.
    func askAboutPluginSettings(in window: NSWindow) {
        let unknown = insertsWithUnknownSettings
        guard !unknown.isEmpty else { return }
        let alert = NSAlert()
        let names = Array(Set(unknown.map(\.insert.name))).sorted()
        alert.messageText = names.count == 1 ? "This project wants to load settings into \(names[0])" : "This project wants to load settings into \(names.count) plugins"
        let shown = unknown.prefix(6).map { "• \($0.insert.name) on “\($0.track)”" }.joined(separator: "\n")
        alert.informativeText = "“\(name)” brings saved settings for:\n\n\(shown)\(unknown.count > 6 ? "\n… and \(unknown.count - 6) more" : "")\n\nSettings are data the plugin reads, and they weren't made in this Jämmer. If the project is your own, or you trust where it came from, load them. Otherwise open it without: those plugins aren't started and their tracks play without them."
        alert.addButton(withTitle: "Open Without Them")
        alert.addButton(withTitle: "Load Settings")
        alert.beginSheetModal(for: window) { [weak self] answer in
            MainActor.assumeIsolated {
                guard let self else { return }
                let n = unknown.count
                if answer == .alertSecondButtonReturn {
                    PluginStateTrust.allow(unknown.map(\.insert))
                    self.syncInserts()
                    self.status = "Loaded the project's settings into \(n) plugin\(n == 1 ? "" : "s")."
                } else {
                    self.status = n == 1 ? "\(unknown[0].insert.name) wasn't started: the project's settings for it weren't loaded."
                        : "\(n) plugins weren't started: the project's settings for them weren't loaded."
                }
            }
        }
    }
}
