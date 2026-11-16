import AVFoundation
import AudioToolbox
import Foundation
import Testing
@testable import JammerCore

@Suite("Sidechain: an Audio Unit's second input, fed by Jämmer", .serialized)
struct KeyedAUTests {
    static let n = 48_000, at = 12_345
    /// A steady 0.25 on one track, a click at `at` on another, in memory.
    static func document() -> (Project, SourcePool) {
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: Int64(n), chunks: [], bext: nil, ixml: nil, markers: [])
        let pool = SourcePool()
        let steady = SourceRef(name: "steady", path: "/dev/null", info: info), click = SourceRef(name: "click", path: "/dev/null", info: info)
        pool.register(steady.id, memory: [Float](repeating: 0.25, count: n * 2), channels: 2)
        var x = [Float](repeating: 0, count: n * 2)
        x[at * 2] = 0.5; x[at * 2 + 1] = 0.25
        pool.register(click.id, memory: x, channels: 2)
        var p = Project(source: steady)
        _ = p.addTrack(source: click, name: "Click")
        return (p, pool)
    }
    static func gated(_ y: [Float]) -> [Int] {
        var wrong: [Int] = []
        for i in 0..<n {
            let l: Float = (i == at ? 0.0625 : 0.25) + (i == at ? 0.5 : 0), r: Float = (i == at ? 0.0625 : 0.25) + (i == at ? 0.25 : 0)
            if abs(y[i * 2] - l) > 1e-7 || abs(y[i * 2 + 1] - r) > 1e-7 { wrong.append(i) }
        }
        return wrong
    }

    @Test("The test unit is seen to have a sidechain input, and a key from another track reaches it on the frame: through the model, the host and the engine")
    func keyed() async throws {
        #expect(KeyedGateAU.registered)
        var (p, pool) = Self.document()
        let plain = PlanCompiler.compile(p, pool: pool).render(from: 0, frames: Self.n)
        p.tracks[0].inserts = [Insert(plugin: KeyedGateAU.plugin, name: "Keyed Gate")]
        // Without a key the unit's second input is silent and nothing is gated.
        var host = await InsertHost.make(for: p)
        let unit = try #require(host.instance(p.tracks[0].inserts[0].id), "the test unit didn't start: \(String(describing: host.failure(p.tracks[0].inserts[0].id)))")
        #expect(unit.hasKeyInput && unit.keyRefusal == nil)
        #expect(PlanCompiler.compile(p, pool: pool, inserts: host).render(from: 0, frames: Self.n) == plain)
        // With the click track as its key: gated on that one frame.
        try p.setKey(strip: p.tracks[0].id, insert: p.tracks[0].inserts[0].id, key: p.tracks[1].id)
        #expect(p.usesMixer)
        host = await InsertHost.make(for: p)
        var plan = PlanCompiler.compile(p, pool: pool, inserts: host)
        #expect(plan.keyCount == 1)
        #expect(Self.gated(plan.render(from: 0, frames: Self.n)) == [])
        // Behind another plugin with latency (Apple's limiter, idle at this level), the key still lands on the frame.
        p.tracks[0].inserts.insert(Insert(plugin: PluginID("aufx/lmtr/appl")!, name: "AUPeakLimiter"), at: 0)
        host = await InsertHost.make(for: p)
        plan = PlanCompiler.compile(p, pool: pool, inserts: host)
        #expect(plan.keyCount == 1 && plan.totalLatency > 0)
        let y = plan.render(from: 0, frames: Self.n)
        // (The limiter is not bit-transparent; the gate's frame is what is looked at.)
        #expect(abs(y[Self.at * 2] - (0.0625 + 0.5)) < 1e-3 && abs(y[(Self.at - 1) * 2] - 0.25) < 1e-3 && abs(y[(Self.at + 1) * 2] - 0.25) < 1e-3,
                "\(y[(Self.at - 1) * 2]) \(y[Self.at * 2]) \(y[(Self.at + 1) * 2])")
        // Saved and opened, the key is still there; taken away, the mix is the plain one again.
        let back = try JSONDecoder().decode(Project.self, from: try JSONEncoder().encode(p))
        #expect(back.tracks[0].inserts[1].key == p.tracks[1].id)
        p.tracks[0].inserts.remove(at: 0)
        try p.setKey(strip: p.tracks[0].id, insert: p.tracks[0].inserts[0].id, key: nil)
        host = await InsertHost.make(for: p)
        #expect(PlanCompiler.compile(p, pool: pool, inserts: host).render(from: 0, frames: Self.n) == plain)
    }

    @Test("A plugin without a sidechain input says so; keys that would loop are refused where they are set, and so are routes that would close one")
    func refusals() async throws {
        var (p, _) = Self.document()
        p.tracks[0].inserts = [Insert(plugin: PluginID("aufx/lpas/appl")!, name: "AULowpass")]
        let host = await InsertHost.make(for: p)
        let unit = try #require(host.instance(p.tracks[0].inserts[0].id))
        #expect(!unit.hasKeyInput && unit.keyRefusal == nil)
        let a = p.tracks[0].id, k = p.tracks[1].id, ins = p.tracks[0].inserts[0].id
        let bus = try p.addBus(name: "Bus")
        try p.setTrackRoute(a, output: .some(bus.id))
        // From itself, from a strip that isn't there, from the bus it feeds: refused, nothing changed.
        let before = p
        #expect(throws: Mixer.Failure.self) { try p.setKey(strip: a, insert: ins, key: a) }
        #expect(throws: Mixer.Failure.self) { try p.setKey(strip: a, insert: ins, key: UUID()) }
        #expect(throws: Mixer.Failure.self) { try p.setKey(strip: a, insert: ins, key: bus.id) }
        #expect(throws: Mixer.Failure.self) { try p.setKey(strip: Master.id, insert: ins, key: k) }
        #expect(p == before)
        // Keyed from the click track; then the click track may not be sent to… nothing here feeds back yet.
        try p.setKey(strip: a, insert: ins, key: k)
        // A second bus that listens (by a plugin's key) to the first, and the first then routed into it… no loop;
        // but routing the track to a bus that the key's source reaches through is fine too. The loop: the key's
        // source fed by the listener. The click track's plugin keyed from the bus that A feeds is allowed (no loop),
        // and then A's key from the click track already exists, so a key on the click track from A's bus closes it.
        p.tracks[1].inserts = [Insert(plugin: KeyedGateAU.plugin, name: "Keyed Gate")]
        #expect(throws: Mixer.Failure.self) { try p.setKey(strip: k, insert: p.tracks[1].inserts[0].id, key: bus.id) }
        // And a route that would close one: A listens to a second bus; A may then not be sent to that bus.
        let other = try p.addBus(name: "Other")
        try p.setKey(strip: a, insert: ins, key: other.id)
        let kept = p
        #expect(throws: Mixer.Failure.self) { try p.setSend(from: a, to: other.id) }
        #expect(throws: Mixer.Failure.self) { try p.setTrackRoute(a, output: .some(other.id)) }
        #expect(throws: Mixer.Failure.self) { try p.setBus(bus.id, output: .some(other.id)) }
        #expect(p == kept)
        // Removing the bus takes the key from it away.
        try p.removeBus(other.id)
        #expect(p.tracks[0].inserts[0].key == nil)
        // A hostile file: a key from nowhere, and two strips listening to each other.
        var hostile = p
        hostile.tracks[0].inserts[0].key = UUID()
        hostile.tracks[1].inserts[0].key = a
        var loop = p
        loop.tracks[0].inserts[0].key = k
        loop.tracks[1].inserts[0].key = a
        let (mended, notes) = try ProjectPackage.decodeChecked(try ProjectPackage.encode(hostile))
        #expect(mended.tracks[0].inserts[0].key == nil && mended.tracks[1].inserts[0].key == a && notes.contains { $0.contains("without that key") }, "\(notes)")
        let (cut, _) = try ProjectPackage.decodeChecked(try ProjectPackage.encode(loop))
        #expect(!cut.hasKeyLoop && (cut.tracks[0].inserts[0].key == nil) != (cut.tracks[1].inserts[0].key == nil))
    }

    @Test("Soloing the track that is gated, or exporting it alone, keeps its key: the click track is not heard, and still gates")
    func soloKeepsTheKey() async throws {
        #expect(KeyedGateAU.registered)
        var (p, pool) = Self.document()
        p.tracks[0].inserts = [Insert(plugin: KeyedGateAU.plugin, name: "Keyed Gate")]
        try p.setKey(strip: p.tracks[0].id, insert: p.tracks[0].inserts[0].id, key: p.tracks[1].id)
        func heard(_ q: Project) async -> [Float] {
            let host = await InsertHost.make(for: q)
            return PlanCompiler.compile(q, pool: pool, inserts: host).render(from: 0, frames: Self.n)
        }
        // The steady track alone: 0.25 everywhere, a quarter of it on the click's frame, and no click.
        for alone in [p.listening(solo: [p.tracks[0].id]), p.only(tracks: [p.tracks[0].id])] {
            let y = await heard(alone)
            var wrong = 0
            for i in 0..<Self.n where abs(y[i * 2] - (i == Self.at ? 0.0625 : 0.25)) > 1e-7 || abs(y[i * 2 + 1] - (i == Self.at ? 0.0625 : 0.25)) > 1e-7 { wrong += 1 }
            #expect(wrong == 0, "\(wrong) frames wrong")
        }
        // The click track alone is just the click; and a click track the document has muted is a silent key, solo or not.
        let click = await heard(p.only(tracks: [p.tracks[1].id]))
        #expect(click[Self.at * 2] == 0.5 && click.filter { $0 != 0 }.count == 2)
        p.tracks[1].isMuted = true
        let ungated = await heard(p.listening(solo: [p.tracks[0].id]))
        let all = ungated.allSatisfy { $0 == 0.25 }
        #expect(all)
    }
}
