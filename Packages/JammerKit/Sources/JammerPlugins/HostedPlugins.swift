import Foundation
import JammerCore

/// A VST 3 or CLAP plugin on a track: its helper process, as the insert host, the steps and
/// the agent API see any unit.
public final class HostedInsertUnit: InsertUnit, @unchecked Sendable {
    public let plugin: PluginID
    public let displayName: String
    public let host: PluginHostProcess
    private let engineUnit: PluginHostUnit
    private let sampleRate: Double

    public var unit: OpaquePointer { engineUnit.unit }
    public var latency: Int64 { Int64(host.latency) }
    /// The formats don't report a tail to rely on; a second covers ordinary effects.
    public var tail: Int64 { Int64(sampleRate) }

    init(plugin: PluginID, name: String, host: PluginHostProcess, sampleRate: Double) {
        self.plugin = plugin
        displayName = name
        self.host = host
        self.sampleRate = sampleRate
        engineUnit = PluginHostUnit(host)
    }

    deinit { HostedPlugins.released() }

    /// Marks settings Jämmer wrote itself, for a plugin that can't save its own.
    static let ownStateMagic = Data("JAMMER-PARAMS-1\n".utf8)

    /// The plugin's own saved state when it has one. A plugin without that would lose its
    /// settings when the document is closed, so for those Jämmer keeps the parameter values
    /// itself (id and value of every parameter that can be set) and puts them back on loading.
    public func captureState() -> Data? {
        if let own = host.saveState() { return own }
        host.refresh()
        let values = Dictionary(host.parameters.filter { !$0.readonly }.map { (String($0.id), $0.value) }, uniquingKeysWith: { a, _ in a })
        guard !values.isEmpty, let json = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) else { return nil }
        return Self.ownStateMagic + json
    }

    public func apply(_ state: Data) throws {
        if state.starts(with: Self.ownStateMagic) {
            guard let values = try? JSONSerialization.jsonObject(with: state.dropFirst(Self.ownStateMagic.count)) as? [String: Double] else {
                throw PluginError.failed("The saved settings for \(displayName) can't be read.")
            }
            let known = Dictionary(host.parameters.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for (key, value) in values {
                // A parameter the plugin no longer has, or can't take, is skipped: the rest still apply.
                guard let id = UInt32(key), let p = known[id], !p.readonly else { continue }
                _ = host.set(id, to: min(p.max, max(p.min, value)))
            }
            return
        }
        guard host.loadState(state) else { throw PluginError.failed("The saved settings for \(displayName) couldn't be applied.") }
    }

    public var parameters: [PluginParameter] {
        host.refresh()
        return host.parameters.filter { !$0.hidden }.map {
            PluginParameter(identifier: String($0.id), name: $0.module.isEmpty ? $0.name : "\($0.module): \($0.name)", unit: nil, min: $0.min, max: $0.max, value: $0.value)
        }
    }

    public func set(_ identifier: String, to value: Double) throws {
        guard host.died == nil else { throw PluginError.failed("\(displayName) \(host.died!.description) and is switched off.") }
        let all = host.parameters
        guard let p = all.first(where: { String($0.id) == identifier }) ?? all.first(where: { $0.name.caseInsensitiveCompare(identifier) == .orderedSame }) else {
            throw PluginError.unknownParameter("\(displayName) has no parameter \"\(identifier)\".")
        }
        guard !p.readonly else { throw PluginError.outOfRange("\(p.name) can only be read.") }
        guard value >= p.min, value <= p.max else {
            throw PluginError.outOfRange("\(p.name) takes \(p.min.formatted()) to \(p.max.formatted()); \(value.formatted()) is outside.")
        }
        guard host.set(p.id, to: value) else { throw PluginError.failed("\(displayName) didn't take the value.") }
    }

    public var factoryPresets: [String] { [] }
    public func loadPreset(_ name: String) throws { throw PluginError.unknownPreset("\(displayName) has no factory presets here.") }
}

/// The app's side of VST 3 and CLAP: the catalogue from the scan, and starting a plugin in a
/// helper process when a track asks for one. `install` plugs both into JammerCore.
public enum HostedPlugins {
    /// How many helper processes may run at once (each plugin has its own).
    nonisolated(unsafe) public static var limit = 64

    private static let lock = NSLock()
    nonisolated(unsafe) private static var running = 0
    nonisolated(unsafe) private static var catalogue = PluginCatalogue()
    nonisolated(unsafe) private static var helper: URL?
    /// Told when a plugin's helper dies while it is in use: the plugin's id, its name and how it ended.
    nonisolated(unsafe) public static var onDeath: (@Sendable (_ plugin: PluginID, _ name: String, _ death: PluginHostProcess.Death) -> Void)?

    /// Folders searched and readable besides the standard plugin folders (debug builds: a test folder).
    nonisolated(unsafe) public static var extraFolders: [URL] = []
    public static func folders(_ format: PluginFormat) -> [URL] { PluginScanner.pluginFolders(format) + extraFolders }

    public static var runningCount: Int { lock.withLock { running } }
    static func released() { lock.withLock { running = max(0, running - 1) } }

    public static func current() -> PluginCatalogue { lock.withLock { catalogue } }
    public static func update(_ c: PluginCatalogue) { lock.withLock { catalogue = c } }

    static func info(_ p: ScannedPlugin) -> PluginInfo {
        PluginInfo(id: PluginID(format: p.format == .vst3 ? .vst3 : .clap, uid: p.id), name: p.name, manufacturer: p.vendor.isEmpty ? "Unknown" : p.vendor,
                   kind: "effect", version: p.version, isV3: false)
    }

    /// Makes JammerCore list the scanned plugins and start them through `helper`.
    public static func install(helper: URL, catalogue: PluginCatalogue) {
        lock.withLock {
            self.helper = helper
            self.catalogue = catalogue
        }
        PluginCatalog.external = { current().plugins.map(info) }
        PluginCatalog.whyUnavailable = { wanted in
            let c = current()
            guard let p = c.entries.flatMap(\.plugins).first(where: { PluginCatalogue.key($0) == wanted || $0.name.caseInsensitiveCompare(wanted) == .orderedSame }),
                  c.blocked.contains(PluginCatalogue.key(p)) else { return nil }
            return "\(p.name) is switched off because it failed while it was in use. The user can switch it on again in Jämmer under Audio › Plugins…."
        }
        InsertUnits.external = { plugin, channels, sampleRate, state in try start(plugin, channels: channels, sampleRate: sampleRate, state: state) }
    }

    static func start(_ plugin: PluginID, channels: Int, sampleRate: Double, state: Data?) throws -> any InsertUnit {
        let (c, helper) = lock.withLock { (catalogue, self.helper) }
        let key = plugin.description
        if c.blocked.contains(key) {
            throw PluginError.failed("\(key) is switched off because it failed while it was in use. Switch it on again in Audio › Plugins….")
        }
        guard let found = c.plugin(key), let helper else {
            throw PluginError.notFound("No plugin \(key) is installed (or the last scan didn't find it).")
        }
        // Counted before starting, so two tracks can't both take the last place.
        let allowed = lock.withLock { () -> Bool in
            guard running < limit else { return false }
            running += 1
            return true
        }
        guard allowed else {
            throw PluginError.failed("\(limit) VST 3 and CLAP plugins are already running, which is the most Jämmer starts at once (each runs in a process of its own). Remove or bypass some to add \(found.name).")
        }
        let host: PluginHostProcess
        do {
            host = try PluginHostProcess(helper: helper, format: found.format, bundle: URL(fileURLWithPath: found.bundle), id: found.id,
                                         sampleRate: sampleRate, channels: channels, readable: folders(.vst3) + folders(.clap))
        } catch let e as PluginHostProcess.StartError {
            released()
            let message = e.message
            if message.contains("mono audio") || message.contains("stereo audio") { throw PluginError.unsupportedFormat("\(found.name): \(message)") }
            throw PluginError.failed("\(found.name) didn't start: \(message)")
        }
        let name = found.name
        host.onDeath = { death in onDeath?(plugin, name, death) }
        let unit = HostedInsertUnit(plugin: plugin, name: name, host: host, sampleRate: sampleRate)
        if let state, !state.isEmpty { try unit.apply(state) }
        return unit
    }
}
