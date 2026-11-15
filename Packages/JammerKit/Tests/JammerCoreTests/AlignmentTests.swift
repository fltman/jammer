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

@Suite("Double-ender with a call recording")
struct CallMixTests {
    /// Two different voices taking turns, a call recording of both with its own latency,
    /// a crude codec (low-pass and coarse quantisation) and noise, and each speaker's own
    /// recorder started at a different time.
    @Test("Each local track lines up with the call mix within a few samples; the mix is suggested as reference")
    func callMix() {
        let n = 48_000 * 40
        let rate = 48_000.0
        var xa: UInt64 = 11, xb: UInt64 = 23
        func noise(_ x: inout UInt64) -> Float {
            x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int32(truncatingIfNeeded: x >> 32)) / 2_147_483_648
        }
        // Turns: A speaks in the first half of every 6 s, B in the second; different timbres.
        var a = [Float](repeating: 0, count: n + 96_000), b = a
        for i in 0..<a.count {
            let t = Double(i) / rate
            let phase = t.truncatingRemainder(dividingBy: 6)
            let envA = phase < 3 ? max(0, sin(2 * .pi * 2.1 * t)) : 0
            let envB = phase >= 3 ? max(0, sin(2 * .pi * 1.6 * t + 0.7)) : 0
            a[i] = Float(envA) * (0.4 * noise(&xa) + 0.2 * Float(sin(2 * .pi * 140 * t)))
            b[i] = Float(envB) * (0.4 * noise(&xb) + 0.2 * Float(sin(2 * .pi * 210 * t)))
        }
        // The call mix: both, 137 ms late, low-passed, quantised to 8 bits, with a little noise.
        let latency = 6_576
        var mix = [Float](repeating: 0, count: n)
        var lp: Float = 0
        var xn: UInt64 = 5
        for i in 0..<n {
            let k = i - latency + 48_000
            let v = k >= 0 && k < a.count ? a[k] + b[k] : 0
            lp += 0.35 * (v - lp)
            mix[i] = (lp * 127).rounded() / 127 + 0.01 * noise(&xn)
        }
        // Local recorders: A started 2.3 s into the conversation's timeline, B 0.4 s.
        let startA = 110_400, startB = 19_200
        let localA = (0..<n).map { i -> Float in let k = i + startA; return k < a.count ? a[k] : 0 }
        let localB = (0..<n).map { i -> Float in let k = i + startB; return k < b.count ? b[k] : 0 }
        var (p, pool) = memoryProject(localA.flatMap { [$0, $0] })
        let info = p.sources[0].info
        for (name, data) in [("Guest", localB), ("Zoom", mix)] {
            let ref = SourceRef(name: name, path: "/dev/null", info: info)
            pool.register(ref.id, memory: data.flatMap { [$0, $0] }, channels: 2)
            p.addTrack(source: ref)
        }
        let mixID = p.tracks[2].id
        #expect(p.suggestedReference(pool: pool, window: 30, maxLag: 5) == mixID)
        let results = p.alignTracks(to: mixID, pool: pool, window: 30, maxLag: 5, minConfidence: 0.3)
        // In the mix, A's content at conversation time T sits at T − 48 000 + latency.
        let expectA = Frame(startA - 48_000 + latency), expectB = Frame(startB - 48_000 + latency)
        let gotA = results[p.tracks[0].id]?.offset ?? .max, gotB = results[p.tracks[1].id]?.offset ?? .max
        #expect(abs(gotA - expectA) <= 3, "A: \(gotA) vs \(expectA), confidence \(results[p.tracks[0].id]?.confidence ?? -1)")
        #expect(abs(gotB - expectB) <= 3, "B: \(gotB) vs \(expectB), confidence \(results[p.tracks[1].id]?.confidence ?? -1)")
    }
}
