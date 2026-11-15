import AppKit
import JammerCore
import JammerPlugins

/// VST 3 and CLAP in the app: the catalogue the scan keeps, the two helper programs inside the
/// app bundle, and what happens when a plugin's helper dies. Jämmer itself never loads a
/// plugin of these formats.
@MainActor
enum HostedPluginsController {
    /// Per build, so a test copy never rewrites the catalogue of the user's real Jämmer.
    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Jammer/plugins-\(Bundle.main.bundleIdentifier ?? "com.brattoo.jammer").json")
    }
    static var probe: URL? { Bundle.main.url(forAuxiliaryExecutable: "jammer-plugin-probe") }
    static var helper: URL? { Bundle.main.url(forAuxiliaryExecutable: "jammer-plugin-host") }
    /// False when this copy of the app was built without the helpers: only Audio Units then.
    static var available: Bool { InsertUnits.external != nil && probe != nil && helper != nil && Confinement.available }
    private(set) static var scanning = false

    /// At launch: what the last scan found is usable at once; new and changed bundles are looked at in the background.
    static func start() {
        guard let helper, probe != nil else { return }
        #if DEBUG
        // Test plugins live in a folder of their own, never in the user's plugin folders: -pluginFolder <path>.
        if let extra = UserDefaults.standard.string(forKey: "pluginFolder") { HostedPlugins.extraFolders = [URL(fileURLWithPath: extra)] }
        #endif
        HostedPlugins.install(helper: helper, catalogue: PluginCatalogue.load(file))
        HostedPlugins.onDeath = { plugin, name, death in
            Task { @MainActor in died(plugin, name: name, how: death) }
        }
        Task { _ = await scan(force: false) }
    }

    /// Looks through the plugin folders (each bundle in a confined helper process). Returns the catalogue after it.
    @discardableResult
    static func scan(force: Bool, progress: @escaping @Sendable (Double) -> Void = { _ in }, cancelled: @escaping @Sendable () -> Bool = { false }) async -> PluginCatalogue {
        guard let probe, !scanning else { return HostedPlugins.current() }
        scanning = true
        defer { scanning = false }
        let before = HostedPlugins.current(), file = self.file
        var catalogue = await Task.detached(priority: .utility) { () -> PluginCatalogue in
            var c = before
            // CLAP only for now: the scanner reads VST 3 bundles too, but nothing can run them yet,
            // and a plugin that is listed has to be one that works.
            let clap = HostedPlugins.folders(.clap)
            c.scan(with: PluginScanner(probe: probe, readable: clap), folders: [.clap: clap],
                   force: force, progress: progress, cancelled: cancelled)
            try? c.save(file)
            return c
        }.value
        // What was blocked while the scan ran stays blocked.
        catalogue.blocked.formUnion(HostedPlugins.current().blocked)
        HostedPlugins.update(catalogue)
        return catalogue
    }

    /// A plugin's helper died while a track was using it: the sound goes on unprocessed, the
    /// plugin is switched off so it isn't started again, and the user is told.
    static func died(_ plugin: PluginID, name: String, how: PluginHostProcess.Death) {
        var c = HostedPlugins.current()
        let first = c.blocked.insert(plugin.description).inserted
        HostedPlugins.update(c)
        try? c.save(file)
        let message = "\(name) \(how.description) and was switched off. Tracks that use it play without it; the document is untouched. Switch it on again in Audio › Plugins…."
        for doc in NSDocumentController.shared.documents.compactMap({ ($0 as? JammerDocument)?.session }) { doc.status = message }
        if first { NSSound.beep() }
    }

    /// Only the user does this, in Audio › Plugins….
    static func unblock(_ key: String) {
        var c = HostedPlugins.current()
        c.blocked.remove(key)
        HostedPlugins.update(c)
        try? c.save(file)
    }
}
