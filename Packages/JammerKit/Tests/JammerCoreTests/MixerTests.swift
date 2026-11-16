import Foundation
import JammerEngine
import Testing
@testable import JammerCore

@Suite("Mixer: buses, routing and pan")
struct MixerTests {
    static let n = 48_000
    /// Three stereo tracks with different tones; left and right differ, so a swapped or summed channel shows.
    static func document(channels: Int = 2) -> (Project, SourcePool) {
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: channels, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: Int64(n), chunks: [], bext: nil, ixml: nil, markers: [])
        let pool = SourcePool()
        var p: Project?
        for (k, hz) in [220.0, 331, 517].enumerated() {
            let src = SourceRef(name: "s\(k)", path: "/dev/null", info: info)
            pool.register(src.id, memory: (0..<n).flatMap { i -> [Float] in
                let v = Float(0.1 * sin(2 * .pi * hz * Double(i) / 48_000))
                return channels == 2 ? [v, v * 0.5] : [v]
            }, channels: channels)
            if p == nil { p = Project(source: src) } else { _ = p!.addTrack(source: src, name: "t\(k)") }
        }
        return (p!, pool)
    }
    static func render(_ p: Project, _ pool: SourcePool) -> [Float] { PlanCompiler.compile(p, pool: pool).render(from: 0, frames: Int(p.length)) }

    @Test("A project that doesn't use the mixer is the file and the sound it always was")
    func untouched() throws {
        let (p, pool) = Self.document()
        #expect(!p.usesMixer)
        let json = String(decoding: try JSONEncoder().encode(p), as: UTF8.self)
        #expect(json.contains("\"formatVersion\":1") && !json.contains("\"buses\"") && !json.contains("\"pan\"") && !json.contains("\"output\""))
        // A file from before the mixer has none of the fields and opens to the same project.
        #expect(try JSONDecoder().decode(Project.self, from: Data(json.utf8)) == p)
        // Routed through a bus at 0 dB, centre: the same samples, bit for bit.
        var q = p
        let bus = try q.addBus(name: "Speech")
        for t in q.tracks { try q.setTrackRoute(t.id, output: .some(bus.id)) }
        #expect(q.usesMixer && Self.render(q, pool) == Self.render(p, pool))
    }

    @Test("Bus gain, mute and nesting; a track outside the bus is not touched")
    func buses() throws {
        var (p, pool) = Self.document()
        let dry = Self.render(p, pool)
        let a = try p.addBus(name: "A"), b = try p.addBus(name: "B")
        try p.setBus(a.id, gainDB: -6, output: .some(b.id))
        try p.setBus(b.id, gainDB: -6)
        try p.setTrackRoute(p.tracks[0].id, output: .some(a.id))
        // Track 0 goes through A and B (−12 dB together); tracks 1 and 2 go straight out.
        var only0 = p; only0.tracks[1].isMuted = true; only0.tracks[2].isMuted = true
        let alone = Self.render(only0, pool), want = pow(10, -12.0 / 20)
        let (q0, pool0) = Self.document()
        var solo = q0; solo.tracks[1].isMuted = true; solo.tracks[2].isMuted = true
        let ref = Self.render(solo, pool0)
        var worst: Float = 0
        for i in 0..<alone.count { worst = max(worst, abs(alone[i] - ref[i] * Float(want))) }
        #expect(worst < 1e-7, "\(worst)")
        // Muting bus B silences what goes through it, and nothing else.
        var muted = p
        try muted.setBus(b.id, muted: true)
        var (others, otherPool) = Self.document()
        others.tracks[0].isMuted = true
        #expect(Self.render(muted, pool).count == dry.count)
        let m = Self.render(muted, pool), o = Self.render(others, otherPool)
        #expect(zip(m, o).allSatisfy { abs($0 - $1) < 1e-7 })
        // The same in blocks of 512 as in one piece.
        let plan = PlanCompiler.compile(p, pool: pool)
        var blocks: [Float] = []
        var at = 0
        while at < Self.n { let k = min(512, Self.n - at); blocks += plan.render(from: Frame(at), frames: k); at += k }
        #expect(blocks == Self.render(p, pool))
    }

    @Test("Pan: the centre is untouched, a side keeps its own channel and loses the other, nothing is raised")
    func pan() throws {
        #expect(Mixer.panGains(0) == (1, 1) && Mixer.panGains(-1).left == 1 && abs(Mixer.panGains(-1).right) < 1e-7 && Mixer.panGains(1).right == 1)
        #expect(abs(Mixer.panGains(0.5).left - Float(cos(Double.pi / 4))) < 1e-7 && Mixer.panGains(0.5).right == 1)
        for p in stride(from: -1.0, through: 1.0, by: 0.05) { let g = Mixer.panGains(p); #expect(g.left <= 1 && g.right <= 1 && g.left >= 0 && g.right >= 0) }
        var (p, pool) = Self.document()
        p.tracks = [p.tracks[0]]
        let centre = Self.render(p, pool)
        try p.setTrackRoute(p.tracks[0].id, pan: -1)
        let left = Self.render(p, pool)
        for i in stride(from: 0, to: left.count, by: 2) { #expect(left[i] == centre[i] && left[i + 1] == 0) }
        // On a bus too.
        var (q, poolQ) = Self.document()
        q.tracks = [q.tracks[0]]
        let centreQ = Self.render(q, poolQ)
        let bus = try q.addBus(name: "R")
        try q.setBus(bus.id, pan: 1)
        try q.setTrackRoute(q.tracks[0].id, output: .some(bus.id))
        let right = Self.render(q, poolQ)
        for i in stride(from: 0, to: right.count, by: 2) { #expect(right[i] == 0 && right[i + 1] == centreQ[i + 1]) }
        // A mono document has nothing to pan between.
        var mono = Self.document(channels: 1).0
        #expect(throws: Mixer.Failure.mono) { try mono.setTrackRoute(mono.tracks[0].id, pan: 0.3) }
        try mono.setTrackRoute(mono.tracks[0].id, pan: 0)
    }

    @Test("Refused in words: loops, a bus that isn't there, one in use, too many, values out of range")
    func refusals() throws {
        var (p, _) = Self.document()
        let a = try p.addBus(name: "A"), b = try p.addBus(name: "B"), c = try p.addBus(name: "C")
        try p.setBus(a.id, output: .some(b.id))
        try p.setBus(b.id, output: .some(c.id))
        let before = p
        #expect(throws: Mixer.Failure.loop("C")) { try p.setBus(c.id, output: .some(a.id)) }
        #expect(throws: Mixer.Failure.loop("A")) { try p.setBus(a.id, output: .some(a.id)) }
        #expect(throws: Mixer.Failure.self) { try p.setBus(UUID(), gainDB: 0) }
        #expect(throws: Mixer.Failure.self) { try p.setBus(a.id, gainDB: 40) }
        #expect(throws: Mixer.Failure.self) { try p.setBus(a.id, gainDB: .nan) }
        #expect(throws: Mixer.Failure.self) { try p.setBus(a.id, pan: 2) }
        #expect(throws: Mixer.Failure.self) { try p.setBus(a.id, name: "  ") }
        #expect(throws: Mixer.Failure.self) { try p.setTrackRoute(p.tracks[0].id, output: .some(UUID())) }
        #expect(throws: Mixer.Failure.inUse("B", 1)) { try p.removeBus(b.id) }
        #expect(p == before)
        // Removed with a place for what fed it: A now feeds C, where B went.
        try p.removeBus(b.id, reroute: .some(c.id))
        #expect(p.buses.map(\.name) == ["A", "C"] && p.bus(a.id)?.output == c.id)
        try p.removeBus(c.id, reroute: .some(nil))
        #expect(p.bus(a.id)?.output == nil)
        for i in 0..<(Mixer.maxBuses - 1) { try p.addBus(name: "b\(i)") }
        #expect(p.buses.count == Mixer.maxBuses)
        #expect(throws: Mixer.Failure.tooMany) { try p.addBus(name: "one too many") }
    }

    @Test("A mixer project is saved as format 2, comes back whole, and a newer format than this app knows is refused in words")
    func format() throws {
        var (p, _) = Self.document()
        let bus = try p.addBus(name: "Music")
        try p.setBus(bus.id, gainDB: -3, pan: 0.25)
        try p.setTrackRoute(p.tracks[1].id, pan: -0.5, output: .some(bus.id))
        let data = try JSONEncoder().encode(p)
        #expect(String(decoding: data, as: UTF8.self).contains("\"formatVersion\":2"))
        #expect(try JSONDecoder().decode(Project.self, from: data) == p)
        // Without the bus and the pan it is format 1 again.
        var back = p
        try back.setTrackRoute(p.tracks[1].id, pan: 0, output: .some(nil))
        try back.removeBus(bus.id)
        #expect(String(decoding: try JSONEncoder().encode(back), as: UTF8.self).contains("\"formatVersion\":1"))
        let newer = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"formatVersion\":2", with: "\"formatVersion\":3").utf8)
        do { _ = try JSONDecoder().decode(Project.self, from: newer); Issue.record("opened") } catch {
            #expect((error as? Project.NeedsNewer)?.version == 3 && error.localizedDescription.contains("newer Jämmer"))
        }
        // The same from a project package, which is how a file is opened: said before anything else is read.
        do { _ = try ProjectPackage.decodeChecked(newer); Issue.record("opened") } catch {
            #expect(error.localizedDescription.contains("saved by a newer Jämmer (format 3)") && error.localizedDescription.contains("Open it in a newer Jämmer"))
        }
        #expect(try ProjectPackage.decodeChecked(data).project == p)
    }

    @Test("The engine doesn't trust the document: a loop handed to it is cut, and it still renders")
    func engineLoop() {
        let plan = jm_plan_create(2, 48_000)
        let a = jm_plan_add_bus(plan, 1, false, 1, 1), b = jm_plan_add_bus(plan, 1, false, 1, 1)
        jm_plan_set_bus_output(plan, a, b)
        jm_plan_set_bus_output(plan, b, a)
        jm_plan_set_bus_output(plan, a, 99)     // nowhere: the output
        jm_plan_set_bus_output(plan, b, a)
        jm_plan_set_bus_output(plan, a, b)      // a ↔ b
        let s = [Float](repeating: 0.25, count: 200)
        let src = s.withUnsafeBufferPointer { jm_source_create_memory($0.baseAddress!, 100, 2) }
        let si = jm_plan_add_source(plan, src)
        let t = jm_plan_add_track(plan, 1, false)
        jm_plan_add_clip(plan, t, si, 0, 0, 100, 1, 0, 0, JM_FADE_LINEAR)
        jm_plan_set_track_route(plan, t, a, 1, 1)
        jm_plan_finalize(plan)
        var out = [Float](repeating: 9, count: 200)
        #expect(jm_render(plan, 0, 100, &out))
        // Through a, on to b or straight out, but out: the track is heard once.
        #expect(out.allSatisfy { $0 == 0.25 })
        jm_plan_release(plan)
        jm_source_release(src)
    }

    /// A project file is untrusted: the mixer in it may loop, point at nothing, or hold values that are
    /// not levels. Each is put right and said, or the file is refused; none of it reaches the engine as it is.
    @Test("A hostile mixer in a project file: loops, routes to nowhere, absurd values, twin ids, too many buses")
    func hostile() throws {
        var (p, pool) = Self.document()
        let a = Bus(name: "A"), b = Bus(name: "B"), c = Bus(name: "C")
        // Written straight into the model, as a file could have it; the editing functions would refuse all of this.
        var hostile = p
        hostile.buses = [Bus(id: a.id, name: "A", gainDB: 1e300, pan: -1e300, output: b.id),
                         Bus(id: b.id, name: "B", gainDB: -1e300, pan: 7, output: a.id),          // a ↔ b
                         Bus(id: c.id, name: "", output: c.id),                                  // itself
                         Bus(id: a.id, name: "A again"),                                         // a twin
                         Bus(name: String(repeating: "x", count: 5_000), output: UUID())]        // to nowhere
        hostile.tracks[0].output = UUID()
        hostile.tracks[1].pan = 1e300          // (JSON has no NaN or infinity, so a file can't hold one)
        hostile.tracks[2].pan = -40
        hostile.tracks[2].output = b.id
        let (opened, notes) = try ProjectPackage.decodeChecked(try ProjectPackage.encode(hostile))
        #expect(opened.buses.count == 4 && Set(opened.buses.map(\.id)).count == 4)
        #expect(opened.buses.allSatisfy { Mixer.gainRange.contains($0.gainDB) && Mixer.panRange.contains($0.pan) && !$0.name.isEmpty && $0.name.count <= 200 })
        #expect(opened.buses.allSatisfy { bus in bus.output.map { o in opened.bus(o) != nil && !opened.loops(bus: bus.id, into: o) } ?? true })
        #expect(opened.tracks[0].output == nil && opened.tracks[1].pan == 1 && opened.tracks[2].pan == -1 && opened.tracks[2].output == b.id)
        #expect(notes.contains { $0.contains("same id") } && notes.contains { $0.contains("round in a circle") } && notes.contains { $0.contains("outside what is possible") }, "\(notes)")
        // And it plays: finite, and as long as it was.
        let y = PlanCompiler.compile(opened, pool: pool).render(from: 0, frames: Self.n)
        #expect(y.count == Self.n * 2 && y.allSatisfy(\.isFinite))
        // More buses than Jämmer makes: not opened, and the words say how many.
        p.buses = (0..<(Mixer.maxBuses + 1)).map { Bus(name: "b\($0)") }
        do { _ = try ProjectPackage.decodeChecked(try ProjectPackage.encode(p)); Issue.record("opened") } catch {
            #expect(error.localizedDescription.contains("65 buses") && error.localizedDescription.contains("at most 64"), "\(error.localizedDescription)")
        }
        // A pan in a mono project means nothing and is dropped.
        var mono = Self.document(channels: 1).0
        mono.tracks[0].pan = 0.5
        #expect(try ProjectPackage.decodeChecked(try ProjectPackage.encode(mono)).project.tracks[0].pan == 0)
    }

    /// A bounce is made from the track's own sound, before its pan and its bus; they apply to the bounce
    /// afterwards. If the bounce had them in it they would be applied twice.
    @Test("A bounce of a panned track on a bus is not panned or lowered twice")
    func bounces() throws {
        var (p, pool) = Self.document()
        let bus = try p.addBus(name: "Music")
        try p.setBus(bus.id, gainDB: -6, pan: 0.5)
        try p.setTrackRoute(p.tracks[0].id, pan: -0.5, output: .some(bus.id))
        let before = Self.render(p, pool)
        let media = FileManager.default.temporaryDirectory.appending(path: "jammer-mixer-bounce-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: media) }
        // An echo with nothing of the echo in it: the bounce is the track as it was.
        let q = try p.applyingEcho(Echo(delay: 0.3, feedback: 0.3, mix: 0), range: 0..<p.length, tracks: [p.tracks[0].id], tail: false, pool: pool, media: media)
        #expect(q.tracks[0].clips.first?.sourceID != p.tracks[0].clips.first?.sourceID && q.tracks[0].pan == -0.5 && q.tracks[0].output == bus.id)
        let after = Self.render(q, pool)
        #expect(zip(after, before).allSatisfy { abs($0 - $1) < 1e-7 })
        // And the limiter listens to the mix as the buses make it: the routed mix comes under the ceiling.
        var loud = p
        loud.tracks[1].gainDB = 22
        let (limited, report) = try loud.limiting(Limiter(ceilingDB: -3), range: 0..<loud.length, pool: pool, media: media)
        var meter = Limiter.PeakMeter(channels: 2, sampleRate: 48_000)
        meter.process(Self.render(limited, pool))
        #expect(meter.peakDB <= -3.0 && report.truePeakAfterDB <= -3.0 && limited.buses == loud.buses, "\(meter.peakDB)")
    }
}
