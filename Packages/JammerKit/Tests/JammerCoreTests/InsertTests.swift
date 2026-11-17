import Foundation
import Testing
@testable import JammerCore

/// Audio Unit inserts, tested with Apple's built-in effects (always installed).
@Suite("Inserts", .serialized)
struct InsertTests {
    let sr = 48_000.0
    static let limiter = PluginID("aufx/lmtr/appl")!
    static let lowpass = PluginID("aufx/lpas/appl")!

    private func project(_ dir: TempDir, seconds: Double = 3, level: Float = 0.03) throws -> (Project, SourcePool) {
        let x = noise(count: Int(sr * seconds) * 2, seed: 7).map { $0 * level }
        let url = dir.file("n.wav")
        try writeWAV(x, to: url)
        return (Project(source: SourceRef(name: "n", path: url.path, info: try AudioFileReader.info(at: url))), SourcePool())
    }

    private func db(_ a: [Float], _ b: [Float]) -> Double {
        var e = 0.0, r = 0.0
        for i in 0..<min(a.count, b.count) { e += Double(a[i] - b[i]) * Double(a[i] - b[i]); r += Double(b[i]) * Double(b[i]) }
        return 10 * log10(max(e, 1e-30) / max(r, 1e-30))
    }

    @Test("Apple's effects are in the catalogue; ids round-trip")
    func catalogue() throws {
        let list = PluginCatalog.effects()
        #expect(list.contains { $0.id == Self.limiter })
        #expect(PluginCatalog.find("AUPeakLimiter", in: list)?.id == Self.limiter)
        #expect(PluginCatalog.find("aufx/lpas/appl", in: list)?.id == Self.lowpass)
        #expect(Self.limiter.description == "aufx/lmtr/appl")
        let data = try JSONEncoder().encode(Insert(plugin: Self.limiter, name: "AUPeakLimiter"))
        #expect(try JSONDecoder().decode(Insert.self, from: data).plugin == Self.limiter)
    }

    @Test("Old documents without inserts still open; a track without inserts writes no key")
    func coding() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"A","clips":[],"gainDB":0,"isMuted":false}"#
        let t = try JSONDecoder().decode(Track.self, from: Data(json.utf8))
        #expect(t.inserts.isEmpty)
        #expect(!String(decoding: try JSONEncoder().encode(t), as: UTF8.self).contains("inserts"))
    }

    @Test("A bypassed insert, or none, leaves the mix bit for bit")
    func bypass() async throws {
        let dir = TempDir()
        var (p, pool) = try project(dir)
        let dry = PlanCompiler.compile(p, pool: pool).render(from: 0, frames: Int(p.length))
        p.tracks[0].inserts = [Insert(plugin: Self.lowpass, name: "AULowpass", bypass: true)]
        let host = await InsertHost.make(for: p)
        #expect(host.instance(p.tracks[0].inserts[0].id) != nil)
        let wet = PlanCompiler.compile(p, pool: pool, inserts: host).render(from: 0, frames: Int(p.length))
        #expect(wet == dry)
    }

    @Test("A unit's latency is compensated: a limiter that doesn't limit lines up with the dry track")
    func latency() async throws {
        let dir = TempDir()
        var (p, pool) = try project(dir)
        let dry = PlanCompiler.compile(p, pool: pool).render(from: 0, frames: Int(p.length))
        p.tracks[0].inserts = [Insert(plugin: Self.limiter, name: "AUPeakLimiter")]
        let host = await InsertHost.make(for: p)
        let unit = try #require(host.instance(p.tracks[0].inserts[0].id))
        #expect(unit.latency > 0, "AUPeakLimiter reports its look-ahead")
        let wet = PlanCompiler.compile(p, pool: pool, inserts: host).render(from: 0, frames: Int(p.length))
        // Best lag by cross-correlation over the middle second (left channel).
        var best = (lag: 0, c: -Double.infinity)
        for lag in -64...64 {
            var c = 0.0
            for i in stride(from: Int(sr), to: Int(sr) * 2, by: 1) { c += Double(wet[(i + lag) * 2]) * Double(dry[i * 2]) }
            if c > best.c { best = (lag, c) }
        }
        #expect(best.lag == 0, "latency \(unit.latency) frames, best lag \(best.lag)")
        let a = Array(wet[Int(sr) * 2..<Int(sr) * 4]), b = Array(dry[Int(sr) * 2..<Int(sr) * 4])
        #expect(db(a, b) < -40, "residual \(db(a, b)) dB")
    }

    /// A real plugin with look-ahead (Apple's limiter, not limiting at this level) on a BUS: the bus is
    /// then late by the plugin's latency, and the mixer delays the other paths so that everything still
    /// meets on the sample. A second track that goes straight out is the witness.
    @Test("A plugin's latency on a bus is compensated across the mixer: the mix lines up with the plain mix")
    func busLatency() async throws {
        let dir = TempDir()
        var (p, pool) = try project(dir)
        // The same file on a second track, later on the timeline, straight to the output.
        let again = p.sources[0]
        p.tracks.append(Track(name: "B", clips: [Clip(sourceID: again.id, sourceStart: 0, start: Frame(sr / 2), length: again.info.frames - Frame(sr))]))
        let plain = PlanCompiler.compile(p, pool: pool).render(from: 0, frames: Int(p.length))
        let bus = try p.addBus(name: "Speech")
        try p.setTrackRoute(p.tracks[0].id, output: .some(bus.id))
        // Through the bus without a plugin: the plain mix, bit for bit.
        #expect(PlanCompiler.compile(p, pool: pool).render(from: 0, frames: Int(p.length)) == plain)
        p.buses[0].inserts = [Insert(plugin: Self.limiter, name: "AUPeakLimiter")]
        #expect(p.hasActiveInserts && p.allInserts.count == 1)
        let host = await InsertHost.make(for: p)
        let unit = try #require(host.instance(p.buses[0].inserts[0].id))
        #expect(unit.latency > 0)
        let plan = PlanCompiler.compile(p, pool: pool, inserts: host)
        #expect(plan.totalLatency == unit.latency && plan.compensation(bus: false, index: 1) == unit.latency && plan.compensation(bus: false, index: 0) == 0)
        let wet = plan.render(from: 0, frames: Int(p.length))
        var best = (lag: 0, c: -Double.infinity)
        for lag in -64...64 {
            var c = 0.0
            for i in stride(from: Int(sr), to: Int(sr) * 2, by: 1) { c += Double(wet[(i + lag) * 2]) * Double(plain[i * 2]) }
            if c > best.c { best = (lag, c) }
        }
        #expect(best.lag == 0, "latency \(unit.latency) frames, best lag \(best.lag)")
        let a = Array(wet[Int(sr) * 2..<Int(sr) * 4]), b = Array(plain[Int(sr) * 2..<Int(sr) * 4])
        #expect(db(a, b) < -40, "residual \(db(a, b)) dB")
        // Saved and opened again, the bus still has its plugin; without one the key isn't written.
        let back = try JSONDecoder().decode(Project.self, from: try JSONEncoder().encode(p))
        #expect(back.buses[0].inserts.map(\.name) == ["AUPeakLimiter"])
        var bare = p
        bare.buses[0].inserts = []
        #expect(!String(decoding: try JSONEncoder().encode(bare.buses), as: UTF8.self).contains("inserts"))
        // The same in blocks, as playback asks.
        let host2 = await InsertHost.make(for: p)
        let plan2 = PlanCompiler.compile(p, pool: pool, inserts: host2)
        var blocks: [Float] = []
        var at = 0
        while at < Int(p.length) { let k = min(512, Int(p.length) - at); blocks += plan2.render(from: Frame(at), frames: k); at += k }
        #expect(db(blocks, wet) < -100, "blocks against one piece: \(db(blocks, wet)) dB")
    }

    @Test("A lane on an Audio Unit's parameter: Apple's low-pass closed from 20 kHz to 300 Hz over three seconds makes the noise fall away as it plays, the same from a seek, and the lane is refused where it can't be set")
    func parameterLane() async throws {
        let dir = TempDir()
        var (p, pool) = try project(dir, level: 0.3)
        p.tracks[0].inserts = [Insert(plugin: Self.lowpass, name: "AULowpass")]
        let insert = p.tracks[0].inserts[0].id, track = p.tracks[0].id
        let host = await InsertHost.make(for: p)
        let unit = try #require(host.instance(insert))
        let cutoff = try #require(unit.parameters.first)        // the cutoff is the low-pass's first parameter
        #expect(unit.address(of: cutoff.identifier) != nil)
        let rms = { (x: ArraySlice<Float>) in (x.reduce(0.0) { $0 + Double($1 * $1) } / Double(x.count)).squareRoot() }
        // Open all the way: what the lane starts from.
        try unit.set(cutoff.identifier, to: 20_000)
        let open = PlanCompiler.compile(p, pool: pool, inserts: host).render(from: 0, frames: Int(p.length))
        // The lane: 20 kHz at the start, 300 Hz at the end.
        try p.setAutomation(strip: track, param: .plugin, insert: insert, parameter: cutoff.identifier, values: cutoff.min...cutoff.max,
                            points: [AutomationPoint(frame: 0, value: 20_000), AutomationPoint(frame: p.length, value: 300)])
        #expect(p.pluginLanes(of: track).count == 1 && p.usesAutomation)
        let plan = PlanCompiler.compile(p, pool: pool, inserts: host)
        let closing = plan.render(from: 0, frames: Int(p.length))
        let half = Int(sr * 0.5) * 2
        #expect(rms(closing[0..<half]) > rms(open[0..<half]) * 0.8, "the first half second is still nearly open")
        #expect(rms(closing[(closing.count - half)...]) < rms(open[(open.count - half)...]) * 0.45, "the last half second is closed down (from about 3.6 kHz to 300 Hz: under a third of the open level)")
        // Falling all the way: each second quieter than the one before.
        let second = Int(sr) * 2
        #expect(rms(closing[second..<(2 * second)]) < rms(closing[0..<second]) && rms(closing[(2 * second)..<(3 * second)]) < rms(closing[second..<(2 * second)]))
        // From a seek: the parameter is where the lane has it there, whatever the plugin was left at.
        let at = Int(sr * 2)
        let seeked = plan.render(from: Frame(at), frames: Int(sr * 0.9))
        #expect(db(seeked, Array(closing[(at * 2)..<((at + Int(sr * 0.9)) * 2)])) < -60, "after a seek: \(db(seeked, Array(closing[(at * 2)..<((at + Int(sr * 0.9)) * 2)]))) dB")
        // Switched off, the lane is kept and not heard; a lane for a plugin that isn't on the strip, or outside the parameter's range, is refused.
        try p.setAutomation(strip: track, param: .plugin, insert: insert, parameter: cutoff.identifier, points: p.pluginLanes(of: track)[0].points, enabled: false)
        #expect(p.pluginLanes(of: track).isEmpty && p.lane(strip: track, param: .plugin, insert: insert, parameter: cutoff.identifier) != nil)
        #expect(throws: Automation.Failure.noInsert) { try p.setAutomation(strip: track, param: .plugin, insert: UUID(), parameter: "0", points: [AutomationPoint(frame: 0, value: 1)]) }
        #expect(throws: Automation.Failure.self) {
            try p.setAutomation(strip: track, param: .plugin, insert: insert, parameter: cutoff.identifier, values: cutoff.min...cutoff.max, points: [AutomationPoint(frame: 0, value: 1e9)])
        }
        // The plugin taken off the strip: its lane is no longer a lane of the project (and isn't saved).
        p.tracks[0].inserts = []
        #expect(p.liveLanes.isEmpty)
    }

    @Test("Seeking pre-rolls, and the block size doesn't change the output")
    func seekAndBlocks() async throws {
        let dir = TempDir()
        var (p, pool) = try project(dir, level: 0.3)
        p.tracks[0].inserts = [Insert(plugin: Self.lowpass, name: "AULowpass")]
        let host = await InsertHost.make(for: p)
        let unit = try #require(host.instance(p.tracks[0].inserts[0].id))
        try unit.set("0", to: 800)
        let plan = PlanCompiler.compile(p, pool: pool, inserts: host)
        let whole = plan.render(from: 0, frames: Int(p.length))
        // Lowpassed: much quieter than the white noise that went in.
        let dry = PlanCompiler.compile(p, pool: pool).render(from: 0, frames: Int(p.length))
        let rms = { (x: [Float]) in (x.reduce(0.0) { $0 + Double($1 * $1) } / Double(x.count)).squareRoot() }
        #expect(rms(whole) < rms(dry) * 0.4)
        // From a seek point: within a whisker of the continuous render.
        let at = Int(sr * 1.3)
        let seeked = plan.render(from: Frame(at), frames: Int(sr))
        let ref = Array(whole[(at * 2)..<((at + Int(sr)) * 2)])
        #expect(db(seeked, ref) < -90, "after seek: \(db(seeked, ref)) dB")
        // Same start, different block sizes: identical.
        var blocks: [Float] = []
        var f = Frame(at)
        for n in [1_000, 37, 4_096, 511, 65_536] where f < Frame(at + Int(sr)) {
            let k = min(n, at + Int(sr) - Int(f))
            blocks += plan.render(from: f, frames: k)
            f += Frame(k)
        }
        let again = plan.render(from: Frame(at), frames: Int(sr))
        #expect(blocks.count == again.count)
        #expect(blocks == again)
    }

    @Test("Safe mode (out of process) and the export mix sound the same as playback")
    func safeModeAndMix() async throws {
        let dir = TempDir()
        var (p, pool) = try project(dir, level: 0.5)
        p.tracks[0].inserts = [Insert(plugin: Self.limiter, name: "AUPeakLimiter")]
        let live = await InsertHost.make(for: p)
        let a = PlanCompiler.compile(p, pool: pool, inserts: live).render(from: 0, frames: Int(p.length))
        let b = await PlanCompiler.mix(p, pool: pool).render(from: 0, frames: Int(p.length))
        #expect(a == b)
        let c = await PlanCompiler.mix(p, pool: pool, outOfProcess: true).render(from: 0, frames: Int(p.length))
        #expect(db(c, a) < -120, "out of process: \(db(c, a)) dB")
        // It limits: the peaks come down from the 0.5 noise.
        #expect(a.map(abs).max()! < 0.5)
    }

    @Test("Settings round-trip through the saved state; out-of-range values are refused")
    func state() async throws {
        let unit = try await PluginInstance.make(Self.lowpass, channels: 2, sampleRate: sr)
        try unit.set("global.0", to: 1_234)
        #expect(unit.parameters.first?.name == "Cutoff Frequency" && unit.parameters.first?.unit == "Hz")
        #expect(throws: PluginError.self) { try unit.set("0", to: 1e9) }
        #expect(throws: PluginError.self) { try unit.set("no such", to: 1) }
        let state = try #require(unit.captureState())
        let other = try await PluginInstance.make(Self.lowpass, channels: 2, sampleRate: sr, state: state)
        let v = try #require(other.parameters.first { $0.identifier == "global.0" }?.value)
        #expect(abs(v - 1_234) < 0.01)
    }

    /// The settings this suite's gate withholds. Other tests' settings never match (the cutoff is this test's own).
    static let held = Held()
    final class Held: @unchecked Sendable {
        private let lock = NSLock()
        private var states: Set<Data> = []
        func set(_ s: Set<Data>) { lock.withLock { states = s } }
        func contains(_ d: Data) -> Bool { lock.withLock { states.contains(d) } }
    }

    @Test("Settings from elsewhere that the user allowed load only out of process (Anders, 2026-11-18): the Audio Unit runs in a process of its own with them, in its own process with settings made here, and in Safe Mode always out")
    func confinedSettings() async throws {
        let maker = try await PluginInstance.make(Self.lowpass, channels: 2, sampleRate: sr)
        try maker.set("global.0", to: 317.5)
        let foreign = try #require(maker.captureState())
        try maker.set("global.0", to: 9_871.5)
        let own = try #require(maker.captureState())
        InsertUnits.confined = { _, state in Self.held.contains(state) }
        Self.held.set([foreign])
        defer { Self.held.set([]); InsertUnits.confined = nil }
        #expect(InsertUnits.runsOutOfProcess(Self.lowpass, state: foreign, safeMode: false))
        #expect(!InsertUnits.runsOutOfProcess(Self.lowpass, state: own, safeMode: false) && !InsertUnits.runsOutOfProcess(Self.lowpass, state: nil, safeMode: false))
        #expect(InsertUnits.runsOutOfProcess(Self.lowpass, state: own, safeMode: true))
        let out = try #require(try await InsertUnits.make(Self.lowpass, channels: 2, sampleRate: 48_000, state: foreign) as? PluginInstance)
        #expect(!out.avUnit.auAudioUnit.isLoadedInProcess, "settings from elsewhere: a process of its own")
        #expect(abs((out.parameters.first { $0.identifier == "global.0" }?.value ?? 0) - 317.5) < 0.01, "with those settings")
        let here = try #require(try await InsertUnits.make(Self.lowpass, channels: 2, sampleRate: 48_000, state: own) as? PluginInstance)
        #expect(here.avUnit.auAudioUnit.isLoadedInProcess, "settings made here: in Jämmer's process, as before")
        let blocking = try #require(try InsertUnits.makeBlocking(Self.lowpass, channels: 2, sampleRate: 48_000, state: foreign) as? PluginInstance)
        #expect(!blocking.avUnit.auAudioUnit.isLoadedInProcess)
    }

    @Test("Settings that haven't been allowed are not loaded into a plugin: not at the start, not into a running one, until they are allowed")
    func withheldSettings() async throws {
        let dir = TempDir()
        var (p, pool) = try project(dir)
        let dry = PlanCompiler.compile(p, pool: pool).render(from: 0, frames: Int(p.length))
        // Settings as a project from elsewhere would bring them: a low-pass at 317.5 Hz.
        let maker = try await PluginInstance.make(Self.lowpass, channels: 2, sampleRate: sr)
        try maker.set("global.0", to: 317.5)
        let foreign = try #require(maker.captureState())
        try maker.set("global.0", to: 9_871.5)
        let own = try #require(maker.captureState())
        InsertUnits.withheld = { _, state in Self.held.contains(state) }
        Self.held.set([foreign])
        defer { Self.held.set([]) }
        p.tracks[0].inserts = [Insert(plugin: Self.lowpass, name: "AULowpass", state: foreign)]
        let id = p.tracks[0].inserts[0].id
        // Not started; the reason is there for the app and for agents; the track plays without it.
        let host = await InsertHost.make(for: p)
        #expect(host.instance(id) == nil && host.failure(id) == .withheld("AULowpass") && host.failure(id)?.reason == "plugin_settings_withheld")
        #expect(PlanCompiler.compile(p, pool: pool, inserts: host).render(from: 0, frames: Int(p.length)) == dry)
        #expect(InsertHost.makeBlocking(for: p).failure(id) != nil)
        await #expect(throws: PluginError.withheld(Self.lowpass.description)) { try await InsertUnits.make(Self.lowpass, channels: 2, sampleRate: 48_000, state: foreign) }
        // Asked again, still no. Allowed: it starts, with those settings.
        #expect(await host.sync(p) == false && host.instance(id) == nil)
        Self.held.set([])
        #expect(await host.sync(p) == true)
        let unit = try #require(host.instance(id))
        #expect(abs((unit.parameters.first { $0.identifier == "global.0" }?.value ?? 0) - 317.5) < 0.01 && host.failure(id) == nil)
        #expect(PlanCompiler.compile(p, pool: pool, inserts: host).render(from: 0, frames: Int(p.length)) != dry)
        // A running plugin isn't handed settings that aren't allowed either: it is stopped instead.
        var q = p
        q.tracks[0].inserts[0].state = own
        #expect(await host.sync(q) == true && host.instance(id) != nil)
        Self.held.set([foreign])
        #expect(await host.sync(p) == true && host.instance(id) == nil && host.failure(id) == .withheld("AULowpass"))
        // Settings made here (or no settings at all) are never in question.
        #expect(await host.sync(q) == true && host.instance(id) != nil)
        var plain = p
        plain.tracks[0].inserts = [Insert(plugin: Self.lowpass, name: "AULowpass")]
        #expect(await InsertHost.make(for: plain).instance(plain.tracks[0].inserts[0].id) != nil)
    }

    @Test("A unit that isn't installed fails with plugin_not_found")
    func missing() async throws {
        await #expect(throws: PluginError.self) { try await PluginInstance.make(PluginID("aufx/zzzz/zzzz")!, channels: 2, sampleRate: 48_000) }
        var p = Project(sampleRate: sr, channels: 2)
        p.tracks = [Track(name: "A", inserts: [Insert(plugin: PluginID("aufx/zzzz/zzzz")!, name: "Nope")])]
        let host = await InsertHost.make(for: p)
        #expect(host.failure(p.tracks[0].inserts[0].id)?.reason == "plugin_not_found")
        #expect(host.isReady(for: p))
    }
}
