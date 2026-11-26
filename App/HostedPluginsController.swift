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
        AppData.folder.appending(path: "plugins-\(Bundle.main.bundleIdentifier ?? "com.brattoo.jammer").json")
    }
    static var probe: URL? { Bundle.main.url(forAuxiliaryExecutable: "jammer-plugin-probe") }
    static var helper: URL? { Bundle.main.url(forAuxiliaryExecutable: "jammer-plugin-host") }
    /// False when this copy of the app was built without the helpers: only Audio Units then.
    static var available: Bool {
        #if DEBUG
        // A debug copy started as a release has it (`-asRelease YES`, for the manual's pictures): no helpers, as with JAMMER_CLAP = NO.
        if UserDefaults.standard.bool(forKey: "asRelease") { return false }
        #endif
        return InsertUnits.external != nil && probe != nil && helper != nil && Confinement.available
    }
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
    /// Stopped (the job's task cancelled), the bundle being probed is the last: nothing is saved and the list the
    /// app has stays as it was.
    @discardableResult
    static func scan(force: Bool, progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> PluginCatalogue {
        guard let probe, !scanning else { return HostedPlugins.current() }
        scanning = true
        defer { scanning = false }
        let before = HostedPlugins.current(), file = self.file
        // The scan runs detached, where Task.isCancelled is always false: the stop reaches it through Stoppable.
        let (scanned, stopped) = await Stoppable.run { stopped -> PluginCatalogue in
            var c = before
            // CLAP from the user's plugin folders. VST 3 can be hosted too, but so far only our own
            // test plugins have been through it, and a plugin that is listed has to be one that works:
            // until real ones have been tried, VST 3 is read only from the test folder (-pluginFolder).
            let clap = HostedPlugins.folders(.clap), vst3 = HostedPlugins.extraFolders
            c.scan(with: PluginScanner(probe: probe, readable: clap + vst3), folders: vst3.isEmpty ? [.clap: clap] : [.clap: clap, .vst3: vst3],
                   force: force, progress: progress, cancelled: stopped)
            return c
        }
        if stopped { return HostedPlugins.current() }
        var catalogue = scanned
        try? catalogue.save(file)
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
        let message = L10n.text("plugins.died", name, how.description)
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
