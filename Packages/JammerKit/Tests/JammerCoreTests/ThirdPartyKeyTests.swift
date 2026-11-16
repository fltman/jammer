import AVFoundation
import AudioToolbox
import Foundation
import Testing
@testable import JammerCore

/// Sidechain keys against another vendor's plugin (docs/RELEASE.md, rehearsal item 7). The plugin is
/// not part of Jämmer, not in the repository and not installed on the Mac: it is built by itself
/// elsewhere, and this test is given the finished Audio Unit by path (`JAMMER_KEYED_AU`), loads it as a
/// host loads a plugin, and registers it in this test process only. Without the path, nothing runs.
@Suite("Sidechain: another vendor's Audio Unit", .serialized, .enabled(if: ProcessInfo.processInfo.environment["JAMMER_KEYED_AU"] != nil))
struct ThirdPartyKeyTests {
    /// Loads the component bundle and registers what its Info.plist says it is. Returns its id here.
    static let plugin: PluginID? = {
        guard let path = ProcessInfo.processInfo.environment["JAMMER_KEYED_AU"] else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let bundle = CFBundleCreate(nil, url as CFURL), CFBundleLoadExecutable(bundle),
              let info = NSDictionary(contentsOf: url.appending(path: "Contents/Info.plist")),
              let c = (info["AudioComponents"] as? [[String: Any]])?.first,
              let type = c["type"] as? String, let subtype = c["subtype"] as? String, let maker = c["manufacturer"] as? String,
              let factoryName = c["factoryFunction"] as? String,
              let pointer = CFBundleGetFunctionPointerForName(bundle, factoryName as CFString) else { return nil }
        func code(_ s: String) -> OSType { s.utf8.reduce(0) { $0 << 8 | OSType($1) } }
        var description = AudioComponentDescription(componentType: code(type), componentSubType: code(subtype), componentManufacturer: code(maker),
                                                    componentFlags: 0, componentFlagsMask: 0)
        let factory = unsafeBitCast(pointer, to: AudioComponentFactoryFunction.self)
        AudioComponentRegister(&description, (c["name"] as? String ?? "plugin") as CFString, UInt32(c["version"] as? Int ?? 1), factory)
        return PluginID("\(type)/\(subtype)/\(maker)")
    }()

    @Test("What the plugin is: its inputs and its parameters (printed, for writing the test that uses them)")
    func describe() async throws {
        let plugin = try #require(Self.plugin, "the Audio Unit at JAMMER_KEYED_AU couldn't be loaded")
        let unit = try await PluginInstance.make(plugin, channels: 2, sampleRate: 48_000)
        print("KEYED AU \(unit.displayName): hasKeyInput \(unit.hasKeyInput), refusal \(unit.keyRefusal ?? "none"), latency \(unit.latency) frames, in process \(unit.au.isLoadedInProcess)")
        for p in unit.parameters { print("KEYED AU   \(p.identifier) | \(p.name) | \(p.min)…\(p.max) | now \(p.value) | \(p.unit)") }
        #expect(unit.hasKeyInput)
    }

    static let n = 48_000 * 7 / 2
    /// A quiet steady tone on one track; on another a loud burst from 1.0 s to 2.0 s. In memory.
    static func document() -> (Project, SourcePool) {
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: Int64(n), chunks: [], bext: nil, ixml: nil, markers: [])
        let pool = SourcePool()
        let tone = SourceRef(name: "tone", path: "/dev/null", info: info), burst = SourceRef(name: "burst", path: "/dev/null", info: info)
        pool.register(tone.id, memory: (0..<n).flatMap { i -> [Float] in let v = Float(0.1 * sin(2 * .pi * 440 * Double(i) / 48_000)); return [v, v] }, channels: 2)
        pool.register(burst.id, memory: (0..<n).flatMap { i -> [Float] in
            let v = (48_000..<96_000).contains(i) ? Float(0.8 * sin(2 * .pi * 173 * Double(i) / 48_000)) : 0
            return [v, v]
        }, channels: 2)
        var p = Project(source: tone)
        _ = p.addTrack(source: burst, name: "Burst")
        return (p, pool)
    }
    /// The level (dB) of `x` (interleaved stereo) over a stretch given in seconds.
    static func level(_ x: [Float], _ from: Double, _ to: Double) -> Double {
        var e = 0.0
        let a = Int(from * 48_000), b = Int(to * 48_000)
        for i in (a * 2)..<(b * 2) { e += Double(x[i]) * Double(x[i]) }
        return 10 * log10(max(e / Double((b - a) * 2), 1e-20))
    }

    @Test("Keyed from another track, the compressor pulls the tone down while the burst sounds and not before; without the key, or with its external side-chain off, it doesn't")
    func keyed() async throws {
        let plugin = try #require(Self.plugin)
        var (p, pool) = Self.document()
        // The burst by itself, to take it out of every mix below: what is left is the tone as the compressor made it.
        var only = p
        only.tracks[0].isMuted = true
        let burst = PlanCompiler.compile(only, pool: pool).render(from: 0, frames: Self.n)
        func tone(_ project: Project) async -> [Float] {
            let host = await InsertHost.make(for: project)
            let y = PlanCompiler.compile(project, pool: pool, inserts: host).render(from: 0, frames: Self.n)
            return zip(y, burst).map { $0 - $1 }
        }
        // The plugin set to listen to its external side-chain, with a low threshold and a high ratio, by its own parameters.
        let unit = try await PluginInstance.make(plugin, channels: 2, sampleRate: 48_000)
        try unit.set("External Side", to: 1)
        try unit.set("Threshold (dB)", to: 0.25)
        try unit.set("Ratio", to: 0.9)
        p.tracks[0].inserts = [Insert(plugin: plugin, name: "Compressor", state: unit.captureState())]
        let insert = p.tracks[0].inserts[0].id
        // 1. External side-chain on, nothing keyed to it: its side-chain is silent, the tone is left alone.
        let unkeyed = await tone(p)
        let before = Self.level(unkeyed, 0.3, 0.9), during = Self.level(unkeyed, 1.3, 1.9)
        print(String(format: "KEYED AU no key: tone %.2f dB before, %.2f dB during the burst", before, during))
        #expect(abs(before - during) < 0.5)
        // 2. Keyed from the burst track.
        try p.setKey(strip: p.tracks[0].id, insert: insert, key: p.tracks[1].id)
        let keyed = await tone(p)
        let k0 = Self.level(keyed, 0.3, 0.9), early = Self.level(keyed, 0.90, 0.99), k1 = Self.level(keyed, 1.3, 1.9), after = Self.level(keyed, 2.9, 3.4)
        print(String(format: "KEYED AU keyed: tone %.2f dB before, %.2f dB just before the burst, %.2f dB during, %.2f dB a second after", k0, early, k1, after))
        #expect(k0 - k1 > 3, "the burst didn't pull the tone down: \(k0) → \(k1)")
        #expect(abs(early - k0) < 0.5, "pulled down before the burst began")
        #expect(abs(after - k0) < 1, "didn't come back after the burst")
        #expect(abs(k0 - before) < 0.5)
        // 3. The same key, but the plugin told to listen to its own input: the burst means nothing to it.
        try unit.set("External Side", to: 0)
        p.tracks[0].inserts[0].state = unit.captureState()
        let own = await tone(p)
        let o0 = Self.level(own, 0.3, 0.9), o1 = Self.level(own, 1.3, 1.9)
        print(String(format: "KEYED AU keyed but listening to itself: tone %.2f dB before, %.2f dB during", o0, o1))
        #expect(abs(o0 - o1) < 0.5)
        // 4. Keyed from a bus that the burst goes through, behind a plugin with latency on that bus: the same pull, on time.
        try unit.set("External Side", to: 1)
        p.tracks[0].inserts[0].state = unit.captureState()
        let bus = try p.addBus(name: "Key bus")
        try p.setTrackRoute(p.tracks[1].id, output: .some(bus.id))
        p.buses[0].inserts = [Insert(plugin: PluginID("aufx/lmtr/appl")!, name: "AUPeakLimiter")]
        try p.setKey(strip: p.tracks[0].id, insert: insert, key: bus.id)
        // (The burst now comes through the limiter; take what the bus really plays out of the mix.)
        var busOnly = p
        busOnly.tracks[0].isMuted = true
        let hostB = await InsertHost.make(for: busOnly)
        let throughBus = PlanCompiler.compile(busOnly, pool: pool, inserts: hostB).render(from: 0, frames: Self.n)
        let host = await InsertHost.make(for: p)
        let plan = PlanCompiler.compile(p, pool: pool, inserts: host)
        #expect(plan.keyCount == 1 && plan.totalLatency > 0)
        let viaBus = zip(plan.render(from: 0, frames: Self.n), throughBus).map { $0 - $1 }
        let b0 = Self.level(viaBus, 0.3, 0.9), bEarly = Self.level(viaBus, 0.90, 0.99), b1 = Self.level(viaBus, 1.3, 1.9)
        print(String(format: "KEYED AU keyed from a bus with a late plugin: tone %.2f dB before, %.2f dB just before, %.2f dB during", b0, bEarly, b1))
        #expect(b0 - b1 > 3 && abs(bEarly - b0) < 0.5)
    }
}
