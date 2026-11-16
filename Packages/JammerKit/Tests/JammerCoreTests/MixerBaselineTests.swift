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
