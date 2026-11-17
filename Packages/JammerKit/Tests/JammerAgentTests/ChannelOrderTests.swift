import Foundation
import Testing
@testable import JammerAgent
@testable import JammerCore

@Suite("A 7.1 or 7.1.4 file without a mask: the order it is heard in")
struct ChannelOrderTests {
    static func state(channels: Int, mask: UInt32? = nil, opened: Bool = true) -> EditState {
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: channels, sampleRate: 48_000,
                                 channelMask: mask, dataOffset: 0, frames: 48_000, chunks: [], bext: nil, ixml: nil, markers: [])
        let ref = SourceRef(name: "bed", path: "/dev/null", info: info)
        return EditState(project: Project(source: opened ? ref.opened() : ref))
    }
    static func run(_ s: inout EditState, _ params: [String: JSONValue]) -> StepResult {
        StepRunner.run([Step(op: "set_layout", params: params)], on: &s, measure: AutomationStepTests.measure)[0]
    }

    @Test("A user's file opens in BS.2051's order, a file Jämmer wrote in the WAV order; set_layout order switches it and says how many files it is for; saved as format 6, and a project saved before reads as the WAV order")
    func choice() throws {
        var s = Self.state(channels: 12)
        #expect(s.project.unmaskedOrder == .bs2051 && s.project.sources[0].speakerOrder?.count == 12)
        #expect(Self.state(channels: 12, opened: false).project.unmaskedOrder == .wav, "Jämmer's own files are in its order")
        let r = Self.run(&s, ["order": .string("wav")])
        #expect(r.status == .done && r.info["unmaskedFiles"] == 1 && s.project.unmaskedOrder == .wav && s.project.sources[0].speakerOrder == nil)
        #expect(Self.run(&s, ["order": .string("bs2051")]).status == .done && s.project.unmaskedOrder == .bs2051)
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s.project)) as! [String: Any]
        #expect(saved["formatVersion"] as? Int == Project.orderFormatVersion)
        let back = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(s.project))
        #expect(back.unmaskedOrder == .bs2051)
        // A project saved before the choice existed has no order on its sources: the WAV order, as it was heard.
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.state(channels: 8, opened: false).project)) as! [String: Any]
        old["formatVersion"] = 4
        let read = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(read.unmaskedOrder == .wav && read.sources[0].speakerOrder == nil)
    }

    @Test("Refused, by name: an order that isn't one, an order where no file leaves it open (a mask, 5.1), and a step that gives neither layout nor order")
    func refusals() {
        var s = Self.state(channels: 8)
        let bad = Self.run(&s, ["order": .string("film")])
        #expect(bad.status == .failed && (bad.error ?? "").contains("bs2051") && (bad.error ?? "").contains("wav"), "\(bad.error ?? "")")
        var masked = Self.state(channels: 8, mask: ChannelLayout.surround71.mask)
        #expect(masked.project.unmaskedOrder == nil)
        let none = Self.run(&masked, ["order": .string("wav")])
        #expect(none.status == .failed && none.keyed?.key == "step.set_layout.no_unmasked", "\(none.error ?? "")")
        var five = Self.state(channels: 6)
        #expect(five.project.unmaskedOrder == nil, "5.1 is the same in both orders")
        #expect(Self.run(&five, ["order": .string("wav")]).status == .failed)
        let neither = Self.run(&s, [:])
        #expect(neither.status == .failed, "\(neither.error ?? "")")
    }
}

@Suite("A change of how a file is heard is a change of the project")
struct SourceHearingEqualityTests {
    @Test("Changing only a source's order or its field mark makes the project unequal, so the window keeps the step and can undo it")
    func equality() {
        var s = ChannelOrderTests.state(channels: 12)
        let before = s.project
        _ = ChannelOrderTests.run(&s, ["order": .string("wav")])
        #expect(s.project != before)
        var f = FieldStepTests.state(channels: 16)
        let plain = f.project
        let id = f.project.tracks[0].id.uuidString
        _ = FieldStepTests.run(&f, "set_track", ["track": .string(id), "field": .number(3)])
        #expect(f.project.sources[0].fieldOrder == 3 && f.project != plain)
    }
}
