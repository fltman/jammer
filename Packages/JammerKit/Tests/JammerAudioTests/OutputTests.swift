import Foundation
import JammerCore
import JammerEngine
import Testing
@testable import JammerAudio

@Suite("Output routing")
struct OutputRoutingTests {
    typealias Slot = AudioOutput.Slot

    @Test("Mono goes to both channels of the stereo pair, stereo to the pair")
    func stereoPair() {
        // One stereo stream.
        #expect(AudioOutput.slots(projectChannels: 1, streams: [2], stereo: (1, 2))
                == [Slot(buffer: 0, channel: 0, source: 0), Slot(buffer: 0, channel: 1, source: 0)])
        #expect(AudioOutput.slots(projectChannels: 2, streams: [2], stereo: nil)
                == [Slot(buffer: 0, channel: 0, source: 0), Slot(buffer: 0, channel: 1, source: 1)])
        // An interface whose monitors are on outputs 3–4, spread over two streams.
        #expect(AudioOutput.slots(projectChannels: 2, streams: [2, 2], stereo: (3, 4))
                == [Slot(buffer: 1, channel: 0, source: 0), Slot(buffer: 1, channel: 1, source: 1)])
        // A preferred pair outside the device falls back to the first two channels.
        #expect(AudioOutput.slots(projectChannels: 2, streams: [8], stereo: (9, 10))
                == [Slot(buffer: 0, channel: 0, source: 0), Slot(buffer: 0, channel: 1, source: 1)])
    }

    @Test("Mono devices, multichannel projects, no channels")
    func edges() {
        #expect(AudioOutput.slots(projectChannels: 2, streams: [1], stereo: nil) == [Slot(buffer: 0, channel: 0, source: 0)])
        #expect(AudioOutput.slots(projectChannels: 1, streams: [1], stereo: nil) == [Slot(buffer: 0, channel: 0, source: 0)])
        #expect(AudioOutput.slots(projectChannels: 6, streams: [4, 4], stereo: (1, 2)).map(\.source) == [0, 1, 2, 3, 4, 5])
        #expect(AudioOutput.slots(projectChannels: 6, streams: [4, 4], stereo: (1, 2)).last == Slot(buffer: 1, channel: 1, source: 5))
        #expect(AudioOutput.slots(projectChannels: 2, streams: [], stereo: nil).isEmpty)
    }
}

/// Plays through the real default output device, silently (gain 0).
/// Off by default: `JAMMER_DEVICE_TESTS=1 swift test --filter DeviceTests`.
@Suite("Device", .enabled(if: ProcessInfo.processInfo.environment["JAMMER_DEVICE_TESTS"] != nil))
@MainActor
struct DeviceTests {
    @Test("The HAL IOProc plays the plan in real time and stops at the end")
    func halPlayback() async throws {
        let sr = 48_000.0
        let frames = Int64(sr * 1.5)
        let src = jm_source_create_memory([Float](repeating: 0.25, count: Int(frames) * 2), frames, 2)
        defer { jm_source_release(src) }
        let plan = jm_plan_create(2, sr)
        let s = jm_plan_add_source(plan, src)
        let t = jm_plan_add_track(plan, 1, false)
        jm_plan_add_clip(plan, t, s, 0, 0, frames, 1, 0, 0, JM_FADE_LINEAR)
        jm_plan_finalize(plan)
        defer { jm_plan_release(plan) }

        let out = AudioOutput(channels: 2, sampleRate: sr)
        out.setGain(0) // never audible
        jm_engine_set_plan(out.engine, plan)
        try out.play(from: 0)
        #expect(out.path == .hal, "Fell back to the audio unit")
        print("DEVICE  \(out.deviceName ?? "?") at \(out.deviceRate) Hz via \(out.path?.rawValue ?? "?")")
        // Bluetooth devices take a while to wake: wait for audio to flow, then check the rate.
        for _ in 0..<100 where out.playhead == 0 { try await Task.sleep(for: .milliseconds(10)) }
        let h0 = out.playhead, t0 = ContinuousClock.now
        try await Task.sleep(for: .milliseconds(400))
        let h1 = out.playhead, d = ContinuousClock.now - t0
        let elapsed = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        let played = Double(h1 - h0) / sr
        print("DEVICE  played \(played) s in \(elapsed) s")
        #expect(h0 > 0)
        #expect(abs(played - elapsed) < 0.06, "played \(played) s in \(elapsed) s")
        for _ in 0..<60 where out.isPlaying { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!out.isPlaying)
        #expect(out.playhead == frames)
        #expect(out.underruns == 0)
        out.stopDevice()
    }
}
