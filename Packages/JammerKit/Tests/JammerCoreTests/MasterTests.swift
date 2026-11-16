import Foundation
import JammerEngine
import Testing
@testable import JammerCore

@Suite("Mixer: the master strip, with the limiter last")
struct MasterTests {
    static func peakDB(_ x: [Float]) -> Double {
        var m = Limiter.PeakMeter(channels: 2, sampleRate: 48_000)
        m.process(x)
        return m.peakDB
    }
    /// The document of the mixer tests, with every track turned up so the mix is well over −6 dBTP.
    static func loud() -> (Project, SourcePool) {
        var (p, pool) = MixerTests.document()
        for t in p.tracks.indices { p.tracks[t].gainDB = 12 }
        return (p, pool)
    }

    @Test("A master that does nothing is not saved and changes nothing; one that does makes the project a mixer project")
    func untouched() throws {
        var (p, pool) = MixerTests.document()
        let plain = MixerTests.render(p, pool)
        #expect(p.master.isDefault && !p.usesMixer)
        #expect(!String(decoding: try JSONEncoder().encode(p), as: UTF8.self).contains("master"))
        try p.setMaster(gainDB: -6)
        let json = String(decoding: try JSONEncoder().encode(p), as: UTF8.self)
        #expect(p.usesMixer && json.contains("\"formatVersion\":2") && json.contains("\"master\""))
        #expect(try JSONDecoder().decode(Project.self, from: Data(json.utf8)) == p)
        // The gain is on everything, once.
        let g = Float(dbToGain(-6)), y = MixerTests.render(p, pool)
        #expect(zip(y, plain).allSatisfy { abs($0 - $1 * g) < 1e-7 })
        // A copy made to render one track by itself has no master.
        var solo = p
        solo.withoutMixer()
        #expect(solo.master.isDefault && !solo.usesMixer)
        // Out of range, or not a number: refused, nothing changed.
        let before = p
        #expect(throws: Mixer.Failure.self) { try p.setMaster(gainDB: 40) }
        #expect(throws: Mixer.Failure.self) { try p.setMaster(limiter: .some(MasterLimiter(ceilingDB: 3))) }
        #expect(p == before)
    }

    @Test("A limiter that has nothing to do passes the mix through bit for bit and on the sample, and says how late it is inside")
    func idle() throws {
        var (p, pool) = MixerTests.document()
        let plain = MixerTests.render(p, pool)
        try p.setMaster(limiter: .some(MasterLimiter(ceilingDB: -1)))
        let plan = PlanCompiler.compile(p, pool: pool)
        // One of the limiter's pieces, its oversampler's reach, 5 ms of lookahead, and eight to spare.
        #expect(plan.masterLatency == 4_096 + 16 + 240 + 8 && plan.totalLatency == plan.masterLatency)
        #expect(plan.render(from: 0, frames: Int(p.length)) == plain)
        // From the middle too.
        #expect(plan.render(from: 20_000, frames: 5_000) == Array(plain[40_000..<50_000]))
    }

    @Test("A limiter with work to do holds the mix under its ceiling, is the limiter that `limit` uses, and comes out the same in blocks")
    func limiting() throws {
        var (p, pool) = Self.loud()
        let plain = MixerTests.render(p, pool)
        #expect(Self.peakDB(plain) > -3)
        try p.setMaster(limiter: .some(MasterLimiter(ceilingDB: -6)))
        let y = PlanCompiler.compile(p, pool: pool).render(from: 0, frames: Int(p.length))
        #expect(Self.peakDB(y) <= -6, "true peak \(Self.peakDB(y))")
        #expect(y.count == plain.count)
        // The same limiter run over the plain mix, aiming 0.1 dB under as playback does: the same audio
        // (to rounding: the two start their oversampler's pieces at different frames).
        var limiter = try Limiter.Processor(Limiter(ceilingDB: -6), channels: 2, sampleRate: 48_000, marginDB: Mixer.masterMargins[0])
        var want = limiter.process(plain)
        want += limiter.finish()
        var worst: Float = 0
        // (Not the last frames: there the offline limiter sees the end of the file and the master sees silence go on, which is the same thing.)
        for i in 0..<want.count { worst = max(worst, abs(y[i] - want[i])) }
        #expect(worst < 1e-4, "largest difference \(worst)")
        // In 512-frame blocks, as playback asks: the very same samples.
        let plan = PlanCompiler.compile(p, pool: pool)
        var blocks: [Float] = []
        var at = 0
        while at < Int(p.length) { let k = min(512, Int(p.length) - at); blocks += plan.render(from: Frame(at), frames: k); at += k }
        #expect(blocks == y)
        // Asked for from the middle, the limiter has run in over what came before: the same to well under a thousandth.
        let mid = PlanCompiler.compile(p, pool: pool).render(from: 30_000, frames: 8_000)
        var off: Float = 0
        for i in 0..<mid.count { off = max(off, abs(mid[i] - y[60_000 + i])) }
        #expect(off < 1e-3, "after a seek: \(off)")
        #expect(Self.peakDB(mid) <= -6 + 0.1)
        // With more margin the peak is lower still: what an export does when its file measured over.
        let lower = PlanCompiler.compile(p, pool: pool, masterMargin: 0.8).render(from: 0, frames: Int(p.length))
        #expect(Self.peakDB(lower) < Self.peakDB(y) - 0.5)
    }

    @Test("The limiter is last: after the master's gain, and after a bus with a late plugin, with everything still in time")
    func order() throws {
        var (p, pool) = Self.loud()
        try p.setMaster(gainDB: 6, limiter: .some(MasterLimiter(ceilingDB: -3)))
        let y = PlanCompiler.compile(p, pool: pool).render(from: 0, frames: Int(p.length))
        // Gain before the limiter: the ceiling holds. (The other way round it would be 6 dB over.)
        #expect(Self.peakDB(y) <= -3, "true peak \(Self.peakDB(y))")
        // A master limiter that does nothing, over a bus whose plugin is 300 frames late: the plain mix, bit for bit.
        var (q, pool2) = MixerTests.document()
        let plain = MixerTests.render(q, pool2)
        try q.setMaster(limiter: .some(MasterLimiter(ceilingDB: -1)))
        let plan = jm_plan_create(2, 48_000)
        defer { jm_plan_release(plan) }
        let a = MixerGraphTests.source(220), b = MixerGraphTests.source(331)
        defer { jm_source_release(a); jm_source_release(b) }
        let ta = MixerGraphTests.track(plan, a), _ = MixerGraphTests.track(plan, b)
        let bus = jm_plan_add_bus(plan, 1, false, 1, 1)
        jm_plan_set_track_route(plan, ta, bus, 1, 1)
        let late = MixerGraphTests.chain([DelayPlugin(latency: 300)])
        jm_plan_set_bus_chain(plan, bus, late)
        jm_chain_release(late)
        let limiter = try #require(MasterLimiterUnit.chain(Limiter(ceilingDB: -1), channels: 2, sampleRate: 48_000, marginDB: 0.1))
        jm_plan_set_master(plan, 1, nil, limiter)
        jm_chain_release(limiter)
        jm_plan_finalize(plan)
        #expect(jm_plan_total_latency(plan) == 300 + jm_plan_master_latency(plan))
        #expect(MixerGraphTests.render(plan) == MixerGraphTests.plain(a, b))
        _ = plain
    }
}
