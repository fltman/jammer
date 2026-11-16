import Foundation
import JammerEngine
import Testing
@testable import JammerCore

/// A stand-in for a plugin with latency: it delays its input by `latency` frames and does nothing else,
/// which is exactly what a plugin's latency is. Or it fails, and then the chain lets the input through
/// as late as the plugin would have been.
final class DelayPlugin {
    let latency: Int
    var fails = false
    private var lines: [[Float]]
    private var at = 0
    init(latency: Int, channels: Int = 2) {
        self.latency = latency
        lines = Array(repeating: [Float](repeating: 0, count: max(1, latency)), count: channels)
    }
    func unit(channels: Int32 = 2) -> OpaquePointer {
        jm_unit_create_processor(channels, Unmanaged.passRetained(self).toOpaque(), { ctx, input, output, channels, frames in
            let me = Unmanaged<DelayPlugin>.fromOpaque(ctx!).takeUnretainedValue()
            if me.fails { return false }
            for i in 0..<Int(frames) {
                for c in 0..<Int(channels) {
                    let x = input[c * Int(frames) + i]
                    if me.latency == 0 { output[c * Int(frames) + i] = x; continue }
                    output[c * Int(frames) + i] = me.lines[c][me.at]
                    me.lines[c][me.at] = x
                }
                if me.latency > 0 { me.at = (me.at + 1) % me.latency }
            }
            return true
        }, { ctx in
            let me = Unmanaged<DelayPlugin>.fromOpaque(ctx!).takeUnretainedValue()
            for c in me.lines.indices { me.lines[c] = [Float](repeating: 0, count: me.lines[c].count) }
            me.at = 0
        }, { ctx in Unmanaged<DelayPlugin>.fromOpaque(ctx!).release() })
    }
}

@Suite("Mixer: plugins on buses, and every path on the sample")
struct MixerGraphTests {
    static let n = 20_000
    /// Sources in memory: a tone on the left and half of it on the right, so a swapped channel shows.
    static func source(_ hz: Double, impulseAt: Int? = nil) -> OpaquePointer {
        var x = [Float](repeating: 0, count: n * 2)
        for i in 0..<n {
            let v: Float = impulseAt.map { $0 == i ? 0.5 : 0 } ?? Float(0.1 * sin(2 * .pi * hz * Double(i) / 48_000))
            x[i * 2] = v; x[i * 2 + 1] = v * 0.5
        }
        return x.withUnsafeBufferPointer { jm_source_create_memory($0.baseAddress!, Int64(n), 2) }
    }
    static func chain(_ plugins: [DelayPlugin]) -> OpaquePointer {
        let c = jm_chain_create(2, 512)
        for p in plugins { let u = p.unit(); jm_chain_add(c, u, Int64(p.latency)); jm_unit_release(u) }
        return c
    }
    static func track(_ plan: OpaquePointer, _ source: OpaquePointer, gain: Float = 1) -> Int32 {
        let t = jm_plan_add_track(plan, gain, false)
        jm_plan_add_clip(plan, t, jm_plan_add_source(plan, source), 0, 0, Int64(n), 1, 0, 0, JM_FADE_LINEAR)
        return t
    }
    static func render(_ plan: OpaquePointer, from: Int = 0, frames: Int = n) -> [Float] {
        var out = [Float](repeating: 9, count: frames * 2)
        #expect(jm_render(plan, Int64(from), Int64(frames), &out))
        return out
    }
    /// The same two tracks straight to the output, with nothing of the mixer: what the mix has to be.
    static func plain(_ a: OpaquePointer, _ b: OpaquePointer) -> [Float] {
        let plan = jm_plan_create(2, 48_000)
        _ = track(plan, a); _ = track(plan, b)
        jm_plan_finalize(plan)
        defer { jm_plan_release(plan) }
        return render(plan)
    }

    @Test("A plugin with latency on a bus doesn't move the bus against the rest: the mix is the plain mix, bit for bit")
    func compensated() {
        let a = Self.source(220), b = Self.source(331)
        defer { jm_source_release(a); jm_source_release(b) }
        let want = Self.plain(a, b)
        for latency in [0, 1, 100, 512, 777, 4_096] {
            let plan = jm_plan_create(2, 48_000)
            let ta = Self.track(plan, a), _ = Self.track(plan, b)
            let bus = jm_plan_add_bus(plan, 1, false, 1, 1)
            jm_plan_set_track_route(plan, ta, bus, 1, 1)
            let c = Self.chain([DelayPlugin(latency: latency)])
            jm_plan_set_bus_chain(plan, bus, c)
            jm_chain_release(c)
            jm_plan_finalize(plan)
            #expect(jm_plan_total_latency(plan) == Int64(latency))
            // The bus is the longest path; the track that goes straight out is delayed by as much.
            #expect(jm_plan_compensation(plan, false, 1) == Int64(latency) && jm_plan_compensation(plan, false, 0) == 0 && jm_plan_compensation(plan, true, bus) == 0)
            #expect(Self.render(plan) == want, "latency \(latency)")
            jm_plan_release(plan)
        }
    }

    @Test("Nested buses and a send: an impulse arrives on its sample by every path, and the delays are the ones reported")
    func nested() {
        let click = Self.source(0, impulseAt: 12_345), other = Self.source(331)
        defer { jm_source_release(click); jm_source_release(other) }
        let plan = jm_plan_create(2, 48_000)
        let tc = Self.track(plan, click), _ = Self.track(plan, other)
        // click → inner (100 late) → outer (37 late) → out; and a send of the click to side (64 late) → out.
        let inner = jm_plan_add_bus(plan, 1, false, 1, 1), outer = jm_plan_add_bus(plan, 1, false, 1, 1), side = jm_plan_add_bus(plan, 1, false, 1, 1)
        for (bus, late) in [(inner, 100), (outer, 37), (side, 64)] { let c = Self.chain([DelayPlugin(latency: late)]); jm_plan_set_bus_chain(plan, bus, c); jm_chain_release(c) }
        jm_plan_set_bus_output(plan, inner, outer)
        jm_plan_set_track_route(plan, tc, inner, 1, 1)
        jm_plan_add_track_send(plan, tc, side, 1, false)
        jm_plan_finalize(plan)
        #expect(jm_plan_total_latency(plan) == 137)
        // The other track goes straight out: 137. The side bus is 64 late where the long way is 137: 73 more.
        #expect(jm_plan_compensation(plan, false, 1) == 137 && jm_plan_compensation(plan, true, side) == 73 && jm_plan_compensation(plan, true, outer) == 0 && jm_plan_compensation(plan, true, inner) == 0)
        let y = Self.render(plan)
        // The click twice (its own way and the send) on frame 12 345 and nowhere else; the other track as it is.
        let plain = Self.plain(other, other)
        for i in 0..<Self.n {
            let wantL = plain[i * 2] / 2 + (i == 12_345 ? 1.0 : 0)
            #expect(abs(y[i * 2] - wantL) < 1e-7, "frame \(i): \(y[i * 2])")
            if abs(y[i * 2] - wantL) >= 1e-7 { break }
        }
        jm_plan_release(plan)
    }

    @Test("The same whatever the blocks, and from wherever it is asked")
    func blocksAndSeeks() {
        let a = Self.source(220), b = Self.source(517)
        defer { jm_source_release(a); jm_source_release(b) }
        func plan() -> OpaquePointer {
            let plan = jm_plan_create(2, 48_000)
            let ta = Self.track(plan, a), tb = Self.track(plan, b, gain: 0.5)
            let bus = jm_plan_add_bus(plan, 0.7, false, 1, 0.8), fx = jm_plan_add_bus(plan, 1, false, 1, 1)
            jm_plan_set_track_route(plan, ta, bus, 1, 1)
            jm_plan_add_track_send(plan, tb, fx, 0.5, true)
            for (x, late) in [(bus, 300), (fx, 1_000)] { let c = Self.chain([DelayPlugin(latency: late), DelayPlugin(latency: 11)]); jm_plan_set_bus_chain(plan, x, c); jm_chain_release(c) }
            jm_plan_finalize(plan)
            return plan
        }
        let whole = plan()
        let want = Self.render(whole)
        jm_plan_release(whole)
        for size in [1, 333, 512, 4_097] {
            let p = plan()
            var got: [Float] = []
            var at = 0
            while at < Self.n { let k = min(size, Self.n - at); got += Self.render(p, from: at, frames: k); at += k }
            #expect(got == want, "blocks of \(size)")
            jm_plan_release(p)
        }
        // From the middle, back to the start, and the middle again: each time the same samples as the whole.
        let p = plan()
        for (from, frames) in [(7_000, 3_000), (0, 2_500), (7_000, 3_000), (19_000, 1_000), (10_000, 1)] {
            #expect(Self.render(p, from: from, frames: frames) == Array(want[(from * 2)..<((from + frames) * 2)]), "from \(from)")
        }
        jm_plan_release(p)
    }

    @Test("A plugin on a bus that fails lets the bus through as late as it would have been; a muted bus is silent and the rest stays in time")
    func failingAndMuted() {
        let a = Self.source(220), b = Self.source(331)
        defer { jm_source_release(a); jm_source_release(b) }
        let want = Self.plain(a, b)
        let broken = DelayPlugin(latency: 250)
        broken.fails = true
        for mute in [false, true] {
            let plan = jm_plan_create(2, 48_000)
            let ta = Self.track(plan, a), _ = Self.track(plan, b)
            let bus = jm_plan_add_bus(plan, 1, mute, 1, 1)
            jm_plan_set_track_route(plan, ta, bus, 1, 1)
            let c = Self.chain([mute ? DelayPlugin(latency: 250) : broken])
            jm_plan_set_bus_chain(plan, bus, c)
            jm_chain_release(c)
            jm_plan_finalize(plan)
            let y = Self.render(plan)
            if mute {
                // Only the second track, where it always was.
                let alone = Self.plain(b, b).map { $0 / 2 }
                #expect(zip(y, alone).allSatisfy { abs($0 - $1) < 1e-7 })
            } else {
                #expect(y == want)
            }
            jm_plan_release(plan)
        }
    }

    @Test("Without a plugin on any bus there is no graph, no lateness, and the mixer is the one from before")
    func none() {
        let a = Self.source(220), b = Self.source(331)
        defer { jm_source_release(a); jm_source_release(b) }
        let plan = jm_plan_create(2, 48_000)
        let ta = Self.track(plan, a), _ = Self.track(plan, b)
        let bus = jm_plan_add_bus(plan, 1, false, 1, 1)
        jm_plan_set_track_route(plan, ta, bus, 1, 1)
        jm_plan_finalize(plan)
        #expect(jm_plan_total_latency(plan) == 0 && jm_plan_compensation(plan, false, 0) == 0 && jm_plan_compensation(plan, true, bus) == 0)
        #expect(Self.render(plan) == Self.plain(a, b))
        jm_plan_release(plan)
    }
}
