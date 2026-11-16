import CryptoKit
import Foundation
import Testing
@testable import JammerCore

/// Every plan goes through the mixer graph. Until 2026-11-16 there were older paths beside it (the plain
/// renderer, `renderRouted`, tracks' chains pulling for themselves); before they were removed, these
/// projects were rendered both ways and were bit for bit the same (docs/MIXER.md; the commit tagged
/// `before-graph-only` still has both). What the older paths gave is kept here as digests.
@Suite("Mixer: every kind of project gives what it gave before the graph was the only path", .serialized)
struct GraphEquivalenceTests {
    static let lowpass = PluginID("aufx/lpas/appl")!, limiter = PluginID("aufx/lmtr/appl")!

    /// The projects: one per thing the mixer does, and some with several at once.
    static func projects() throws -> [(String, Project, SourcePool)] {
        var out: [(String, Project, SourcePool)] = []
        func add(_ name: String, _ change: (inout Project) throws -> Void) rethrows {
            var (p, pool) = MixerTests.document()
            try change(&p)
            out.append((name, p, pool))
        }
        add("plain") { _ in }
        add("track gains") { p in p.tracks[0].gainDB = -3; p.tracks[1].gainDB = 2.5 }
        add("clip gain and fades") { p in p.tracks[0].clips[0].gainDB = -4; p.tracks[0].clips[0].fadeIn = 2_000; p.tracks[1].clips[0].fadeOut = 3_000; p.tracks[1].gainDB = -1.5 }
        add("a muted track") { p in p.tracks[1].isMuted = true }
        add("a clip moved and cut") { p in p.tracks[2].clips[0].start = 5_000; p.tracks[2].clips[0].length = 20_000; p.tracks[2].clips[0].sourceStart = 700 }
        try add("pan") { p in try p.setTrackRoute(p.tracks[0].id, pan: -0.4); try p.setTrackRoute(p.tracks[2].id, pan: 1) }
        try add("a bus") { p in let b = try p.addBus(name: "B"); try p.setTrackRoute(p.tracks[0].id, output: .some(b.id)); try p.setBus(b.id, gainDB: -2, pan: 0.3) }
        try add("nested buses and sends") { p in
            let a = try p.addBus(name: "A"), b = try p.addBus(name: "B"), fx = try p.addBus(name: "FX")
            try p.setBus(a.id, gainDB: -1, output: .some(b.id))
            try p.setTrackRoute(p.tracks[0].id, output: .some(a.id))
            try p.setSend(from: p.tracks[1].id, to: fx.id, gainDB: -6)
            try p.setSend(from: p.tracks[2].id, to: fx.id, gainDB: -3, pre: true)
            try p.setSend(from: a.id, to: fx.id, gainDB: -9)
            p.tracks[2].gainDB = -5
        }
        try add("a VCA group") { p in let v = try p.addVCA(name: "V"); try p.setMember(p.tracks[0].id, vca: v.id); try p.setVCA(v.id, gainDB: -4) }
        try add("master gain") { p in try p.setMaster(gainDB: -3) }
        try add("master limiter, idle") { p in try p.setMaster(limiter: .some(MasterLimiter(ceilingDB: -1))) }
        try add("master limiter, working") { p in for t in p.tracks.indices { p.tracks[t].gainDB = 12 }; try p.setMaster(limiter: .some(MasterLimiter(ceilingDB: -6))) }
        add("plugins on a track") { p in p.tracks[0].inserts = [Insert(plugin: lowpass, name: "lp"), Insert(plugin: limiter, name: "lim")]; p.tracks[0].gainDB = -2 }
        add("plugins on every track") { p in for t in p.tracks.indices { p.tracks[t].inserts = [Insert(plugin: t % 2 == 0 ? lowpass : limiter, name: "p")] } }
        try add("a plugin on a bus") { p in let b = try p.addBus(name: "B"); try p.setTrackRoute(p.tracks[0].id, output: .some(b.id)); p.buses[0].inserts = [Insert(plugin: limiter, name: "lim")] }
        try add("plugins on tracks and buses, a send") { p in
            let b = try p.addBus(name: "B"), fx = try p.addBus(name: "FX")
            p.tracks[0].inserts = [Insert(plugin: limiter, name: "lim")]
            p.tracks[1].inserts = [Insert(plugin: lowpass, name: "lp")]
            p.buses[0].inserts = [Insert(plugin: lowpass, name: "lp")]
            p.buses[1].inserts = [Insert(plugin: limiter, name: "lim")]
            try p.setTrackRoute(p.tracks[0].id, output: .some(b.id))
            try p.setSend(from: p.tracks[1].id, to: fx.id, gainDB: -6)
            try p.setMaster(gainDB: -1)
        }
        // Clips that start in another order than their tracks stand in, three of them sounding at once:
        // the plain renderer sums clips in the order of their starts.
        add("clips out of track order") { p in
            p.tracks[0].clips[0].start = 9_000; p.tracks[0].clips[0].length = 30_000; p.tracks[0].gainDB = -1.3
            p.tracks[1].clips[0].start = 3_000; p.tracks[1].clips[0].length = 40_000; p.tracks[1].gainDB = 0.7
            p.tracks[2].gainDB = -2.1
        }
        add("two clips crossing on a track") { p in
            var second = p.tracks[0].clips[0]
            second.id = UUID(); second.start = 20_000; second.sourceStart = 4_000; second.length = 15_000; second.fadeIn = 1_000; second.gainDB = -3
            p.tracks[0].clips[0].length = 21_000; p.tracks[0].clips[0].fadeOut = 1_000
            p.tracks[0].clips.append(second)
            p.tracks[0].gainDB = 1.1
        }
        add("plugins with latency before and after tracks without") { p in
            p.tracks[1].inserts = [Insert(plugin: limiter, name: "lim")]; p.tracks[1].gainDB = -2.2
            p.tracks[0].gainDB = -0.9; p.tracks[2].gainDB = 1.4
        }
        add("a soloed track") { p in p = p.listening(solo: [p.tracks[1].id]) }
        do {
            var (p, pool) = MixerTests.document(channels: 1)
            p.tracks[0].gainDB = -3
            p.tracks[1].inserts = [Insert(plugin: lowpass, name: "lp")]
            out.append(("mono, a plugin", p, pool))
        }
        return out
    }

    /// What each project gave by the older paths (the plain renderer, `renderRouted`, tracks' chains
    /// pulling for themselves) on 2026-11-16, at the commit tagged `before-graph-only`: the first eight
    /// bytes of the SHA-256 of the whole render's samples. Kept so that the suite goes on saying "the
    /// same as what shipped before", not only "the same as itself". The ones with Apple's plugins in them
    /// depend on those plugins and are held to only on the macOS build they were made on.
    static let shippedBefore: [String: String] = [
        "plain": "abbff03c38841469", "track gains": "3fc27e3cd742bcc3", "clip gain and fades": "8f12b0177ccb6e25", "a muted track": "7e300eb946d9bd98",
        "a clip moved and cut": "70481b85eca178b6", "pan": "def8d26144086496", "a bus": "bb655fc10e649bd5", "nested buses and sends": "6e26e438d4e16538",
        "a VCA group": "c7894fb33eab5c7b", "master gain": "44874737139e13d1", "master limiter, idle": "abbff03c38841469", "master limiter, working": "975560489d830cb8",
        "clips out of track order": "6071a7faf2bd9e13", "two clips crossing on a track": "672db63533caecbd", "a soloed track": "0c65ad5dfd2b3df0",
        "plugins on a track": "2840f30449d0288e", "plugins on every track": "766f666e7ba3f4f7", "a plugin on a bus": "731f722ca272c2b2",
        "plugins on tracks and buses, a send": "6307664907e56aae", "plugins with latency before and after tracks without": "3dfebd3b3140440d", "mono, a plugin": "dd3bf710d569d0d5",
    ]
    static let shippedOnBuild = "Version 27.2.1 (Build 26B131)"
    static func digest(_ x: [Float]) -> String { x.withUnsafeBytes { SHA256.hash(data: Data($0)) }.prefix(8).map { String(format: "%02x", $0) }.joined() }
    static var thisBuild: String { ProcessInfo.processInfo.operatingSystemVersionString }

    static func worst(_ a: [Float], _ b: [Float]) -> (max: Float, db: Double, differing: Int) {
        var m: Float = 0, e = 0.0, r = 0.0, n = 0
        for i in 0..<min(a.count, b.count) {
            let d = abs(a[i] - b[i])
            if d > 0 { n += 1 }
            m = max(m, d); e += Double(d) * Double(d); r += Double(b[i]) * Double(b[i])
        }
        return (m, 10 * log10(max(e, 1e-30) / max(r, 1e-30)), n)
    }

    @Test("Each project gives the samples it gave by the older paths (by their recorded digests), the same in 512-frame blocks, and the same after seeks")
    func asShippedBefore() throws {
        for (name, p, pool) in try Self.projects() {
            let hasPlugins = p.hasActiveInserts
            func plan() -> RenderPlan { PlanCompiler.compile(p, pool: pool, inserts: hasPlugins ? InsertHost.makeBlocking(for: p) : nil) }
            let n = Int(p.length)
            let whole = plan().render(from: 0, frames: n)
            if let shipped = Self.shippedBefore[name] {
                if !hasPlugins || Self.thisBuild == Self.shippedOnBuild {
                    #expect(Self.digest(whole) == shipped, "\(name): not the samples that shipped before")
                } else {
                    print("GRAPH EQ \(name): has Apple's plugins and this is another macOS build than the reference's; its digest is not held to")
                }
            } else {
                Issue.record("\(name) has no recorded digest")
            }
            let blocky = plan()
            var blocks: [Float] = []
            var at = 0
            while at < n { let k = min(512, n - at); blocks += blocky.render(from: Frame(at), frames: k); at += k }
            #expect(blocks == whole, "\(name): differs between blocks and one piece")
            let seeking = plan()
            for (from, frames) in [(30_000, 4_000), (0, 3_000), (17_123, 2_048), (46_000, 2_000)] {
                let got = seeking.render(from: Frame(from), frames: frames), want = Array(whole[(from * channelsOf(p))..<((from + frames) * channelsOf(p))])
                if name == "master limiter, working" {
                    // A limiter that is working doesn't know what it did before the run-in: after a seek it
                    // is the unbroken run's to within a thousandth, not bit for bit (docs/MIXER.md, step 4).
                    #expect(zip(got, want).allSatisfy { abs($0 - $1) < 1e-3 }, "\(name): after a seek to \(from)")
                } else {
                    #expect(got == want, "\(name): after a seek to \(from)")
                }
            }
        }
    }
    func channelsOf(_ p: Project) -> Int { p.channels }
}
