import Foundation
import Testing
@testable import JammerAgent
@testable import JammerCore

/// The window's Stop (COMFORT 7): a run of steps asked to stop skips the rest, and says why in its own words.
@Suite("Stopping a run of steps")
struct StopStepTests {
    func state() -> EditState {
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 1, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: 480_000, chunks: [], bext: nil, ixml: nil, markers: [])
        return EditState(project: Project(source: SourceRef(name: "a", path: "/dev/null", info: info)))
    }
    let silent: StepRunner.Measure = { _, _ in LoudnessResult(integrated: nil, range: nil, maxMomentary: nil, maxShortTerm: nil, samplePeak: 0, truePeak: 0, duration: 0) }

    @Test("Asked to stop before the second step: the first is done, the second fails as stopped, the third is skipped")
    func stopsBetweenSteps() {
        var s = state()
        var asked = 0
        let steps = [Step(op: "split", params: ["at": .number(1)]), Step(op: "split", params: ["at": .number(2)]), Step(op: "split", params: ["at": .number(3)])]
        let r = StepRunner.run(steps, on: &s, measure: silent, stopped: { asked += 1; return asked > 1 })
        #expect(r.map(\.status) == [.done, .failed, .skipped])
        #expect(r[1].reason == "stopped" && r[1].keyed == KeyedMessage("job.stopped") && r[1].error == "Stopped in Jämmer's window.")
        #expect(s.project.tracks[0].clips.count == 2)
    }

    @Test("Never asked to stop: every step runs, as before")
    func runsWhole() {
        var s = state()
        let r = StepRunner.run([Step(op: "split", params: ["at": .number(1)]), Step(op: "split", params: ["at": .number(2)])], on: &s, measure: silent)
        #expect(r.allSatisfy { $0.status == .done } && s.project.tracks[0].clips.count == 3)
    }
}
