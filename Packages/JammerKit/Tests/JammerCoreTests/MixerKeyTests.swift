import Foundation
import JammerEngine
import Testing
@testable import JammerCore

/// A stand-in for a plugin with a sidechain input and known arithmetic: where the key is not silent the
/// audio is multiplied by a quarter, and everything is then `latency` frames late. With a silent key it
/// is a pure delay.
final class KeyedGate {
    let latency: Int
    private var lines: [[Float]]
    private var at = 0
    init(latency: Int, channels: Int = 2) {
        self.latency = latency
        lines = Array(repeating: [Float](repeating: 0, count: max(1, latency)), count: channels)
    }
    func unit(channels: Int32 = 2) -> OpaquePointer {
        let u = jm_unit_create_keyed_processor(channels, Unmanaged.passRetained(self).toOpaque(), { ctx, input, key, output, channels, frames in
            let me = Unmanaged<KeyedGate>.fromOpaque(ctx!).takeUnretainedValue()
            let n = Int(frames), ch = Int(channels)
            for i in 0..<n {
                var open = true
                for c in 0..<ch where key[c * n + i] != 0 { open = false }
                for c in 0..<ch {
                    let x = input[c * n + i] * (open ? 1 : 0.25)
                    if me.latency == 0 { output[c * n + i] = x; continue }
                    output[c * n + i] = me.lines[c][me.at]
                    me.lines[c][me.at] = x
                }
                if me.latency > 0 { me.at = (me.at + 1) % me.latency }
            }
            return true
        }, { ctx in
            let me = Unmanaged<KeyedGate>.fromOpaque(ctx!).takeUnretainedValue()
            for c in me.lines.indices { me.lines[c] = [Float](repeating: 0, count: me.lines[c].count) }
            me.at = 0
        }, { ctx in Unmanaged<KeyedGate>.fromOpaque(ctx!).release() })
        #expect(jm_unit_enable_key_input(u))
        return u
    }
}

@Suite("Mixer: sidechain keys, in step with the audio by every path")
struct MixerKeyTests {
    static let n = MixerGraphTests.n, at = 12_345
    /// A steady level on both channels: what a gate does to it is plain to see.
    static func steady(_ level: Float = 0.25) -> OpaquePointer {
        let x = [Float](repeating: level, count: n * 2)
        return x.withUnsafeBufferPointer { jm_source_create_memory($0.baseAddress!, Int64(n), 2) }
    }
    /// A chain of stand-ins, in order: `.delay(n)` a pure delay, `.gate(n)` the keyed gate.
    enum Stage { case delay(Int), gate(Int) }
    static func chain(_ stages: [Stage]) -> OpaquePointer {
        let c = jm_chain_create(2, 512)
        for s in stages {
            switch s {
            case .delay(let l): let u = DelayPlugin(latency: l).unit(); jm_chain_add(c, u, Int64(l)); jm_unit_release(u)
            case .gate(let l): let u = KeyedGate(latency: l).unit(); jm_chain_add(c, u, Int64(l)); jm_unit_release(u)
            }
        }
        return c
    }
    /// What has to come out when a steady 0.25 is gated by a click at `at` that is itself in the mix
    /// (0.5 on the left, 0.25 on the right): 0.25 everywhere, a quarter of it on that one frame, plus the click.
    static func expectGated(_ y: [Float], click: Bool = true, _ what: String) {
        var wrong = 0, first = -1
        for i in 0..<n {
            let l: Float = (i == at ? 0.0625 : 0.25) + (click && i == at ? 0.5 : 0)
            let r: Float = (i == at ? 0.0625 : 0.25) + (click && i == at ? 0.25 : 0)
            if abs(y[i * 2] - l) > 1e-7 || abs(y[i * 2 + 1] - r) > 1e-7 { wrong += 1; if first < 0 { first = i } }
        }
        #expect(wrong == 0, "\(what): \(wrong) frames wrong, the first at \(first) (\(first >= 0 ? y[first * 2] : 0))")
    }

    @Test("A track's plugin keyed from another track: the key lands on its frame, whatever the plugin's latency and whatever stands before it in the chain")
    func trackFromTrack() {
        let a = Self.steady(), k = MixerGraphTests.source(0, impulseAt: Self.at)
        defer { jm_source_release(a); jm_source_release(k) }
        for (stages, unit): ([Stage], Int32) in [([.gate(0)], 0), ([.gate(100)], 0), ([.gate(777)], 0), ([.delay(300), .gate(64)], 1), ([.delay(1), .delay(511), .gate(0), .delay(40)], 2)] {
            let plan = jm_plan_create(2, 48_000)
            let ta = MixerGraphTests.track(plan, a), tk = MixerGraphTests.track(plan, k)
            let c = Self.chain(stages)
            jm_plan_set_chain(plan, ta, c)
            jm_chain_release(c)
            jm_plan_add_key(plan, false, ta, unit, false, tk)
            jm_plan_finalize(plan)
            #expect(jm_plan_key_count(plan) == 1)
            Self.expectGated(MixerGraphTests.render(plan), "\(stages)")
            jm_plan_release(plan)
        }
    }

    @Test("The key's own strip is late (a plugin on it), or the key is a bus with a late plugin, or the listener is a bus: still on the frame")
    func latePaths() {
        let a = Self.steady(), k = MixerGraphTests.source(0, impulseAt: Self.at)
        defer { jm_source_release(a); jm_source_release(k) }
        // 1. The key track has a plugin of its own, 64 frames late.
        do {
            let plan = jm_plan_create(2, 48_000)
            let ta = MixerGraphTests.track(plan, a), tk = MixerGraphTests.track(plan, k)
            let c = Self.chain([.gate(33)]), late = Self.chain([.delay(64)])
            jm_plan_set_chain(plan, ta, c); jm_plan_set_chain(plan, tk, late)
            jm_chain_release(c); jm_chain_release(late)
            jm_plan_add_key(plan, false, ta, 0, false, tk)
            jm_plan_finalize(plan)
            // The key is 64 late where it leaves; the listening track is 33 late itself: the longest path is 97.
            #expect(jm_plan_total_latency(plan) == 97)
            Self.expectGated(MixerGraphTests.render(plan), "key track with a plugin")
            jm_plan_release(plan)
        }
        // 2. The key is a bus (the click goes through it) with a 50-frame plugin.
        do {
            let plan = jm_plan_create(2, 48_000)
            let ta = MixerGraphTests.track(plan, a), tk = MixerGraphTests.track(plan, k)
            let bus = jm_plan_add_bus(plan, 1, false, 1, 1)
            jm_plan_set_track_route(plan, tk, bus, 1, 1)
            let c = Self.chain([.gate(10)]), late = Self.chain([.delay(50)])
            jm_plan_set_chain(plan, ta, c); jm_plan_set_bus_chain(plan, bus, late)
            jm_chain_release(c); jm_chain_release(late)
            jm_plan_add_key(plan, false, ta, 0, true, bus)
            jm_plan_finalize(plan)
            Self.expectGated(MixerGraphTests.render(plan), "key from a bus")
            jm_plan_release(plan)
        }
        // 3. The listener is a bus that the steady track goes through; the key is a track, muted on the way out
        //    by its fader being at nothing? No: a key is taken after the fader. So the click is in the mix too.
        do {
            let plan = jm_plan_create(2, 48_000)
            let ta = MixerGraphTests.track(plan, a), tk = MixerGraphTests.track(plan, k)
            let bus = jm_plan_add_bus(plan, 1, false, 1, 1)
            jm_plan_set_track_route(plan, ta, bus, 1, 1)
            let c = Self.chain([.delay(20), .gate(200)])
            jm_plan_set_bus_chain(plan, bus, c)
            jm_chain_release(c)
            jm_plan_add_key(plan, true, bus, 1, false, tk)
            jm_plan_finalize(plan)
            Self.expectGated(MixerGraphTests.render(plan), "a bus that listens")
            jm_plan_release(plan)
        }
        // 5. The listener is a bus whose audio arrives late (the steady track has a 120-frame plugin of its
        //    own) while the key comes from a track that is on time: the key has to wait for the audio.
        do {
            let plan = jm_plan_create(2, 48_000)
            let ta = MixerGraphTests.track(plan, a), tk = MixerGraphTests.track(plan, k)
            let bus = jm_plan_add_bus(plan, 1, false, 1, 1)
            jm_plan_set_track_route(plan, ta, bus, 1, 1)
            let late = Self.chain([.delay(120)]), c = Self.chain([.gate(7)])
            jm_plan_set_chain(plan, ta, late); jm_plan_set_bus_chain(plan, bus, c)
            jm_chain_release(late); jm_chain_release(c)
            jm_plan_add_key(plan, true, bus, 0, false, tk)
            jm_plan_finalize(plan)
            #expect(jm_plan_total_latency(plan) == 127)
            Self.expectGated(MixerGraphTests.render(plan), "a key that waits for late audio")
            jm_plan_release(plan)
        }
        // 4. A muted key track is a silent key (it is taken after the fader): nothing is gated.
        do {
            let plan = jm_plan_create(2, 48_000)
            let ta = MixerGraphTests.track(plan, a)
            let tk = jm_plan_add_track(plan, 1, true)
            jm_plan_add_clip(plan, tk, jm_plan_add_source(plan, k), 0, 0, Int64(Self.n), 1, 0, 0, JM_FADE_LINEAR)
            let c = Self.chain([.gate(100)])
            jm_plan_set_chain(plan, ta, c)
            jm_chain_release(c)
            jm_plan_add_key(plan, false, ta, 0, false, tk)
            jm_plan_finalize(plan)
            let y = MixerGraphTests.render(plan)
            let all = y.allSatisfy { $0 == 0.25 }
            #expect(all, "a muted key gated something")
            jm_plan_release(plan)
        }
    }

    @Test("Without a key nothing changes: a plan with a keyed plugin and no key is the plan it was, bit for bit; with one, blocks and seeks give the same samples")
    func nullAndBlocks() {
        let a = MixerGraphTests.source(220), k = MixerGraphTests.source(0, impulseAt: Self.at)
        defer { jm_source_release(a); jm_source_release(k) }
        func plan(key: Bool) -> OpaquePointer {
            let plan = jm_plan_create(2, 48_000)
            let ta = MixerGraphTests.track(plan, a), tk = MixerGraphTests.track(plan, k)
            let c = Self.chain([.delay(30), .gate(100)])
            jm_plan_set_chain(plan, ta, c)
            jm_chain_release(c)
            if key { jm_plan_add_key(plan, false, ta, 1, false, tk) }
            jm_plan_finalize(plan)
            return plan
        }
        // No key: the gate is a delay (30 + 100 frames with the unit before it) that the graph makes up for; the plain mix.
        let none = plan(key: false)
        #expect(jm_plan_total_latency(none) == 130)
        #expect(MixerGraphTests.render(none) == MixerGraphTests.plain(a, k))
        jm_plan_release(none)
        // With the key: only the one frame differs from the plain mix, and by the gate's quarter.
        let whole = plan(key: true)
        let want = MixerGraphTests.render(whole)
        jm_plan_release(whole)
        let plain = MixerGraphTests.plain(a, k)
        var differing: [Int] = []
        for i in 0..<Self.n where want[i * 2] != plain[i * 2] { differing.append(i) }
        #expect(differing == [Self.at], "\(differing.prefix(5))")
        for size in [1, 333, 512, 4_097] {
            let p = plan(key: true)
            var got: [Float] = []
            var at = 0
            while at < Self.n { let n = min(size, Self.n - at); got += MixerGraphTests.render(p, from: at, frames: n); at += n }
            #expect(got == want, "blocks of \(size)")
            jm_plan_release(p)
        }
        let p = plan(key: true)
        for (from, frames) in [(12_000, 1_000), (0, 2_500), (12_340, 10), (19_000, 1_000)] {
            #expect(MixerGraphTests.render(p, from: from, frames: frames) == Array(want[(from * 2)..<((from + frames) * 2)]), "from \(from)")
        }
        jm_plan_release(p)
    }

    @Test("A key that would close a loop, or that points at nothing, is dropped, and the plan still plays")
    func loops() {
        let a = Self.steady(), k = MixerGraphTests.source(0, impulseAt: Self.at)
        defer { jm_source_release(a); jm_source_release(k) }
        // Two tracks keyed from each other: the second key closes the loop and goes.
        do {
            let plan = jm_plan_create(2, 48_000)
            let ta = MixerGraphTests.track(plan, a), tk = MixerGraphTests.track(plan, k)
            for t in [ta, tk] { let c = Self.chain([.gate(10)]); jm_plan_set_chain(plan, t, c); jm_chain_release(c) }
            jm_plan_add_key(plan, false, ta, 0, false, tk)
            jm_plan_add_key(plan, false, tk, 0, false, ta)
            jm_plan_finalize(plan)
            #expect(jm_plan_key_count(plan) == 1)
            Self.expectGated(MixerGraphTests.render(plan), "one key of a pair kept")
            jm_plan_release(plan)
        }
        // A track keyed from the bus it feeds; from itself; to a unit that isn't there; from a strip that isn't there.
        do {
            let plan = jm_plan_create(2, 48_000)
            let ta = MixerGraphTests.track(plan, a), _ = MixerGraphTests.track(plan, k)
            let bus = jm_plan_add_bus(plan, 1, false, 1, 1)
            jm_plan_set_track_route(plan, ta, bus, 1, 1)
            let c = Self.chain([.gate(10)])
            jm_plan_set_chain(plan, ta, c)
            jm_chain_release(c)
            jm_plan_add_key(plan, false, ta, 0, true, bus)
            jm_plan_add_key(plan, false, ta, 0, false, ta)
            jm_plan_add_key(plan, false, ta, 5, false, 1)
            jm_plan_add_key(plan, false, ta, 0, false, 40)
            jm_plan_add_key(plan, true, 9, 0, false, 1)
            jm_plan_finalize(plan)
            #expect(jm_plan_key_count(plan) == 0)
            let y = MixerGraphTests.render(plan)
            let finite = y.allSatisfy { $0.isFinite }
            #expect(finite && y.count == Self.n * 2)
            jm_plan_release(plan)
        }
    }
}
