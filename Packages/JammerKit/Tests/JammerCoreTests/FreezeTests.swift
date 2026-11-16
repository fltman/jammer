import Foundation
import Testing
@testable import JammerCore

@Suite("Mixer: freezing a strip", .serialized)
struct FreezeTests {
    static let limiter = PluginID("aufx/lmtr/appl")!, lowpass = PluginID("aufx/lpas/appl")!
    /// The render a freeze uses: the copy's mix, with plugins of its own.
    static func freeze(_ p: Project, _ strip: UUID, pool: SourcePool, media: URL) throws -> Project {
        try p.freezing(strip, media: media) { context, range, write in
            let plan = PlanCompiler.compile(context, pool: pool, inserts: InsertHost.makeBlocking(for: context))
            try plan.render(range) { try write($0) }
        }
    }
    static func heard(_ p: Project, _ pool: SourcePool) -> [Float] {
        PlanCompiler.compile(p, pool: pool, inserts: InsertHost.makeBlocking(for: p)).render(from: 0, frames: Int(p.length))
    }
    static func db(_ a: [Float], _ b: [Float]) -> Double {
        var e = 0.0, r = 0.0
        for i in 0..<min(a.count, b.count) { e += Double(a[i] - b[i]) * Double(a[i] - b[i]); r += Double(b[i]) * Double(b[i]) }
        return 10 * log10(max(e, 1e-30) / max(r, 1e-30))
    }

    @Test("A frozen track sounds as it did, runs no plugins, keeps its fader, pan, mute and sends live, and thaws to exactly what it was")
    func track() async throws {
        let dir = TempDir()
        var (p, pool) = MixerTests.document()
        p.tracks[0].inserts = [Insert(plugin: Self.lowpass, name: "AULowpass"), Insert(plugin: Self.limiter, name: "AUPeakLimiter")]
        p.tracks[0].gainDB = -4
        let bus = try p.addBus(name: "Room")
        try p.setSend(from: p.tracks[0].id, to: bus.id, gainDB: -6)
        let id = p.tracks[0].id
        let live = Self.heard(p, pool)
        let frozen = try Self.freeze(p, id, pool: pool, media: dir.url)
        let record = try #require(frozen.tracks[0].frozen)
        #expect(frozen.usesMixer && frozen.sources.count == p.sources.count + 1 && record.start == 0 && record.madeFrom == p.content(of: id))
        // Underneath, nothing is changed: its clips and its plugins are what they were.
        #expect(frozen.tracks[0].clips == p.tracks[0].clips && frozen.tracks[0].inserts == p.tracks[0].inserts)
        // As played: one clip of the file, no plugins; and the mix is the live one.
        let played = frozen.played()
        #expect(played.tracks[0].inserts.isEmpty && played.tracks[0].clips.map(\.sourceID) == [record.sourceID] && !played.hasFreezes)
        #expect(Self.db(Self.heard(frozen, pool), live) < -90, "frozen against live: \(Self.db(Self.heard(frozen, pool), live)) dB")
        // The fader, the pan, the mute and the send are after the file: changed, they are as on the live track.
        var a = frozen, b = p
        for i in [0] { a.tracks[i].gainDB = 3; b.tracks[i].gainDB = 3; a.tracks[i].pan = -0.5; b.tracks[i].pan = -0.5 }
        try a.setSend(from: id, to: bus.id, gainDB: 0, pre: true)
        try b.setSend(from: id, to: bus.id, gainDB: 0, pre: true)
        #expect(p.frozenViolation(in: p) == nil && frozen.frozenViolation(in: a) == nil)
        #expect(Self.db(Self.heard(a, pool), Self.heard(b, pool)) < -90)
        a.tracks[0].isMuted = true; b.tracks[0].isMuted = true
        #expect(Self.db(Self.heard(a, pool), Self.heard(b, pool)) < -90)
        // What it was frozen from can't be changed under it: its clips, its plugins. Another track's can.
        var cut = frozen
        cut.tracks[0].clips[0].length -= 100
        #expect(frozen.frozenViolation(in: cut) == p.tracks[0].name)
        var bypassed = frozen
        bypassed.tracks[0].inserts[0].bypass = true
        #expect(frozen.frozenViolation(in: bypassed) == p.tracks[0].name)
        var other = frozen
        other.tracks[1].clips[0].length -= 100
        other.tracks[1].gainDB = -20
        #expect(frozen.frozenViolation(in: other) == nil)
        // Saved and opened: still frozen, the same file.
        let back = try JSONDecoder().decode(Project.self, from: try JSONEncoder().encode(frozen))
        #expect(back == frozen)
        // Frozen twice is refused; thawed, it is the project it was, and the file is no longer one of its sources.
        #expect(throws: FreezeError.self) { try Self.freeze(frozen, id, pool: pool, media: dir.url) }
        let thawed = try frozen.unfreezing(id)
        #expect(thawed == p)
        #expect(throws: FreezeError.self) { try p.unfreezing(id) }
        #expect(throws: FreezeError.self) { try p.unfreezing(UUID()) }
        // A track rendered by itself for a bounce or an analysis is its own sound, not the frozen file.
        var solo = frozen
        solo.withoutMixer()
        #expect(solo.tracks[0].frozen == nil)
    }

    @Test("A frozen bus plays its file in place of everything that fed it; what only fed it isn't worked out; a change upstream is refused")
    func bus() async throws {
        let dir = TempDir()
        var (p, pool) = MixerTests.document()
        let bus = try p.addBus(name: "Speech"), fx = try p.addBus(name: "FX")
        p.buses[0].inserts = [Insert(plugin: Self.limiter, name: "AUPeakLimiter")]
        p.buses[0].gainDB = -2
        p.tracks[0].inserts = [Insert(plugin: Self.lowpass, name: "AULowpass")]
        try p.setTrackRoute(p.tracks[0].id, output: .some(bus.id))        // only to the bus
        try p.setTrackRoute(p.tracks[1].id, output: .some(bus.id))        // to the bus, and by a send to FX
        try p.setSend(from: p.tracks[1].id, to: fx.id, gainDB: -3)
        let live = Self.heard(p, pool)
        let frozen = try Self.freeze(p, bus.id, pool: pool, media: dir.url)
        let record = try #require(frozen.buses[0].frozen)
        #expect(record.start == 0 && frozen.buses[0].inserts == p.buses[0].inserts)
        #expect(Self.db(Self.heard(frozen, pool), live) < -90, "frozen bus against live: \(Self.db(Self.heard(frozen, pool), live)) dB")
        // As played: track 0 fed only the bus, so it is muted and runs nothing; track 1 still plays for its send.
        let played = frozen.played()
        #expect(played.tracks[0].isMuted && played.tracks[0].inserts.isEmpty)
        #expect(!played.tracks[1].isMuted && played.tracks[1].output == Project.frozenSink && played.tracks[1].sends.map(\.to) == [fx.id])
        #expect(played.tracks.last?.output == bus.id && played.tracks.last?.clips.map(\.sourceID) == [record.sourceID] && played.buses[0].inserts.isEmpty)
        // The bus's own fader is live.
        var a = frozen, b = p
        a.buses[0].gainDB = -12; b.buses[0].gainDB = -12
        #expect(frozen.frozenViolation(in: a) == nil && Self.db(Self.heard(a, pool), Self.heard(b, pool)) < -90)
        // Upstream of it: a track's level, a clip, a route into it. All refused while it is frozen.
        var level = frozen
        level.tracks[0].gainDB = -6
        #expect(frozen.frozenViolation(in: level) == "Speech")
        var clip = frozen
        clip.tracks[1].clips[0].length -= 10
        #expect(frozen.frozenViolation(in: clip) == "Speech")
        var route = frozen
        try route.setTrackRoute(route.tracks[2].id, output: .some(bus.id))
        #expect(frozen.frozenViolation(in: route) == "Speech")
        // The third track never reached the bus: it can be changed.
        var free = frozen
        free.tracks[2].gainDB = -6
        #expect(frozen.frozenViolation(in: free) == nil)
        #expect(try frozen.unfreezing(bus.id) == p)
    }

    @Test("A track whose plugin listens to another track is frozen with what it heard, and the key's track can't then be changed under it")
    func keyed() async throws {
        #expect(KeyedGateAU.registered)
        let dir = TempDir()
        var (p, pool) = KeyedAUTests.document()
        p.tracks[0].inserts = [Insert(plugin: KeyedGateAU.plugin, name: "Gate")]
        try p.setKey(strip: p.tracks[0].id, insert: p.tracks[0].inserts[0].id, key: p.tracks[1].id)
        let live = Self.heard(p, pool)
        #expect(KeyedAUTests.gated(live) == [])
        let frozen = try Self.freeze(p, p.tracks[0].id, pool: pool, media: dir.url)
        let y = Self.heard(frozen, pool)
        #expect(KeyedAUTests.gated(y) == [], "the gate's frame isn't in the frozen file")
        #expect(frozen.played().tracks[0].inserts.isEmpty)
        var moved = frozen
        moved.tracks[1].clips[0].start += 10
        #expect(frozen.frozenViolation(in: moved) == p.tracks[0].name)
        var quieter = frozen
        quieter.tracks[1].gainDB = -6          // the key is taken after the fader
        #expect(frozen.frozenViolation(in: quieter) == p.tracks[0].name)
    }

    @Test("Nothing to freeze, a strip that isn't there, the master: refused in words")
    func refusals() throws {
        let dir = TempDir()
        var (p, pool) = MixerTests.document()
        p.tracks.append(Track(name: "Empty"))
        #expect(throws: FreezeError.nothing("Empty")) { try Self.freeze(p, p.tracks[3].id, pool: pool, media: dir.url) }
        #expect(throws: FreezeError.self) { try Self.freeze(p, UUID(), pool: pool, media: dir.url) }
        #expect(throws: FreezeError.self) { try Self.freeze(p, Master.id, pool: pool, media: dir.url) }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.url.path))?.isEmpty ?? true, "a refused freeze left a file")
    }
}
