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

/// A stand-in for a plugin with a tail and no latency: an echo that feeds back, so what went in goes on
/// sounding after the input has stopped (what a reverb does).
final class TailPlugin {
    let delay: Int
    private var lines: [[Float]]
    private var at = 0
    init(delay: Int = 600, channels: Int = 2) {
        self.delay = delay
        lines = Array(repeating: [Float](repeating: 0, count: delay), count: channels)
    }
    func unit(channels: Int32 = 2) -> OpaquePointer {
        jm_unit_create_processor(channels, Unmanaged.passRetained(self).toOpaque(), { ctx, input, output, channels, frames in
            let me = Unmanaged<TailPlugin>.fromOpaque(ctx!).takeUnretainedValue()
            for i in 0..<Int(frames) {
                for c in 0..<Int(channels) {
                    let y = input[c * Int(frames) + i] + 0.6 * me.lines[c][me.at]
                    output[c * Int(frames) + i] = y
                    me.lines[c][me.at] = y
                }
                me.at = (me.at + 1) % me.delay
            }
            return true
        }, { ctx in
            let me = Unmanaged<TailPlugin>.fromOpaque(ctx!).takeUnretainedValue()
            for c in me.lines.indices { me.lines[c] = [Float](repeating: 0, count: me.lines[c].count) }
            me.at = 0
        }, { ctx in Unmanaged<TailPlugin>.fromOpaque(ctx!).release() })
    }
}

@Suite("Mixer: a new plan goes on from the one that was playing")
struct PlanContinuationTests {
    static let n = MixerGraphTests.n
    /// A track into a bus with an echo on it. `mute`: the track's mute. `until`: the track's clip ends there (nil: the whole source).
    static func plan(_ source: OpaquePointer, chain: OpaquePointer, mute: Bool, until: Int? = nil, extraBus: Bool = false) -> OpaquePointer {
        let plan = jm_plan_create(2, 48_000)
        let t = jm_plan_add_track(plan, 1, mute)
        jm_plan_add_clip(plan, t, jm_plan_add_source(plan, source), 0, 0, Int64(until ?? n), 1, 0, 0, JM_FADE_LINEAR)
        let bus = jm_plan_add_bus(plan, 1, false, 1, 1)
        jm_plan_set_track_route(plan, t, bus, 1, 1)
        jm_plan_set_bus_chain(plan, bus, chain)
        if extraBus { _ = jm_plan_add_bus(plan, 1, false, 1, 1) }
        jm_plan_finalize(plan)
        return plan
    }
    static func echo() -> OpaquePointer {
        let c = jm_chain_create(2, 512)
        let u = TailPlugin().unit()
        jm_chain_add(c, u, 0)
        jm_unit_release(u)
        return c
    }

    @Test("A track muted while it plays: the echo on its bus rings on, the same samples as if the track's sound had simply ended there; started afresh instead, the echo is cut")
    func muteKeepsTheTail() {
        let source = MixerGraphTests.source(220)
        defer { jm_source_release(source) }
        let at = 8_192, after = 6_000   // the mute comes between two blocks, as a new plan does
        // What it has to be: the track's clip simply ends at `at`, through an echo of its own.
        let wantChain = Self.echo(), want = Self.plan(source, chain: wantChain, mute: false, until: at)
        let wanted = MixerGraphTests.render(want, from: 0, frames: at + after)
        jm_plan_release(want); jm_chain_release(wantChain)
        // Playing, then muted by a new plan that goes on from the first.
        let chain = Self.echo()
        let playing = Self.plan(source, chain: chain, mute: false), muted = Self.plan(source, chain: chain, mute: true)
        let before = MixerGraphTests.render(playing, from: 0, frames: at)
        #expect(before == Array(wanted[0..<(at * 2)]))
        #expect(jm_plan_continue_from(muted, playing))
        let tail = MixerGraphTests.render(muted, from: at, frames: after)
        #expect(tail == Array(wanted[(at * 2)...]), "the tail is not what the echo would have gone on to give")
        #expect(tail.contains { abs($0) > 0.01 }, "there is a tail to hear")
        jm_plan_release(playing); jm_plan_release(muted)
        // The same without going on: the new plan starts afresh, the plugin is reset, and the echo is gone.
        let again = Self.plan(source, chain: chain, mute: false), cut = Self.plan(source, chain: chain, mute: true)
        _ = MixerGraphTests.render(again, from: 0, frames: at)
        let silence = MixerGraphTests.render(cut, from: at, frames: after)
        #expect(silence.allSatisfy { $0 == 0 }, "(this is the fault the going-on puts right)")
        jm_plan_release(again); jm_plan_release(cut)
        // A plan of another shape (a bus more), or with other plugins, does not go on: it says so and starts afresh.
        let first = Self.plan(source, chain: chain, mute: false), other = Self.plan(source, chain: chain, mute: true, extraBus: true)
        _ = MixerGraphTests.render(first, from: 0, frames: at)
        #expect(!jm_plan_continue_from(other, first))
        let otherChain = Self.echo(), plugins = Self.plan(source, chain: otherChain, mute: true)
        #expect(!jm_plan_continue_from(plugins, first))
        // A plan that has not played has nothing to go on from.
        let fresh = Self.plan(source, chain: chain, mute: false), next = Self.plan(source, chain: chain, mute: true)
        #expect(!jm_plan_continue_from(next, fresh))
        for p in [first, other, plugins, fresh, next] { jm_plan_release(p) }
        jm_chain_release(chain); jm_chain_release(otherChain)
    }

    @Test("A level changed while it plays goes on without a break: the frames after the change are the next frames, at the new level, none skipped and none twice")
    func levelGoesOn() {
        let source = MixerGraphTests.source(220)
        defer { jm_source_release(source) }
        let at = 8_192, after = 4_096
        func plan(_ chain: OpaquePointer, gain: Float) -> OpaquePointer {
            let plan = jm_plan_create(2, 48_000)
            let t = jm_plan_add_track(plan, gain, false)
            jm_plan_add_clip(plan, t, jm_plan_add_source(plan, source), 0, 0, Int64(Self.n), 1, 0, 0, JM_FADE_LINEAR)
            jm_plan_finalize(plan)
            return plan
        }
        // No plugins at all here: the plain sum. Going on must not skip or repeat a frame.
        let c = Self.echo()
        defer { jm_chain_release(c) }
        let a = plan(c, gain: 1), b = plan(c, gain: 0.5)
        let whole = MixerGraphTests.render(a, from: 0, frames: at + after)
        jm_plan_release(a)
        let a2 = plan(c, gain: 1)
        let first = MixerGraphTests.render(a2, from: 0, frames: at)
        #expect(jm_plan_continue_from(b, a2))
        let second = MixerGraphTests.render(b, from: at, frames: after)
        #expect(first == Array(whole[0..<(at * 2)]))
        #expect(zip(second, whole[(at * 2)...]).allSatisfy { abs($0 - $1 * 0.5) < 1e-7 }, "the frames after the change are the next frames, at the new level")
        jm_plan_release(a2); jm_plan_release(b)
    }

    @Test("Through an echo on a bus, the engine's ring made short and long while it plays: the output is the unbroken render, bit for bit, and a mute given as a new plan in the middle leaves the echo ringing")
    func ringAndMuteInTheEngine() throws {
        let source = MixerGraphTests.source(220)
        defer { jm_source_release(source) }
        let total = 16_384, muteAt = 8_192
        // What it has to be: the track's sound ends at `muteAt`, through an echo of its own, rendered in one go.
        let wantChain = Self.echo(), want = Self.plan(source, chain: wantChain, mute: false, until: muteAt)
        let wanted = MixerGraphTests.render(want, from: 0, frames: total)
        jm_plan_release(want); jm_chain_release(wantChain)
        let chain = Self.echo()
        defer { jm_chain_release(chain) }
        let playing = Self.plan(source, chain: chain, mute: false), muted = Self.plan(source, chain: chain, mute: true)
        defer { jm_plan_release(playing); jm_plan_release(muted) }
        let engine = jm_engine_create(2, 48_000, 4_096)
        defer { jm_engine_destroy(engine) }
        jm_engine_set_plan(engine, playing)
        jm_engine_set_ahead(engine, 512)          // short from the start, so the new plan is taken up at a block we can name
        var left = [Float](repeating: 0, count: 256), right = [Float](repeating: 0, count: 256)
        func pull() {
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    let outs: [UnsafeMutablePointer<Float>] = [l.baseAddress!, r.baseAddress!]
                    outs.withUnsafeBufferPointer { jm_engine_pull(engine, $0.baseAddress!, 2, 256) }
                }
            }
        }
        jm_engine_play(engine, 0)
        for _ in 0..<2_000 where !jm_engine_seek_settled(engine) { pull(); usleep(500) }
        var got: [Float] = []
        var changed = false
        while got.count < total * 2 {
            if !changed {
                // Until the mute, the ring is short and full before every pull: the worker then has nothing it
                // may make, so a plan given now is the one the very next block is made with.
                for _ in 0..<20_000 where jm_engine_buffered(engine) < 512 { usleep(100) }
                try #require(jm_engine_buffered(engine) == 512)
                if got.count / 2 + 512 == muteAt {
                    jm_engine_set_plan(engine, muted)
                    changed = true
                }
            } else {
                // After it, the ring long and short by turns.
                jm_engine_set_ahead(engine, (got.count / 512) % 8 < 4 ? 512 : 0)
                for _ in 0..<20_000 where jm_engine_buffered(engine) < 256 { usleep(100) }
                try #require(jm_engine_buffered(engine) >= 256)
            }
            pull()
            for i in 0..<256 { got.append(left[i]); got.append(right[i]) }
        }
        #expect(changed)
        #expect(got == wanted, "not the unbroken render")
        #expect(got[(muteAt * 2)...].contains { abs($0) > 0.01 }, "the echo rings on after the mute")
    }

    @Test("With the master's limiter on, a mix change goes on too: the playing plans share one limiter through a keeper; without one each plan has its own and starts afresh")
    func limiterGoesOn() throws {
        var (p, pool) = MixerTests.document()
        try p.setMaster(limiter: .some(MasterLimiter()))
        var q = p
        q.tracks[0].isMuted = true
        let keeper = LimiterKeeper()
        let a = PlanCompiler.compile(p, pool: pool, limiters: keeper), b = PlanCompiler.compile(q, pool: pool, limiters: keeper)
        _ = a.render(from: 0, frames: 4_096)
        #expect(jm_plan_continue_from(b.pointer, a.pointer))
        // What it gives after the change is what one unbroken render of the same change gives: the limiter's state came along.
        // (Checked against a plan pair without a keeper, which can't go on.)
        let c = PlanCompiler.compile(p, pool: pool), d = PlanCompiler.compile(q, pool: pool)
        _ = c.render(from: 0, frames: 4_096)
        #expect(!jm_plan_continue_from(d.pointer, c.pointer))
        // Other settings: another limiter, and no going on.
        var r = q
        try r.setMaster(limiter: .some(MasterLimiter(ceilingDB: -3)))
        let e = PlanCompiler.compile(r, pool: pool, limiters: keeper)
        _ = b.render(from: 4_096, frames: 1_024)
        #expect(!jm_plan_continue_from(e.pointer, b.pointer))
    }
}

/// A stand-in for a plugin with a parameter: it multiplies by a gain that a lane can set (parameter 7).
final class GainPlugin {
    var gain: Float = 1
    var sets: [Float] = []
    func unit(channels: Int32 = 2) -> OpaquePointer {
        let u = jm_unit_create_processor(channels, Unmanaged.passRetained(self).toOpaque(), { ctx, input, output, channels, frames in
            let me = Unmanaged<GainPlugin>.fromOpaque(ctx!).takeUnretainedValue()
            for i in 0..<Int(channels) * Int(frames) { output[i] = input[i] * me.gain }
            return true
        }, { _ in }, { ctx in Unmanaged<GainPlugin>.fromOpaque(ctx!).release() })
        jm_unit_set_control(u, { ctx, parameter, value in
            let me = Unmanaged<GainPlugin>.fromOpaque(ctx!).takeUnretainedValue()
            if parameter == 7 { me.gain = value; me.sets.append(value) }
        })
        return u
    }
}

@Suite("Mixer: automation of a plugin's parameter")
struct ParameterCurveTests {
    static let n = MixerGraphTests.n
    static func plan(_ source: OpaquePointer, _ plugin: GainPlugin, points: [(Int64, Float)], onBus: Bool = false) -> OpaquePointer {
        let plan = jm_plan_create(2, 48_000)
        let t = jm_plan_add_track(plan, 1, false)
        jm_plan_add_clip(plan, t, jm_plan_add_source(plan, source), 0, 0, Int64(n), 1, 0, 0, JM_FADE_LINEAR)
        let c = jm_chain_create(2, 0)
        let u = plugin.unit()
        jm_chain_add(c, u, 0)
        jm_unit_release(u)
        if onBus {
            let bus = jm_plan_add_bus(plan, 1, false, 1, 1)
            jm_plan_set_track_route(plan, t, bus, 1, 1)
            jm_plan_set_bus_chain(plan, bus, c)
            jm_plan_add_param_curve(plan, 1, bus, 0, 7, points.map(\.0), points.map(\.1), Int32(points.count))
        } else {
            jm_plan_set_chain(plan, t, c)
            jm_plan_add_param_curve(plan, 0, t, 0, 7, points.map(\.0), points.map(\.1), Int32(points.count))
        }
        jm_chain_release(c)
        jm_plan_finalize(plan)
        return plan
    }

    @Test("A lane on a plugin's parameter: the parameter has the line's value at the start of every 512 frames, on a track and on a bus, and a render from the middle gives the same samples as the whole")
    func parameterFollowsTheLine() {
        let source = MixerGraphTests.source(220)
        defer { jm_source_release(source) }
        let dry = MixerGraphTests.render({ let p = jm_plan_create(2, 48_000); _ = MixerGraphTests.track(p, source); jm_plan_finalize(p); return p }())
        let points: [(Int64, Float)] = [(2_048, 1), (10_240, 0.25)]
        func want(_ frame: Int) -> Float {
            let start = Int64(frame / 512 * 512)            // the block the frame is in
            if start <= 2_048 { return 1 }
            if start >= 10_240 { return 0.25 }
            return 1 + (0.25 - 1) * Float(start - 2_048) / Float(10_240 - 2_048)
        }
        for onBus in [false, true] {
            let plugin = GainPlugin()
            let plan = Self.plan(source, plugin, points: points, onBus: onBus)
            let out = MixerGraphTests.render(plan)
            #expect((0..<Self.n).allSatisfy { abs(out[$0 * 2] - dry[$0 * 2] * want($0)) < 1e-7 }, "on a \(onBus ? "bus" : "track")")
            #expect(plugin.sets.first == 1 && plugin.sets.last == 0.25 && plugin.sets.count >= Self.n / 512)
            // From the middle: the same samples, whatever the plugin's parameter was left at.
            let from = 6_000
            let part = MixerGraphTests.render(plan, from: from, frames: Self.n - from)
            #expect(part == Array(out[(from * 2)...]), "a render from the middle, on a \(onBus ? "bus" : "track")")
            jm_plan_release(plan)
        }
    }
}
