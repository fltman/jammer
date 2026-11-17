import AudioToolbox
import Foundation
import JammerEngine
import Testing

/// A stereo test signal with distinct, exactly representable values per frame and channel.
private func ramp(frames: Int, channels: Int = 2, seed: Int = 0) -> [Float] {
    (0..<(frames * channels)).map { i in Float(((i + seed) % 65_536) - 32_768) / 32_768 }
}

private func render(_ plan: OpaquePointer, start: Int64 = 0, frames: Int64) -> [Float] {
    var out = [Float](repeating: .nan, count: Int(frames) * Int(jm_plan_channels(plan)))
    #expect(jm_render(plan, start, frames, &out))
    return out
}

@Suite("Engine")
struct EngineTests {
    @Test("An untouched clip renders bit-exactly (null test)")
    func nullTest() {
        let signal = ramp(frames: 100_000)
        let src = jm_source_create_memory(signal, 100_000, 2)
        defer { jm_source_release(src) }
        let plan = jm_plan_create(2, 48_000)
        defer { jm_plan_release(plan) }
        let s = jm_plan_add_source(plan, src)
        let t = jm_plan_add_track(plan, 1, false)
        jm_plan_add_clip(plan, t, s, 0, 0, 100_000, 1, 0, 0, JM_FADE_LINEAR)
        jm_plan_finalize(plan)
        #expect(jm_plan_length(plan) == 100_000)
        #expect(render(plan, frames: 100_000) == signal)
    }

    @Test("Rendering is independent of where the range starts")
    func deterministic() {
        let signal = ramp(frames: 200_000, seed: 7)
        let src = jm_source_create_memory(signal, 200_000, 2)
        defer { jm_source_release(src) }
        let plan = jm_plan_create(2, 48_000)
        defer { jm_plan_release(plan) }
        let s = jm_plan_add_source(plan, src)
        let t = jm_plan_add_track(plan, 0.5, false)
        jm_plan_add_clip(plan, t, s, 1_000, 0, 150_000, 0.8, 4_800, 9_600, JM_FADE_EQUAL_POWER)
        jm_plan_add_clip(plan, t, s, 0, 120_000, 50_000, 1, 2_000, 0, JM_FADE_LINEAR)
        jm_plan_finalize(plan)
        let whole = render(plan, frames: 170_000)
        var pieces: [Float] = []
        var at: Int64 = 0
        for size: Int64 in [1, 333, 65_536, 4_096, 99_999, 35] {
            let n = min(size, 170_000 - at)
            pieces += render(plan, start: at, frames: n)
            at += n
        }
        #expect(at == 170_000)
        #expect(pieces == whole)
    }

    @Test("A cut joins the two halves exactly")
    func cut() {
        let signal = ramp(frames: 10_000, channels: 1)
        let src = jm_source_create_memory(signal, 10_000, 1)
        defer { jm_source_release(src) }
        let plan = jm_plan_create(1, 48_000)
        defer { jm_plan_release(plan) }
        let s = jm_plan_add_source(plan, src)
        let t = jm_plan_add_track(plan, 1, false)
        // Remove frames 3000..<5000.
        jm_plan_add_clip(plan, t, s, 0, 0, 3_000, 1, 0, 0, JM_FADE_LINEAR)
        jm_plan_add_clip(plan, t, s, 5_000, 3_000, 5_000, 1, 0, 0, JM_FADE_LINEAR)
        jm_plan_finalize(plan)
        #expect(render(plan, frames: 8_000) == Array(signal[0..<3_000] + signal[5_000..<10_000]))
    }

    @Test("Mono plays on both channels; muted tracks are silent")
    func channelsAndMute() {
        let mono: [Float] = [0.5, -0.25, 0.125]
        let src = jm_source_create_memory(mono, 3, 1)
        defer { jm_source_release(src) }
        let plan = jm_plan_create(2, 48_000)
        defer { jm_plan_release(plan) }
        let s = jm_plan_add_source(plan, src)
        let a = jm_plan_add_track(plan, 1, false)
        let b = jm_plan_add_track(plan, 1, true)
        jm_plan_add_clip(plan, a, s, 0, 0, 3, 1, 0, 0, JM_FADE_LINEAR)
        jm_plan_add_clip(plan, b, s, 0, 0, 3, 1, 0, 0, JM_FADE_LINEAR)
        jm_plan_finalize(plan)
        #expect(render(plan, frames: 3) == [0.5, 0.5, -0.25, -0.25, 0.125, 0.125])
    }

    @Test("int16 and int24 files decode with exact power-of-two scaling")
    func fileDecoding() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "jm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Raw little-endian int16 and big-endian int24 after a 5-byte header.
        let i16: [Int16] = [0, 1, -1, 32_767, -32_768, 12_345]
        var d16 = Data([1, 2, 3, 4, 5])
        for v in i16 { withUnsafeBytes(of: v.littleEndian) { d16.append(contentsOf: $0) } }
        let p16 = dir.appending(path: "a.raw")
        try d16.write(to: p16)
        let i24: [Int32] = [0, 1, -1, 8_388_607, -8_388_608, -123_456]
        var d24 = Data([9, 9, 9, 9, 9])
        for v in i24 { d24.append(contentsOf: [UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
        let p24 = dir.appending(path: "b.raw")
        try d24.write(to: p24)

        let s16 = try #require(jm_source_open(p16.path, 5, 6, 1, JM_PCM_I16, false))
        defer { jm_source_release(s16) }
        var out = [Float](repeating: 0, count: 6)
        #expect(jm_source_read(s16, 0, 6, &out) == 6)
        #expect(out.map { Int16($0 * 32_768) } == i16)

        let s24 = try #require(jm_source_open(p24.path, 5, 6, 1, JM_PCM_I24, true))
        defer { jm_source_release(s24) }
        #expect(jm_source_read(s24, 0, 6, &out) == 6)
        #expect(out.map { Int32($0 * 8_388_608) } == i24)
        // Reading past the end returns only what exists.
        #expect(jm_source_read(s24, 4, 10, &out) == 2)
    }

    @Test("Playback through the ring delivers the plan, seeks cleanly and stops at the end")
    func playback() throws {
        let frames = 48_000
        let signal = ramp(frames: frames, seed: 3)
        let src = jm_source_create_memory(signal, Int64(frames), 2)
        defer { jm_source_release(src) }
        let plan = jm_plan_create(2, 48_000)
        defer { jm_plan_release(plan) }
        let s = jm_plan_add_source(plan, src)
        let t = jm_plan_add_track(plan, 1, false)
        jm_plan_add_clip(plan, t, s, 0, 0, Int64(frames), 1, 0, 0, JM_FADE_LINEAR)
        jm_plan_finalize(plan)

        let engine = jm_engine_create(2, 48_000, 8_192)
        defer { jm_engine_destroy(engine) }
        jm_engine_set_plan(engine, plan)

        var left = [Float](repeating: 0, count: 512)
        var right = [Float](repeating: 0, count: 512)
        func pull() -> ([Float], [Float]) {
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    let outs: [UnsafeMutablePointer<Float>] = [l.baseAddress!, r.baseAddress!]
                    outs.withUnsafeBufferPointer { jm_engine_pull(engine, $0.baseAddress!, 2, 512) }
                }
            }
            return (left, right)
        }

        /// Like a device: keep calling until the seek is acknowledged and audio is ready.
        func prime() -> Bool {
            for _ in 0..<2_000 where !jm_engine_seek_settled(engine) {
                _ = pull() // silence until the worker has parked
                usleep(500)
            }
            return jm_engine_wait_primed(engine, 2_000)
        }

        jm_engine_play(engine, 1_000)
        #expect(prime())
        let (l, r) = pull()
        let expectedL = (0..<512).map { signal[(1_000 + $0) * 2] }
        let expectedR = (0..<512).map { signal[(1_000 + $0) * 2 + 1] }
        #expect(l == expectedL)
        #expect(r == expectedR)
        #expect(jm_engine_playhead(engine) == 1_512)

        // Seek: nothing from before the seek may leak out.
        jm_engine_play(engine, 40_000)
        #expect(prime())
        let (l2, _) = pull()
        #expect(l2 == (0..<512).map { signal[(40_000 + $0) * 2] })

        // Run to the end: playback stops by itself.
        var guardCount = 0
        while jm_engine_is_playing(engine), guardCount < 1_000 {
            _ = pull()
            guardCount += 1
            if jm_engine_playhead(engine) < Int64(frames) { _ = jm_engine_wait_primed(engine, 50) }
        }
        #expect(!jm_engine_is_playing(engine))
        #expect(jm_engine_playhead(engine) == Int64(frames))
        #expect(jm_engine_take_peak(engine, 0) > 0)
    }

    /// A 48 kHz project played to a device at another rate, pulled like an IOProc would.
    private func playThrough(deviceRate: Double, frames: Int, frequency: Double) -> (out: [Float], playheads: [Int64]) {
        let mono = (0..<frames).map { Float(0.5 * sin(2 * .pi * frequency * Double($0) / 48_000)) }
        let src = jm_source_create_memory(mono, Int64(frames), 1)
        defer { jm_source_release(src) }
        let plan = jm_plan_create(1, 48_000)
        defer { jm_plan_release(plan) }
        let s = jm_plan_add_source(plan, src)
        let t = jm_plan_add_track(plan, 1, false)
        jm_plan_add_clip(plan, t, s, 0, 0, Int64(frames), 1, 0, 0, JM_FADE_LINEAR)
        jm_plan_finalize(plan)
        let engine = jm_engine_create(1, 48_000, 16_384)
        defer { jm_engine_destroy(engine) }
        jm_engine_set_plan(engine, plan)
        var buffers: [Int32] = [0], channels: [Int32] = [0], sources: [Int32] = [0]
        jm_engine_set_output(engine, deviceRate, &buffers, &channels, &sources, 1)
        #expect(jm_engine_output_rate(engine) == deviceRate)

        var out: [Float] = [], playheads: [Int64] = []
        var block = [Float](repeating: 0, count: 256)
        func pull() {
            block.withUnsafeMutableBufferPointer { b in
                let outs: [UnsafeMutablePointer<Float>] = [b.baseAddress!]
                outs.withUnsafeBufferPointer { jm_engine_pull(engine, $0.baseAddress!, 1, 256) }
            }
        }
        jm_engine_play(engine, 0)
        for _ in 0..<2_000 where !jm_engine_seek_settled(engine) { pull(); usleep(500) }
        #expect(jm_engine_wait_primed(engine, 2_000))
        var guardCount = 0
        while jm_engine_is_playing(engine), guardCount < 10_000 {
            pull()
            out += block
            playheads.append(jm_engine_playhead(engine))
            guardCount += 1
            _ = jm_engine_wait_primed(engine, 20)
        }
        // Drop the silent tail of the last block.
        while let last = out.last, last == 0 { out.removeLast() }
        return (out, playheads)
    }

    @Test("A device at another rate gets resampled audio; the playhead stays in project frames", arguments: [44_100.0, 96_000.0])
    func resampledPlayback(deviceRate: Double) {
        let frames = 48_000
        let (out, playheads) = playThrough(deviceRate: deviceRate, frames: frames, frequency: 1_000)
        // One second of project audio is one second at the device rate.
        #expect(abs(out.count - Int(deviceRate)) < 64)
        #expect(playheads.last == Int64(frames))
        #expect(zip(playheads, playheads.dropFirst()).allSatisfy { $0 <= $1 })
        // Still a 1 kHz tone: count rising zero crossings in the middle.
        let mid = Array(out[Int(deviceRate * 0.25)..<Int(deviceRate * 0.75)])
        let crossings = zip(mid, mid.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        #expect(abs(crossings - 500) <= 1)
        let peak = mid.map(abs).max() ?? 0
        #expect(abs(peak - 0.5) < 0.01)
    }

    @Test("The IOProc routes into interleaved device buffers: mono to both stereo channels, the rest silent")
    func ioprocRouting() {
        let frames = 4_096
        let mono = (0..<frames).map { Float($0 % 512 - 256) / 512 }
        let src = jm_source_create_memory(mono, Int64(frames), 1)
        defer { jm_source_release(src) }
        let plan = jm_plan_create(1, 48_000)
        defer { jm_plan_release(plan) }
        let s = jm_plan_add_source(plan, src)
        let t = jm_plan_add_track(plan, 1, false)
        jm_plan_add_clip(plan, t, s, 0, 0, Int64(frames), 1, 0, 0, JM_FADE_LINEAR)
        jm_plan_finalize(plan)
        let engine = jm_engine_create(1, 48_000, 8_192)
        defer { jm_engine_destroy(engine) }
        jm_engine_set_plan(engine, plan)
        // A 4-channel interleaved device whose "stereo pair" is channels 3 and 4.
        var buffers: [Int32] = [0, 0], channels: [Int32] = [2, 3], sources: [Int32] = [0, 0]
        jm_engine_set_output(engine, 48_000, &buffers, &channels, &sources, 2)

        let n = 256
        var data = [Float](repeating: 9, count: n * 4)
        func callIOProc() {
            data.withUnsafeMutableBytes { raw in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 4, mDataByteSize: UInt32(n * 16), mData: raw.baseAddress))
                var ts = AudioTimeStamp()
                var input = AudioBufferList()
                _ = jm_engine_ioproc(0, &ts, &input, &ts, &list, &ts, UnsafeMutableRawPointer(engine))
            }
        }
        jm_engine_play(engine, 100)
        for _ in 0..<2_000 where !jm_engine_seek_settled(engine) { callIOProc(); usleep(500) }
        #expect(jm_engine_wait_primed(engine, 2_000))
        callIOProc()
        for i in 0..<n {
            #expect(data[i * 4] == 0 && data[i * 4 + 1] == 0)
            #expect(data[i * 4 + 2] == mono[100 + i] && data[i * 4 + 3] == mono[100 + i])
        }
        #expect(jm_engine_playhead(engine) == 100 + Int64(n))
        // No client data or no buffers: nothing happens, nothing crashes.
        var ts = AudioTimeStamp()
        var empty = AudioBufferList()
        var output = AudioBufferList()
        #expect(jm_engine_ioproc(0, &ts, &empty, &ts, &output, &ts, nil) == noErr)
        #expect(jm_engine_ioproc(0, &ts, &empty, &ts, &output, &ts, UnsafeMutableRawPointer(engine)) == noErr)
    }
}

@Suite("The engine's ring, long and short")
struct RingLengthTests {
    @Test("The ring made short and long and short again while it plays: every frame comes out once, in order, the same samples as an unbroken render; and while short it is never far ahead")
    func shortAndLong() throws {
        let frames = 160_000
        var signal = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames { signal[i * 2] = Float(0.2 * sin(2 * .pi * 220 * Double(i) / 48_000)); signal[i * 2 + 1] = Float(i % 997) / 2_000 }
        let src = jm_source_create_memory(signal, Int64(frames), 2)
        defer { jm_source_release(src) }
        let plan = jm_plan_create(2, 48_000)
        defer { jm_plan_release(plan) }
        let t = jm_plan_add_track(plan, 1, false)
        jm_plan_add_clip(plan, t, jm_plan_add_source(plan, src), 0, 0, Int64(frames), 1, 0, 0, JM_FADE_LINEAR)
        jm_plan_finalize(plan)
        let engine = jm_engine_create(2, 48_000, 16_384)
        defer { jm_engine_destroy(engine) }
        jm_engine_set_plan(engine, plan)
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
        #expect(jm_engine_wait_primed(engine, 2_000))
        var got: [Float] = []
        var mostWhileShort: Int64 = 0
        let short: Int32 = 960                                 // 20 ms
        for round in 0..<480 {
            // Long for 80 pulls, short for 80 (more than the whole ring, so it has time to drain), and so on: six changes while it plays.
            let brief = (round / 80) % 2 == 1
            jm_engine_set_ahead(engine, brief ? short : 0)
            // Like a device that never runs dry: wait for the worker rather than take silence.
            for _ in 0..<4_000 where jm_engine_buffered(engine) < 256 { usleep(200) }
            try #require(jm_engine_buffered(engine) >= 256, "the worker stopped feeding the ring (round \(round))")
            // Some pulls into a short stretch the ring has drained to its short length.
            if brief, round % 80 > 72 { mostWhileShort = max(mostWhileShort, jm_engine_buffered(engine)) }
            pull()
            for i in 0..<256 { got.append(left[i]); got.append(right[i]) }
        }
        #expect(got == Array(signal[0..<got.count]), "a frame was skipped, repeated or changed")
        #expect(mostWhileShort > 0 && mostWhileShort <= Int64(short), "while short the ring was \(mostWhileShort) frames ahead")
        #expect(jm_engine_underruns(engine) == 0)
    }
}
