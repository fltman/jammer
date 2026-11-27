import Foundation
import Testing
import JammerCore
@testable import JammerAgent

@Suite("Plugins change places in their chain: set_insert's position")
struct InsertOrderTests {
    func state() -> (EditState, [Insert]) {
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: 48_000, chunks: [], bext: nil, ixml: nil, markers: [])
        var p = Project(source: SourceRef(name: "t", path: "/dev/null", info: info))
        let inserts = ["EQ", "Compressor", "Limiter"].map { Insert(plugin: PluginID("aufx/test/appl")!, name: $0) }
        p.tracks[0].inserts = inserts
        return (EditState(project: p), inserts)
    }
    func move(_ s: inout EditState, _ insert: Insert, to position: Double) -> StepResult {
        StepRunner.run([Step(op: "set_insert", params: ["track": .string(s.project.tracks[0].id.uuidString), "insert": .string(insert.id.uuidString),
                                                       "position": .number(position)])], on: &s, measure: { _, _ in LoudnessResult(integrated: -20, range: 5, maxMomentary: -15, maxShortTerm: -17, samplePeak: -3, truePeak: -2.5, duration: 1) })[0]
    }

    @Test("A plugin moved earlier, later, beyond the end and to where it is: the chain's order, and info's position")
    func positions() {
        var (s, i) = state()
        #expect(move(&s, i[2], to: 0).info["position"] == 0)
        #expect(s.project.tracks[0].inserts.map(\.name) == ["Limiter", "EQ", "Compressor"])
        _ = move(&s, i[2], to: 63)
        #expect(s.project.tracks[0].inserts.map(\.name) == ["EQ", "Compressor", "Limiter"], "beyond the end: last")
        let same = move(&s, i[1], to: 1)
        #expect(same.status == .done && s.project.tracks[0].inserts.map(\.name) == ["EQ", "Compressor", "Limiter"])
        #expect(s.project.tracks[0].inserts.map(\.id) == i.map(\.id), "the inserts themselves, settings and all, are kept")
    }

    @Test("A position outside 0…63 is refused before anything runs")
    func range() {
        #expect(throws: (any Error).self) { try StepRunner.validate(Step(op: "set_insert", params: ["track": .string("x"), "insert": .string("y"), "position": .number(-1)])) }
    }
}
