import AVFAudio
import AudioToolbox
import Foundation
import JammerEngine

/// A plugin's identity. An Audio Unit is its component's type, subtype and manufacturer,
/// written "aufx/lmtr/appl"; a VST 3 plugin is "vst3:" and its class id (32 hex digits); a CLAP
/// plugin is "clap:" and its id. Projects saved before the other formats existed hold the
/// Audio Unit form and open unchanged.
public struct PluginID: Hashable, Sendable, Codable, CustomStringConvertible {
    public enum Format: String, Sendable, Codable, CaseIterable { case au, vst3, clap }

    public var format: Format
    /// Audio Units only (0 otherwise).
    public var type: OSType
    public var subtype: OSType
    public var manufacturer: OSType
    /// VST 3 and CLAP only: the format's own id.
    public var uid: String

    public init(type: OSType, subtype: OSType, manufacturer: OSType) {
        format = .au
        self.type = type
        self.subtype = subtype
        self.manufacturer = manufacturer
        uid = ""
    }

    public init(format: Format, uid: String) {
        self.format = format
        type = 0
        subtype = 0
        manufacturer = 0
        self.uid = uid
    }

    public init(_ d: AudioComponentDescription) {
        self.init(type: d.componentType, subtype: d.componentSubType, manufacturer: d.componentManufacturer)
    }

    public init?(_ string: String) {
        for f in [Format.vst3, .clap] where string.hasPrefix(f.rawValue + ":") {
            let uid = String(string.dropFirst(f.rawValue.count + 1))
            guard !uid.isEmpty else { return nil }
            self.init(format: f, uid: uid)
            return
        }
        let parts = string.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, let t = Self.code(parts[0]), let s = Self.code(parts[1]), let m = Self.code(parts[2]) else { return nil }
        self.init(type: t, subtype: s, manufacturer: m)
    }

    public var description: String {
        format == .au ? [type, subtype, manufacturer].map(Self.text).joined(separator: "/") : "\(format.rawValue):\(uid)"
    }

    public var componentDescription: AudioComponentDescription {
        AudioComponentDescription(componentType: type, componentSubType: subtype, componentManufacturer: manufacturer,
                                  componentFlags: 0, componentFlagsMask: 0)
    }

    static func code<S: StringProtocol>(_ s: S) -> OSType? {
        let bytes = Array(s.data(using: .macOSRoman) ?? Data())
        guard bytes.count == 4 else { return nil }
        return bytes.reduce(0) { $0 << 8 | OSType($1) }
    }

    static func text(_ c: OSType) -> String {
        let bytes = [UInt8(c >> 24), UInt8((c >> 16) & 0xFF), UInt8((c >> 8) & 0xFF), UInt8(c & 0xFF)]
        return String(bytes: bytes, encoding: .macOSRoman) ?? String(format: "%08x", c)
    }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let id = PluginID(s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a plugin id: \(s)"))
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

/// An Audio Unit on a track. The settings are the unit's full state as a binary plist,
/// so changing them is an ordinary value change on the project.
public struct Insert: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var plugin: PluginID
    public var name: String
    public var state: Data?
    public var bypass: Bool
    /// The sidechain key: the track or bus whose signal, after its fader, the plugin listens to on its
    /// second input. nil: none.
    public var key: UUID?

    public init(id: UUID = UUID(), plugin: PluginID, name: String, state: Data? = nil, bypass: Bool = false) {
        self.id = id
        self.plugin = plugin
        self.name = name
        self.state = state
        self.bypass = bypass
    }
}

/// An installed effect.
public struct PluginInfo: Sendable, Codable, Hashable {
    public var id: PluginID
    public var name: String
    public var manufacturer: String
    /// "effect" or "music_effect".
    public var kind: String
    public var version: String
    public var isV3: Bool
    public var format: PluginID.Format { id.format }

    public init(id: PluginID, name: String, manufacturer: String, kind: String, version: String, isV3: Bool) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.kind = kind
        self.version = version
        self.isV3 = isV3
    }
}

public enum PluginError: Error, LocalizedError, Equatable {
    case notFound(String)
    case unsupportedFormat(String)
    case failed(String)
    case unknownParameter(String)
    case outOfRange(String)
    case unknownPreset(String)
    /// The plugin's saved settings came with a project and the user hasn't allowed them (the plugin's name).
    case withheld(String)

    public var reason: String {
        switch self {
        case .notFound: "plugin_not_found"
        case .unsupportedFormat: "plugin_unsupported_format"
        case .failed: "plugin_failed"
        case .unknownParameter, .unknownPreset: "not_found"
        case .outOfRange: "out_of_range"
        case .withheld: "plugin_settings_withheld"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notFound(let m), .unsupportedFormat(let m), .failed(let m), .unknownParameter(let m), .outOfRange(let m), .unknownPreset(let m): m
        case .withheld(let name): "\(name) wasn't started: its settings came with this project, and the user hasn't allowed them to be loaded into the plugin. The track plays without it."
        }
    }
}

public enum PluginCatalog {
    /// VST 3 and CLAP plugins come from the app's scan (they are never loaded in this process);
    /// the app plugs its catalogue in here. nil: only Audio Units.
    nonisolated(unsafe) public static var external: (@Sendable () -> [PluginInfo])?

    /// Why a plugin that isn't offered can't be used, when the app knows (it is switched off
    /// after failing). nil: it simply isn't installed.
    nonisolated(unsafe) public static var whyUnavailable: (@Sendable (_ idOrName: String) -> String?)?

    /// Every installed effect: Audio Units, then what the scan found, sorted by manufacturer and name.
    public static func effects() -> [PluginInfo] {
        (audioUnits() + (external?() ?? [])).sorted { ($0.manufacturer, $0.name, $0.id.description) < ($1.manufacturer, $1.name, $1.id.description) }
    }

    /// Installed Audio Unit effects (aufx and aumf).
    public static func audioUnits() -> [PluginInfo] {
        let manager = AVAudioUnitComponentManager.shared()
        return [kAudioUnitType_Effect, kAudioUnitType_MusicEffect].flatMap { type in
            manager.components(matching: AudioComponentDescription(componentType: type, componentSubType: 0, componentManufacturer: 0,
                                                                   componentFlags: 0, componentFlagsMask: 0))
        }
        .map { c in
            PluginInfo(id: PluginID(c.audioComponentDescription), name: c.name, manufacturer: c.manufacturerName,
                       kind: c.audioComponentDescription.componentType == kAudioUnitType_MusicEffect ? "music_effect" : "effect",
                       version: c.versionString,
                       isV3: c.audioComponentDescription.componentFlags & AudioComponentFlags.isV3AudioUnit.rawValue != 0)
        }
        .sorted { ($0.manufacturer, $0.name) < ($1.manufacturer, $1.name) }
    }

    /// By id ("aufx/lmtr/appl", "clap:…", "vst3:…") or by name, ignoring case ("AUPeakLimiter").
    public static func find(_ s: String, in list: [PluginInfo] = effects()) -> PluginInfo? {
        if let id = PluginID(s), let hit = list.first(where: { $0.id == id }) { return hit }
        return list.first { $0.name.caseInsensitiveCompare(s) == .orderedSame }
            ?? list.first { "\($0.manufacturer): \($0.name)".caseInsensitiveCompare(s) == .orderedSame }
    }
}

/// A plugin parameter as the agent API shows it. `identifier` is the parameter's key path.
public struct PluginParameter: Sendable, Codable, Hashable {
    public var identifier: String
    public var name: String
    public var unit: String?
    public var min: Double
    public var max: Double
    public var value: Double

    public init(identifier: String, name: String, unit: String?, min: Double, max: Double, value: Double) {
        self.identifier = identifier
        self.name = name
        self.unit = unit
        self.min = min
        self.max = max
        self.value = value
    }
}

/// A running effect on a track, whatever its format: what the insert host, the steps and the
/// agent API need of it.
public protocol InsertUnit: AnyObject, Sendable {
    var plugin: PluginID { get }
    var displayName: String { get }
    /// The engine's handle (`jm_unit`); chains keep the unit alive through it.
    var unit: OpaquePointer { get }
    /// Latency in frames at the project rate.
    var latency: Int64 { get }
    /// How long it rings after the input stops, in frames.
    var tail: Int64 { get }
    func captureState() -> Data?
    func apply(_ state: Data) throws
    var parameters: [PluginParameter] { get }
    /// Sets a parameter by identifier (or display name). Refuses values outside its range.
    func set(_ identifier: String, to value: Double) throws
    var factoryPresets: [String] { get }
    func loadPreset(_ name: String) throws
    /// Whether the plugin has a sidechain input that Jämmer can feed a key.
    var hasKeyInput: Bool { get }
    /// Why it can't be given a key although it has the input, in words; nil when it can or has none.
    var keyRefusal: String? { get }
}

public extension InsertUnit {
    var hasKeyInput: Bool { false }
    var keyRefusal: String? { nil }
}

public enum InsertUnits {
    /// Starts a VST 3 or CLAP plugin (in a helper process; the app plugs this in). nil: this
    /// build hosts only Audio Units.
    nonisolated(unsafe) public static var external: (@Sendable (_ plugin: PluginID, _ channels: Int, _ sampleRate: Double, _ state: Data?) throws -> any InsertUnit)?

    /// Saved plugin settings are bytes handed to someone else's code. The ones a project brings with
    /// it from elsewhere aren't loaded until the user has said yes; the app says which those are here.
    /// nil: every state is loaded (tests, tools).
    nonisolated(unsafe) public static var withheld: (@Sendable (_ plugin: PluginID, _ state: Data) -> Bool)?

    static func check(_ plugin: PluginID, _ state: Data?) throws {
        if let state, let withheld, withheld(plugin, state) { throw PluginError.withheld(plugin.description) }
    }

    static func makeExternal(_ plugin: PluginID, channels: Int, sampleRate: Double, state: Data?) throws -> any InsertUnit {
        guard let external else { throw PluginError.notFound("This build can't run \(plugin.format.rawValue.uppercased()) plugins.") }
        do { return try external(plugin, channels, sampleRate, state) } catch let e as PluginError { throw e } catch {
            throw PluginError.failed(error.localizedDescription)
        }
    }

    /// A running unit for `plugin` at the project's rate and channel count.
    public static func make(_ plugin: PluginID, channels: Int, sampleRate: Double, state: Data? = nil, outOfProcess: Bool = false) async throws -> any InsertUnit {
        try check(plugin, state)
        if plugin.format != .au {
            // Starting a helper process can take a moment: not on the caller's thread.
            return try await Task.detached(priority: .userInitiated) { try makeExternal(plugin, channels: channels, sampleRate: sampleRate, state: state) }.value
        }
        return try await PluginInstance.make(plugin, channels: channels, sampleRate: sampleRate, state: state, outOfProcess: outOfProcess)
    }

    /// The same, waiting on this thread (background only).
    public static func makeBlocking(_ plugin: PluginID, channels: Int, sampleRate: Double, state: Data? = nil, outOfProcess: Bool = false) throws -> any InsertUnit {
        try check(plugin, state)
        if plugin.format != .au { return try makeExternal(plugin, channels: channels, sampleRate: sampleRate, state: state) }
        return try PluginInstance.makeBlocking(plugin, channels: channels, sampleRate: sampleRate, state: state, outOfProcess: outOfProcess)
    }
}

/// A running Audio Unit, set up for the project's rate and channels.
public final class PluginInstance: InsertUnit, @unchecked Sendable {
    public var displayName: String { avUnit.name }
    public let plugin: PluginID
    public let avUnit: AVAudioUnit
    public let sampleRate: Double
    /// The engine's handle; chains keep the unit alive through it.
    public let unit: OpaquePointer

    public var audioUnit: AudioUnit { avUnit.audioUnit }
    public var au: AUAudioUnit { avUnit.auAudioUnit }
    public private(set) var hasKeyInput = false
    public private(set) var keyRefusal: String?

    init(plugin: PluginID, avUnit: AVAudioUnit, channels: Int, sampleRate: Double) {
        self.plugin = plugin
        self.avUnit = avUnit
        self.sampleRate = sampleRate
        unit = jm_unit_create(avUnit.audioUnit, Int32(channels), Unmanaged.passRetained(avUnit).toOpaque()) { ctx in
            if let ctx { Unmanaged<AVAudioUnit>.fromOpaque(ctx).release() }
        }
    }

    deinit { jm_unit_release(unit) }

    /// Instantiates and initializes `plugin` for non-interleaved float at `sampleRate`.
    /// In-process unless `outOfProcess` (safe mode).
    public static func make(_ plugin: PluginID, channels: Int, sampleRate: Double, state: Data? = nil,
                            outOfProcess: Bool = false) async throws -> PluginInstance {
        guard AVAudioUnitComponentManager.shared().components(matching: plugin.componentDescription).first != nil else {
            throw PluginError.notFound("No Audio Unit \(plugin) is installed.")
        }
        let av: AVAudioUnit
        do {
            av = try await AVAudioUnit.instantiate(with: plugin.componentDescription, options: outOfProcess ? .loadOutOfProcess : .loadInProcess)
        } catch where !outOfProcess {
            // The hardened runtime refuses to load other developers' code into Jämmer;
            // such plugins run in a process of their own instead.
            do {
                av = try await AVAudioUnit.instantiate(with: plugin.componentDescription, options: .loadOutOfProcess)
            } catch {
                throw PluginError.failed("\(plugin) didn't start: \(error.localizedDescription)")
            }
        } catch {
            throw PluginError.failed("\(plugin) didn't start: \(error.localizedDescription)")
        }
        return try setUp(av, plugin: plugin, channels: channels, sampleRate: sampleRate, state: state)
    }

    /// The same, waiting on this thread: for background work (the step runner, offline
    /// renders). Never on the main thread, which instantiation may need.
    public static func makeBlocking(_ plugin: PluginID, channels: Int, sampleRate: Double, state: Data? = nil,
                                    outOfProcess: Bool = false) throws -> PluginInstance {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard AVAudioUnitComponentManager.shared().components(matching: plugin.componentDescription).first != nil else {
            throw PluginError.notFound("No Audio Unit \(plugin) is installed.")
        }
        final class Box: @unchecked Sendable { var unit: AVAudioUnit?; var error: Error? }
        func attempt(_ options: AudioComponentInstantiationOptions) throws -> AVAudioUnit {
            let box = Box(), done = DispatchSemaphore(value: 0)
            AVAudioUnit.instantiate(with: plugin.componentDescription, options: options) { u, e in
                box.unit = u
                box.error = e
                done.signal()
            }
            guard done.wait(timeout: .now() + 30) == .success else { throw PluginError.failed("\(plugin) took too long to start.") }
            guard let av = box.unit else { throw PluginError.failed("\(plugin) didn't start: \(box.error?.localizedDescription ?? "no unit")") }
            return av
        }
        let av: AVAudioUnit
        if !outOfProcess, let inProcess = try? attempt(.loadInProcess) {
            av = inProcess
        } else {
            av = try attempt(.loadOutOfProcess)
        }
        return try setUp(av, plugin: plugin, channels: channels, sampleRate: sampleRate, state: state)
    }

    private static func setUp(_ av: AVAudioUnit, plugin: PluginID, channels: Int, sampleRate: Double, state: Data?) throws -> PluginInstance {
        let u = av.audioUnit
        AudioUnitUninitialize(u)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        for scope in [kAudioUnitScope_Input, kAudioUnitScope_Output] {
            guard AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, scope, 0, &asbd, size) == noErr else {
                throw PluginError.unsupportedFormat("\(av.name) can't process \(channels == 1 ? "mono" : "\(channels)-channel") float audio at \(Int(sampleRate)) Hz.")
            }
        }
        // A second input is the sidechain: given the same format as the first, before the unit is initialised.
        var inputs: UInt32 = 0, inputsSize = UInt32(MemoryLayout<UInt32>.size)
        AudioUnitGetProperty(u, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &inputs, &inputsSize)
        var keyed = false
        var refusal: String?
        if inputs >= 2 {
            if !av.auAudioUnit.isLoadedInProcess {
                refusal = "\(av.name) has a sidechain input, but it runs in a process of its own here (Safe Mode, or because macOS wouldn't load it into Jämmer), and a key isn't carried there yet."
            } else if AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &asbd, size) == noErr {
                keyed = true
            } else {
                refusal = "\(av.name) has a sidechain input, but it wouldn't take \(channels == 1 ? "mono" : "stereo") float audio on it."
            }
        }
        var maxFrames: UInt32 = 4_096
        AudioUnitSetProperty(u, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, UInt32(MemoryLayout<UInt32>.size))
        let status = AudioUnitInitialize(u)
        guard status == noErr else { throw PluginError.failed("\(av.name) couldn't initialize (error \(status)).") }
        let instance = PluginInstance(plugin: plugin, avUnit: av, channels: channels, sampleRate: sampleRate)
        if keyed {
            if jm_unit_enable_key_input(instance.unit) { instance.hasKeyInput = true }
            else { refusal = "\(av.name) has a sidechain input, but wouldn't let Jämmer feed it." }
        }
        instance.keyRefusal = refusal
        if let state { try instance.apply(state) }
        return instance
    }

    /// Latency in frames at the project rate.
    public var latency: Int64 { Int64((au.latency * sampleRate).rounded()) }
    /// How long it rings after the input stops, in frames (capped at 10 s; some report infinity).
    public var tail: Int64 {
        let t = au.tailTime
        return t.isFinite ? Int64((min(10, max(0, t)) * sampleRate).rounded()) : Int64(10 * sampleRate)
    }

    public func captureState() -> Data? {
        guard let s = au.fullState else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: s, format: .binary, options: 0)
    }

    public func apply(_ state: Data) throws {
        guard let s = try PropertyListSerialization.propertyList(from: state, format: nil) as? [String: Any] else {
            throw PluginError.failed("The saved settings for \(avUnit.name) can't be read.")
        }
        au.fullState = s
    }

    public var parameters: [PluginParameter] {
        (au.parameterTree?.allParameters ?? []).map { p in
            PluginParameter(identifier: p.keyPath, name: p.displayName, unit: p.unitName ?? Self.unitName(p.unit),
                            min: Self.decimal(p.minValue), max: Self.decimal(p.maxValue), value: Self.decimal(p.value))
        }
    }

    /// Sets a parameter by key path (or display name). Refuses values outside its range.
    public func set(_ identifier: String, to value: Double) throws {
        let all = au.parameterTree?.allParameters ?? []
        guard let p = all.first(where: { $0.keyPath == identifier }) ?? all.first(where: { $0.identifier == identifier })
            ?? all.first(where: { $0.displayName.caseInsensitiveCompare(identifier) == .orderedSame }) else {
            throw PluginError.unknownParameter("\(avUnit.name) has no parameter \"\(identifier)\".")
        }
        guard value >= Self.decimal(p.minValue), value <= Self.decimal(p.maxValue) else {
            throw PluginError.outOfRange("\(p.displayName) takes \(Self.decimal(p.minValue).formatted()) to \(Self.decimal(p.maxValue).formatted()); \(value.formatted()) is outside.")
        }
        p.value = AUValue(value)
    }

    public var factoryPresets: [String] { (au.factoryPresets ?? []).map(\.name) }

    public func loadPreset(_ name: String) throws {
        guard let preset = (au.factoryPresets ?? []).first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw PluginError.unknownPreset("\(avUnit.name) has no factory preset \"\(name)\".")
        }
        au.currentPreset = preset
    }

    /// A Float as the shortest decimal that reads back to it (0.03, not 0.029999999329).
    static func decimal(_ v: AUValue) -> Double { Double("\(v)") ?? Double(v) }

    static func unitName(_ u: AudioUnitParameterUnit) -> String? {
        switch u {
        case .decibels: "dB"
        case .hertz: "Hz"
        case .milliseconds: "ms"
        case .seconds: "s"
        case .percent: "%"
        case .ratio: "ratio"
        case .cents: "cents"
        case .boolean: "on/off"
        case .linearGain: "gain"
        default: nil
        }
    }
}

/// Supplies a track's insert chain to the plan compiler.
public protocol ChainProvider: AnyObject {
    /// Sets the track's chain on plan track `index`, if it has one. Returns its latency.
    @discardableResult
    func attachChain(for track: Track, to plan: OpaquePointer, index: Int32) -> Int64?
    /// The same for a bus's plugins on plan bus `index`.
    @discardableResult
    func attachChain(for bus: Bus, to plan: OpaquePointer, index: Int32) -> Int64?
    /// The chain of the master's plugins, if it has any running (not retained for the caller).
    func masterChain(for master: Master) -> OpaquePointer?
    /// The place in a strip's chain of the unit for `insert`, when that unit runs and can take a key.
    func keyUnit(of insert: UUID, among inserts: [Insert]) -> Int32?
}

public extension ChainProvider {
    /// A provider that knows nothing of buses puts no plugins on them.
    @discardableResult
    func attachChain(for bus: Bus, to plan: OpaquePointer, index: Int32) -> Int64? { nil }
    func masterChain(for master: Master) -> OpaquePointer? { nil }
    func keyUnit(of insert: UUID, among inserts: [Insert]) -> Int32? { nil }
}

/// The running instances for a project's inserts and the chains built from them. One
/// host for playback; exports and measurements make their own, so two renders never
/// share a unit.
public final class InsertHost: ChainProvider, @unchecked Sendable {
    public let channels: Int
    public let sampleRate: Double
    public let outOfProcess: Bool

    private struct Entry {
        var instance: any InsertUnit
        var applied: Data?
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var chains: [UUID: (key: [String], chain: OpaquePointer)] = [:]
    private var failed: [UUID: PluginError] = [:]

    public init(channels: Int, sampleRate: Double, outOfProcess: Bool = false) {
        self.channels = channels
        self.sampleRate = sampleRate
        self.outOfProcess = outOfProcess
    }

    deinit { for c in chains.values { jm_chain_release(c.chain) } }

    /// A new host with every insert of `project` running.
    public static func make(for project: Project, outOfProcess: Bool = false) async -> InsertHost {
        let host = InsertHost(channels: project.channels, sampleRate: project.sampleRate, outOfProcess: outOfProcess)
        await host.sync(project)
        return host
    }

    /// `make(for:)` on this thread (background only).
    public static func makeBlocking(for project: Project, outOfProcess: Bool = false) -> InsertHost {
        let host = InsertHost(channels: project.channels, sampleRate: project.sampleRate, outOfProcess: outOfProcess)
        for insert in project.allInserts where !insert.bypass {
            do {
                let i = try InsertUnits.makeBlocking(insert.plugin, channels: project.channels, sampleRate: project.sampleRate,
                                                     state: insert.state, outOfProcess: outOfProcess)
                host.entries[insert.id] = Entry(instance: i, applied: insert.state)
            } catch {
                host.failed[insert.id] = error as? PluginError ?? .failed(error.localizedDescription)
            }
        }
        return host
    }

    /// Starts units for new inserts, drops removed ones and applies changed settings.
    /// Returns true when anything changed (the plan should be compiled again).
    @discardableResult
    public func sync(_ project: Project) async -> Bool {
        var changed = false
        let wanted = project.allInserts
        let ids = Set(wanted.map(\.id))
        lock.withLock {
            let before = entries.count + failed.count
            entries = entries.filter { ids.contains($0.key) }
            failed = failed.filter { ids.contains($0.key) }
            if entries.count + failed.count != before { changed = true }
        }
        for insert in wanted {
            let existing = lock.withLock { entries[insert.id] }
            if let existing {
                guard existing.applied != insert.state else { continue }
                // Settings that haven't been allowed aren't handed to a running plugin either (a step
                // back in a project's own history can ask for them): the unit goes, the reason stays.
                if let s = insert.state, InsertUnits.withheld?(insert.plugin, s) == true {
                    lock.withLock { entries[insert.id] = nil; failed[insert.id] = .withheld(insert.name) }
                    changed = true
                    continue
                }
                do {
                    if let s = insert.state { try existing.instance.apply(s) }
                    lock.withLock { entries[insert.id]?.applied = insert.state }
                    changed = true
                } catch let e as PluginError {
                    lock.withLock { failed[insert.id] = e }
                } catch {}
                continue
            }
            if let f = lock.withLock({ failed[insert.id] }) {
                // Withheld settings are tried again once they are allowed; other failures stay failures.
                guard case .withheld = f, !(insert.state.map { InsertUnits.withheld?(insert.plugin, $0) ?? false } ?? false) else { continue }
                lock.withLock { failed[insert.id] = nil }
            }
            if let s = insert.state, InsertUnits.withheld?(insert.plugin, s) == true {
                lock.withLock { failed[insert.id] = .withheld(insert.name) }
                changed = true
                continue
            }
            do {
                let instance = try await InsertUnits.make(insert.plugin, channels: channels, sampleRate: sampleRate,
                                                          state: insert.state, outOfProcess: outOfProcess)
                lock.withLock { entries[insert.id] = Entry(instance: instance, applied: insert.state) }
            } catch let e as PluginError {
                lock.withLock { failed[insert.id] = e }
            } catch {
                lock.withLock { failed[insert.id] = .failed(error.localizedDescription) }
            }
            changed = true
        }
        return changed
    }

    /// No units running and none failed.
    public var isEmpty: Bool { lock.withLock { entries.isEmpty && failed.isEmpty } }

    public func instance(_ insert: UUID) -> (any InsertUnit)? { lock.withLock { entries[insert]?.instance } }
    public func failure(_ insert: UUID) -> PluginError? { lock.withLock { failed[insert] } }

    /// True when every insert in `project` is running or has failed (nothing is pending).
    public func isReady(for project: Project) -> Bool {
        lock.withLock { project.allInserts.allSatisfy { entries[$0.id] != nil || failed[$0.id] != nil } }
    }

    /// Notes settings the unit already has (it changed them itself, e.g. in its window),
    /// so sync doesn't apply them again.
    public func markApplied(_ insert: UUID, state: Data?) { lock.withLock { entries[insert]?.applied = state } }

    /// The chain of the track's active inserts that are running, kept while nothing about
    /// it changes so playback carries on through edits elsewhere.
    @discardableResult
    public func attachChain(for track: Track, to plan: OpaquePointer, index: Int32) -> Int64? {
        lock.withLock {
            guard let chain = chainLocked(for: track.id, inserts: track.inserts) else { return nil }
            jm_plan_set_chain(plan, index, chain)
            return jm_chain_latency(chain)
        }
    }

    @discardableResult
    public func attachChain(for bus: Bus, to plan: OpaquePointer, index: Int32) -> Int64? {
        lock.withLock {
            guard let chain = chainLocked(for: bus.id, inserts: bus.inserts) else { return nil }
            jm_plan_set_bus_chain(plan, index, chain)
            return jm_chain_latency(chain)
        }
    }

    public func masterChain(for master: Master) -> OpaquePointer? {
        lock.withLock { chainLocked(for: Master.id, inserts: master.inserts) }
    }

    public func keyUnit(of insert: UUID, among inserts: [Insert]) -> Int32? {
        lock.withLock {
            // The chain holds the strip's inserts that aren't bypassed and are running, in order.
            let running = inserts.filter { !$0.bypass && entries[$0.id] != nil }
            guard let at = running.firstIndex(where: { $0.id == insert }), entries[insert]?.instance.hasKeyInput == true else { return nil }
            return Int32(at)
        }
    }

    /// The chain of a strip (a track or a bus, by its id).
    private func chainLocked(for strip: UUID, inserts: [Insert]) -> OpaquePointer? {
        do {
            let track = (id: strip, inserts: inserts)
            let active = track.inserts.filter { !$0.bypass }.compactMap { i in entries[i.id].map { (i.id, $0.instance) } }
            guard !active.isEmpty else {
                if let old = chains.removeValue(forKey: track.id) { jm_chain_release(old.chain) }
                return nil
            }
            let key = active.map { "\($0.0.uuidString):\($0.1.latency)" }
            if let c = chains[track.id], c.key == key { return c.chain }
            let tail = active.map(\.1.tail).reduce(0, +)
            let preroll = max(Int64(0.25 * sampleRate), min(tail, Int64(2 * sampleRate)))
            let chain = jm_chain_create(Int32(channels), preroll)
            for (_, instance) in active { jm_chain_add(chain, instance.unit, instance.latency) }
            if let old = chains[track.id] { jm_chain_release(old.chain) }
            chains[track.id] = (key, chain)
            return chain
        }
    }

    /// The last error a unit on the track returned while rendering, if any.
    public func renderStatus(track: UUID) -> OSStatus {
        lock.withLock { chains[track].map { jm_chain_status($0.chain) } ?? 0 }
    }
}

extension PlanCompiler {
    /// The mix as it's heard, inserts included, with units of its own: for exports and
    /// loudness measurements, which mustn't share units with playback. The plan keeps
    /// its units alive.
    public static func mix(_ project: Project, pool: SourcePool, outOfProcess: Bool = false, masterMargin: Double = Mixer.masterMargins[0]) async -> RenderPlan {
        guard project.hasActiveInserts else { return compile(project, pool: pool, masterMargin: masterMargin) }
        return compile(project, pool: pool, inserts: await InsertHost.make(for: project, outOfProcess: outOfProcess), masterMargin: masterMargin)
    }

    /// `mix` on this thread (background only).
    public static func mixBlocking(_ project: Project, pool: SourcePool, outOfProcess: Bool = false, masterMargin: Double = Mixer.masterMargins[0]) -> RenderPlan {
        guard project.hasActiveInserts else { return compile(project, pool: pool, masterMargin: masterMargin) }
        return compile(project, pool: pool, inserts: InsertHost.makeBlocking(for: project, outOfProcess: outOfProcess), masterMargin: masterMargin)
    }
}

extension Project {
    /// Any track has an insert that isn't bypassed.
    public var hasActiveInserts: Bool { allInserts.contains { !$0.bypass } }
}
