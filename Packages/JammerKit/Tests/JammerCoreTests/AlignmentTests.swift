import Foundation
import Testing
@testable import JammerCore

@Suite("Alignment")
struct AlignmentTests {
    /// Speech-like: bursts of noise shaped by a slow, irregular envelope.
    func voice(_ n: Int, seed: UInt64) -> [Float] {
        var x = seed
        return (0..<n).map { i in
            x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let r = Float(Int32(truncatingIfNeeded: x >> 32)) / 2_147_483_648
            let t = Double(i) / 48_000
            let env = max(0, sin(2 * .pi * 1.7 * t) * sin(2 * .pi * 0.31 * t + 1))
            return r * Float(env) * 0.5
        }
    }

    @Test("Finds a known offset to the sample, both ways, through a different mic and noise", arguments: [12_345, -7_777])
    func offset(d: Int) {
        let n = 48_000 * 20
        let ref = voice(n + 30_000, seed: 4)
        // The other recorder: the same voice, quieter, slightly filtered, with its own noise.
        var other = [Float](repeating: 0, count: n)
        let noise = voice(n, seed: 99)
        for i in 0..<n {
            let k = i + 15_000 + d
            let v = k >= 1 && k < ref.count ? 0.6 * ref[k] + 0.2 * ref[k - 1] : 0
            other[i] = v + 0.02 * noise[i]
        }
        let r = Alignment.offset(reference: Array(ref[15_000..<(15_000 + n)]), other: other, sampleRate: 48_000, maxLag: 48_000)
        #expect(r.offset == Frame(d), "found \(r.offset)")
        #expect(r.confidence > 0.8, "confidence \(r.confidence)")
    }

    @Test("Unrelated audio has low confidence")
    func unrelated() {
        let r = Alignment.offset(reference: voice(48_000 * 10, seed: 1), other: voice(48_000 * 10, seed: 2), sampleRate: 48_000, maxLag: 24_000)
        #expect(abs(r.confidence) < 0.2, "confidence \(r.confidence)")
    }

    @Test("Drift: a recorder running 50 ppm fast is measured")
    func drift() throws {
        let n = 48_000 * 300
        let ref = voice(n, seed: 7)
        // other runs fast: its sample i holds the reference at i · (1 + 50e-6), linearly interpolated.
        let other = (0..<n).map { i -> Float in
            let pos = Double(i) * (1 + 50e-6)
            let k = Int(pos), f = Float(pos - Double(k))
            return k + 1 < n ? ref[k] * (1 - f) + ref[k + 1] * f : 0
        }
        let d = try #require(Alignment.drift(reference: ref, other: other, sampleRate: 48_000, maxLag: 4_800, window: 30))
        #expect(abs(d.partsPerMillion - 50) < 2, "measured \(d.partsPerMillion) ppm")
    }
}

@Suite("Double-ender import")
struct DoubleEnderTests {
    @Test("Two recorders of one conversation end up in sync; unrelated audio stays put")
    func align() {
        let n = 48_000 * 30
        let a = AlignmentTests().voice(n + 48_000, seed: 3)
        let host = Array(a[0..<n]).flatMap { [$0, $0] }
        // The guest's recorder started 0.75 s later, and hears the host faintly.
        let late = 36_000
        let guest = (0..<n).flatMap { i -> [Float] in let v = 0.3 * a[i + late] + 0.01 * Float(i % 7) / 7; return [v, v] }
        var (p, pool) = memoryProject(host)
        let info = p.sources[0].info
        let g = SourceRef(name: "Guest", path: "/dev/null", info: info)
        pool.register(g.id, memory: guest, channels: 2)
        p.addTrack(source: g)
        let u = SourceRef(name: "Other", path: "/dev/null", info: info)
        pool.register(u.id, memory: AlignmentTests().voice(n, seed: 77).flatMap { [$0, $0] }, channels: 2)
        p.addTrack(source: u)
        let results = p.alignTracks(to: p.tracks[0].id, pool: pool, window: 20, maxLag: 5)
        #expect(results[p.tracks[1].id]?.offset == Frame(late))
        #expect(p.tracks[1].clips[0].start == Frame(late))
        #expect((results[p.tracks[2].id]?.confidence ?? 1) < 0.5)
        #expect(p.tracks[2].clips[0].start == 0)
    }
}
