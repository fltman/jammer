import AppKit
import AudioToolbox
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
    /// Settings from elsewhere the user allowed, which load only out of process (Anders, 2026-11-18), and
    /// what a plugin running on them made afterwards: it may still carry what came from elsewhere.
    private static let confinedKey = "plugins.confinedSettings"
    nonisolated(unsafe) private static var confinedOrder: [String] = UserDefaults.standard.stringArray(forKey: confinedKey) ?? []
    nonisolated(unsafe) private static var confinedSet = Set(UserDefaults.standard.stringArray(forKey: confinedKey) ?? [])

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

    static func isConfined(_ plugin: PluginID, _ state: Data) -> Bool {
        let d = digest(plugin, state)
        return lock.withLock { confinedSet.contains(d) && !known.contains(d) }
    }

    /// At launch: from now on the plugin host asks here before it loads saved settings, and runs an Audio
    /// Unit out of process when its settings came from elsewhere.
    static func install() {
        InsertUnits.withheld = { plugin, state in !isKnown(plugin, state) && !isConfined(plugin, state) }
        InsertUnits.confined = { plugin, state in isConfined(plugin, state) }
    }

    /// Settings from elsewhere the user allowed: they load, but only out of process.
    static func allowConfined(_ inserts: [Insert]) {
        let add = inserts.compactMap { i in i.state.map { digest(i.plugin, $0) } }
        guard !add.isEmpty else { return }
        lock.withLock {
            let new = add.filter { !confinedSet.contains($0) }
            guard !new.isEmpty else { return }
            confinedOrder += new
            if confinedOrder.count > most { confinedOrder.removeFirst(confinedOrder.count - most) }
            confinedSet = Set(confinedOrder)
            UserDefaults.standard.set(confinedOrder, forKey: confinedKey)
        }
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
        let before = Set(old.allInserts.compactMap(\.state))
        let changed = new.allInserts.filter { $0.state.map { !before.contains($0) } ?? false }
        // A plugin that ran on settings from elsewhere stays out of process with what it makes of them.
        let wasConfined = Set(old.allInserts.filter { i in i.state.map { isConfined(i.plugin, $0) } ?? false }.map(\.id))
        allowConfined(changed.filter { wasConfined.contains($0.id) })
        allow(changed.filter { !wasConfined.contains($0.id) })
    }

    /// What kind of plugin it is, for the question: format, and an Audio Unit's kind and maker's code.
    static func kind(_ p: PluginID) -> String {
        switch p.format {
        case .au:
            let type = p.type == kAudioUnitType_MusicEffect ? L10n.text("pluginSettings.kind.musicEffect")
                : p.type == kAudioUnitType_MusicDevice ? L10n.text("pluginSettings.kind.instrument") : L10n.text("pluginSettings.kind.effect")
            let maker = String(bytes: withUnsafeBytes(of: p.manufacturer.bigEndian, Array.init), encoding: .macOSRoman) ?? "?"
            return L10n.text("pluginSettings.kind.au", type, maker)
        case .vst3: return L10n.text("pluginSettings.kind.vst3")
        case .clap: return L10n.text("pluginSettings.kind.clap")
        }
    }
}

extension EditorSession {
    /// The plugins of this document whose saved settings haven't been allowed.
    var insertsWithUnknownSettings: [(track: String, insert: Insert)] {
        // Plugins on buses bring settings like any other, and are asked about like any other.
        let strips = project.tracks.map { ($0.name, $0.inserts) } + project.buses.map { ($0.name, $0.inserts) }
        return strips.flatMap { name, inserts in inserts.filter { i in i.state.map { !PluginStateTrust.isKnown(i.plugin, $0) } ?? false }.map { (name, $0) } }
    }

    /// Asks once, when a project that came from somewhere else brings settings for plugins.
    func askAboutPluginSettings(in window: NSWindow) {
        let unknown = insertsWithUnknownSettings
        guard !unknown.isEmpty else { return }
        let alert = NSAlert()
        let names = Array(Set(unknown.map(\.insert.name))).sorted()
        alert.messageText = names.count == 1 ? L10n.text("pluginSettings.ask.title.one", names[0]) : L10n.text("pluginSettings.ask.title.many", String(names.count))
        let shown = unknown.prefix(6).map { L10n.text("pluginSettings.ask.rowKind", $0.insert.name, PluginStateTrust.kind($0.insert.plugin), $0.track) }.joined(separator: "\n")
            + (unknown.count > 6 ? "\n" + L10n.text("ask.more", String(unknown.count - 6)) : "")
        alert.informativeText = L10n.text("pluginSettings.ask.textConfined", name, shown)
        alert.addButton(withTitle: L10n.text("ask.openWithout"))
        alert.addButton(withTitle: L10n.text("pluginSettings.ask.loadConfined"))
        alert.beginSheetModal(for: window) { [weak self] answer in
            MainActor.assumeIsolated {
                guard let self else { return }
                let n = unknown.count
                if answer == .alertSecondButtonReturn {
                    // Allowed, but only out of process: each such Audio Unit runs in a process of its own.
                    PluginStateTrust.allowConfined(unknown.map(\.insert))
                    self.syncInserts()
                    self.status = L10n.count("pluginSettings.loadedConfined", n)
                } else {
                    self.status = n == 1 ? L10n.text("pluginSettings.notStarted.one", unknown[0].insert.name)
                        : L10n.text("pluginSettings.notStarted.many", String(n))
                }
            }
        }
    }
}
