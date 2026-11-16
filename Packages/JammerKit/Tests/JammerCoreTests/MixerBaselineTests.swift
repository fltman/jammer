import Accelerate
import Foundation
import Testing
@testable import JammerCore

/// What the render path costs today, before a mixer is built on it: `JAMMER_MIXER_BASELINE=1`.
/// Not a pass/fail test; it prints the figures that docs/MIXER.md quotes.
@Suite("Mixer baseline", .serialized, .enabled(if: ProcessInfo.processInfo.environment["JAMMER_MIXER_BASELINE"] != nil))
struct MixerBaselineTests {
    @Test func tracks() {
        let rate = 48_000.0, seconds = 20, n = Int(rate) * 30
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: rate,
                                 channelMask: nil, dataOffset: 0, frames: Int64(n), chunks: [], bext: nil, ixml: nil, markers: [])
        for count in [1, 8, 32, 64, 128] {
            let pool = SourcePool()
            var p: Project?
            for t in 0..<count {
                let src = SourceRef(name: "s\(t)", path: "/dev/null", info: info)
                pool.register(src.id, memory: (0..<(n * 2)).map { Float(0.01 * sin(Double($0 + t * 977) * 0.01)) }, channels: 2)
                if p == nil { p = Project(source: src) } else { _ = p!.addTrack(source: src, name: "t\(t)") }
            }
            let plan = PlanCompiler.compile(p!, pool: pool)
            // In 512-frame blocks, as the playback worker asks; the worst single block matters as much as the mean.
            var worst = 0.0, total = 0.0
            let blocks = seconds * Int(rate) / 512
            for b in 0..<blocks {
                let t0 = DispatchTime.now().uptimeNanoseconds
                _ = plan.render(from: Frame(b * 512), frames: 512)
                let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
                total += dt; worst = max(worst, dt)
            }
            let block = 512 / rate
            print(String(format: "MIXER BASELINE %3d stereo tracks: %.0f× realtime on one core; a 512-frame block (10.7 ms of audio) takes %.3f ms on average, %.3f ms at worst (%.1f %% of its time)",
                         count, Double(seconds) / total, total / Double(blocks) * 1000, worst * 1000, worst / block * 100))
        }
    }

    /// What automation costs: 64 stereo tracks with a level that moves all the time on every one of them
    /// (a point every half second, 12 dB apart) and on the master, against the same tracks without lanes.
    /// Each measured three times, in turn, so that a busy moment doesn't land on one of them only.
    @Test func withAutomation() throws {
        let rate = 48_000.0, seconds = 20, n = Int(rate) * 30, count = 64
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: rate,
                                 channelMask: nil, dataOffset: 0, frames: Int64(n), chunks: [], bext: nil, ixml: nil, markers: [])
        let pool = SourcePool()
        var made: Project?
        for t in 0..<count {
            let src = SourceRef(name: "s\(t)", path: "/dev/null", info: info)
            pool.register(src.id, memory: (0..<(n * 2)).map { Float(0.01 * sin(Double($0 + t * 977) * 0.01)) }, channels: 2)
            if made == nil { made = Project(source: src) } else { _ = made!.addTrack(source: src, name: "t\(t)") }
        }
        let plain = made!
        var moving = plain
        let points = (0...(seconds * 2 + 2)).map { AutomationPoint(frame: Frame(Double($0) * rate / 2), value: $0 % 2 == 0 ? 0 : -12) }
        for t in moving.tracks { try moving.setAutomation(strip: t.id, points: points) }
        try moving.setAutomation(strip: Master.id, points: points)
        // The same lanes, but still: a point's worth of line at one level (what a lane costs when nothing moves).
        var still = plain
        for t in still.tracks { try still.setAutomation(strip: t.id, points: [AutomationPoint(frame: 0, value: -6), AutomationPoint(frame: Frame(n), value: -6)]) }
        func measure(_ p: Project) -> (mean: Double, worst: Double) {
            let plan = PlanCompiler.compile(p, pool: pool)
            var worst = 0.0, total = 0.0
            let blocks = seconds * Int(rate) / 512
            for b in 0..<blocks {
                let t0 = DispatchTime.now().uptimeNanoseconds
                _ = plan.render(from: Frame(b * 512), frames: 512)
                let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
                total += dt; worst = max(worst, dt)
            }
            return (total / Double(blocks) * 1000, worst * 1000)
        }
        var rows: [String: [(Double, Double)]] = [:]
        for _ in 0..<3 { for (name, p) in [("no lanes", plain), ("a still lane on every track", still), ("a moving lane on every track and the master", moving)] { rows[name, default: []].append(measure(p)) } }
        for name in ["no lanes", "a still lane on every track", "a moving lane on every track and the master"] {
            let r = rows[name]!
            print(String(format: "MIXER AUTOMATION 64 stereo tracks, %@: a 512-frame block takes %.3f ms on average (best of three %.3f), %.3f ms at worst (best of three %.3f)",
                         name, r.map(\.0).reduce(0, +) / 3, r.map(\.0).min()!, r.map(\.1).max()!, r.map(\.1).min()!))
        }
    }

    /// The mixer carrying real plugins, on tracks and on buses (Apple's low-pass and peak limiter, in
    /// process): what a 512-frame block costs once it runs, and what the first block after a seek costs,
    /// which has the run-in of every chain and of the graph in it.
    @Test func withPlugins() async throws {
        let rate = 48_000.0, seconds = 10, n = Int(rate) * 20
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: rate,
                                 channelMask: nil, dataOffset: 0, frames: Int64(n), chunks: [], bext: nil, ixml: nil, markers: [])
        let lowpass = PluginID("aufx/lpas/appl")!, limiter = PluginID("aufx/lmtr/appl")!
        for (tracks, buses, perTrack, perBus) in [(8, 2, 1, 2), (16, 4, 2, 2), (32, 8, 2, 2), (64, 8, 2, 2), (64, 8, 0, 2), (64, 0, 2, 0)] {
            let pool = SourcePool()
            var made: Project?
            for t in 0..<tracks {
                let src = SourceRef(name: "s\(t)", path: "/dev/null", info: info)
                pool.register(src.id, memory: (0..<(n * 2)).map { Float(0.01 * sin(Double($0 + t * 977) * 0.01)) }, channels: 2)
                if made == nil { made = Project(source: src) } else { _ = made!.addTrack(source: src, name: "t\(t)") }
            }
            var p = made!
            for b in 0..<buses {
                let bus = try p.addBus(name: "bus \(b)")
                p.buses[b].inserts = (0..<perBus).map { Insert(plugin: $0 % 2 == 0 ? limiter : lowpass, name: "p") }
                _ = bus
            }
            for t in 0..<tracks {
                p.tracks[t].inserts = (0..<perTrack).map { Insert(plugin: $0 % 2 == 0 ? lowpass : limiter, name: "p") }
                if buses > 0 {
                    try p.setTrackRoute(p.tracks[t].id, output: .some(p.buses[t % buses].id))
                    // Every fourth track also sends to the next bus.
                    if t % 4 == 0, buses > 1 { try p.setSend(from: p.tracks[t].id, to: p.buses[(t + 1) % buses].id, gainDB: -6) }
                }
            }
            let host = await InsertHost.make(for: p)
            #expect(p.allInserts.allSatisfy { host.instance($0.id) != nil })
            let plan = PlanCompiler.compile(p, pool: pool, inserts: host)
            var times: [Double] = [], first = 0.0
            let blocks = seconds * Int(rate) / 512
            for b in 0..<blocks {
                let t0 = DispatchTime.now().uptimeNanoseconds
                _ = plan.render(from: Frame(b * 512), frames: 512)
                let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
                if b == 0 { first = dt } else { times.append(dt) }
            }
            let block = 512 / rate
            let sorted = times.sorted(), late = times.indices.filter { times[$0] > block }
            func pct(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] * 1000 }
            print(String(format: "MIXER PLUGINS %2d tracks × %d plugins, %d buses × %d plugins (%3d units, mixer latency %lld frames): block mean %.3f ms, median %.3f, 99 %% under %.3f, 99.9 %% under %.3f, worst %.3f ms; %d of %d blocks over their 10.7 ms (at %@); first block after a seek %.1f ms",
                         tracks, perTrack, buses, perBus, p.allInserts.count, plan.totalLatency, times.reduce(0, +) / Double(times.count) * 1000, pct(0.5), pct(0.99), pct(0.999), sorted.last! * 1000,
                         late.count, times.count, late.prefix(6).map { String($0 + 1) }.joined(separator: ",") as NSString, first * 1000))
        }
    }

    /// The same load with and without one sidechain key. With a key every track's chain runs as a stream
    /// in the mixer graph instead of pulling for itself: a new path for the tracks, so what it costs is measured.
    @Test func withAKey() async throws {
        #expect(KeyedGateAU.registered)
        let rate = 48_000.0, seconds = 10, n = Int(rate) * 20
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: rate,
                                 channelMask: nil, dataOffset: 0, frames: Int64(n), chunks: [], bext: nil, ixml: nil, markers: [])
        let lowpass = PluginID("aufx/lpas/appl")!, limiter = PluginID("aufx/lmtr/appl")!
        for (tracks, buses) in [(16, 4), (64, 8)] {
            for keyed in [false, true, false, true] {
                let pool = SourcePool()
                var made: Project?
                for t in 0..<tracks {
                    let src = SourceRef(name: "s\(t)", path: "/dev/null", info: info)
                    pool.register(src.id, memory: (0..<(n * 2)).map { Float(0.01 * sin(Double($0 + t * 977) * 0.01)) }, channels: 2)
                    if made == nil { made = Project(source: src) } else { _ = made!.addTrack(source: src, name: "t\(t)") }
                }
                var p = made!
                for b in 0..<buses {
                    _ = try p.addBus(name: "bus \(b)")
                    p.buses[b].inserts = [Insert(plugin: limiter, name: "p"), Insert(plugin: lowpass, name: "p")]
                }
                for t in 0..<tracks {
                    p.tracks[t].inserts = [Insert(plugin: lowpass, name: "p"), Insert(plugin: limiter, name: "p")]
                    try p.setTrackRoute(p.tracks[t].id, output: .some(p.buses[t % buses].id))
                }
                // The gate is there both times; only the key differs, so only the path differs.
                p.tracks[0].inserts.append(Insert(plugin: KeyedGateAU.plugin, name: "gate"))
                if keyed { try p.setKey(strip: p.tracks[0].id, insert: p.tracks[0].inserts[2].id, key: p.tracks[1].id) }
                let host = await InsertHost.make(for: p)
                let plan = PlanCompiler.compile(p, pool: pool, inserts: host)
                #expect(plan.keyCount == (keyed ? 1 : 0))
                var times: [Double] = []
                let blocks = seconds * Int(rate) / 512
                for b in 0..<blocks {
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    _ = plan.render(from: Frame(b * 512), frames: 512)
                    if b > 0 { times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9) }
                }
                let sorted = times.sorted()
                print(String(format: "MIXER KEY %2d tracks × 2 plugins, %d buses × 2: %@  block median %.3f ms, mean %.3f, 99 %% under %.3f; mixer latency %lld frames",
                             tracks, buses, (keyed ? "with one key (all strips in the graph)" : "no key (tracks pull for themselves) ") as NSString,
                             sorted[sorted.count / 2] * 1000, times.reduce(0, +) / Double(times.count) * 1000, sorted[Int(Double(sorted.count) * 0.99)] * 1000, plan.totalLatency))
            }
        }
    }

    /// What the mixer adds per block on top of rendering the tracks: sums into buses, sends, gains, and
    /// delay lines for compensation. Done here with the same vector routines the engine would use.
    @Test func busArithmetic() {
        let frames = 512, ch = 2, tracks = 64, buses = 8, sendsPerTrack = 2, delay = 4_096
        var rng = SystemRandomNumberGenerator()
        let audio = (0..<tracks).map { _ in (0..<(frames * ch)).map { _ in Float.random(in: -0.1...0.1, using: &rng) } }
        var bus = [[Float]](repeating: [Float](repeating: 0, count: frames * ch), count: buses + 1)
        var lines = [[Float]](repeating: [Float](repeating: 0, count: (delay + frames) * ch), count: tracks)
        var scratch = [Float](repeating: 0, count: frames * ch)
        let rounds = 20_000
        let t0 = DispatchTime.now().uptimeNanoseconds
        for r in 0..<rounds {
            for b in bus.indices { vDSP_vclr(&bus[b], 1, vDSP_Length(frames * ch)) }
            for t in 0..<tracks {
                // Compensation: the block goes into the track's delay line and the delayed block comes out.
                lines[t].withUnsafeMutableBufferPointer { l in
                    memmove(l.baseAddress!, l.baseAddress! + frames * ch, delay * ch * MemoryLayout<Float>.size)
                    audio[t].withUnsafeBufferPointer { memcpy(l.baseAddress! + delay * ch, $0.baseAddress!, frames * ch * MemoryLayout<Float>.size) }
                    memcpy(&scratch, l.baseAddress!, frames * ch * MemoryLayout<Float>.size)
                }
                var g = Float(0.7 + Double((t + r) % 3) * 0.1)
                vDSP_vsma(scratch, 1, &g, bus[t % buses], 1, &bus[t % buses], 1, vDSP_Length(frames * ch))
                for s in 0..<sendsPerTrack {
                    var sg = Float(0.2)
                    vDSP_vsma(scratch, 1, &sg, bus[(t + s + 1) % buses], 1, &bus[(t + s + 1) % buses], 1, vDSP_Length(frames * ch))
                }
            }
            for b in 0..<buses { var g = Float(0.9); vDSP_vsma(bus[b], 1, &g, bus[buses], 1, &bus[buses], 1, vDSP_Length(frames * ch)) }
        }
        let per = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9 / Double(rounds)
        print(String(format: "MIXER BASELINE bus arithmetic for %d tracks into %d buses with %d sends each and a %d-frame delay line per track: %.4f ms per 512-frame block (%.2f %% of its time)",
                     tracks, buses, sendsPerTrack, delay, per * 1000, per / (512 / 48_000.0) * 100))
        #expect(bus[buses][0].isFinite)
    }
}
