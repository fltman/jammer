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
