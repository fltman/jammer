import Foundation
import Testing
@testable import JammerAgent
@testable import JammerCore

@Suite("Sound fields: the steps that mark and turn them")
struct FieldStepTests {
    static func state(channels: Int) -> EditState {
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: channels, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: 480_000, chunks: [], bext: nil, ixml: nil, markers: [])
        return EditState(project: Project(source: SourceRef(name: "field", path: "/dev/null", info: info)))
    }
    static func run(_ s: inout EditState, _ op: String, _ params: [String: JSONValue]) -> StepResult {
        StepRunner.run([Step(op: op, params: params)], on: &s, measure: AutomationStepTests.measure)[0]
    }

    @Test("Making a document Ambisonics marks its files of that size as fields; set_track field marks or unmarks, and refuses a file of another size")
    func marking() {
        var s = Self.state(channels: 16)
        #expect(s.project.sources[0].fieldOrder == nil, "nothing in a WAV says it is a field")
        let r = Self.run(&s, "set_layout", ["layout": .string("ambix3")])
        #expect(r.status == .done && s.project.sources[0].fieldOrder == 3 && r.info["fields"] == 1)
        #expect(Self.run(&s, "set_layout", ["layout": .string("7.1.4")]).status == .done && s.project.sources[0].fieldOrder == 3, "a field stays a field in loudspeakers, decoded")
        let id = s.project.tracks[0].id.uuidString
        #expect(Self.run(&s, "set_track", ["track": .string(id), "field": .number(0)]).status == .done && s.project.sources[0].fieldOrder == nil)
        let wrong = Self.run(&s, "set_track", ["track": .string(id), "field": .number(1)])
        #expect(wrong.status == .failed && wrong.reason == "bad_request" && wrong.keyed?.key == "step.set_track.fieldSize", "\(wrong.error ?? "")")
        #expect(Self.run(&s, "set_track", ["track": .string(id), "field": .number(3)]).status == .done && s.project.sources[0].fieldOrder == 3)
    }

    @Test("A field turned by set_track (fixed) and taken back; a turn on a track without a field is refused with the reason; the project is saved as format 5 and an older reader would refuse it")
    func turning() throws {
        var s = Self.state(channels: 16)
        let id = s.project.tracks[0].id.uuidString
        let plain = Self.run(&s, "set_track", ["track": .string(id), "yaw": .number(30)])
        #expect(plain.status == .failed && plain.reason == "no_field" && plain.keyed?.key == "error.automation.noField")
        #expect(Self.run(&s, "set_track", ["track": .string(id), "field": .number(3), "yaw": .number(30), "pitch": .number(-10)]).status == .done)
        #expect(s.project.tracks[0].rotation == FieldRotation(yaw: 30, pitch: -10, roll: 0))
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s.project)) as! [String: Any]
        #expect(saved["formatVersion"] as? Int == Project.fieldFormatVersion)
        #expect(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(s.project)) == s.project)
        #expect(Self.run(&s, "set_track", ["track": .string(id), "turned": .bool(false)]).status == .done && s.project.tracks[0].rotation == nil)
        #expect(Self.run(&s, "set_track", ["track": .string(id), "roll": .number(200)]).status == .failed, "roll is −180 to 180")
    }

    @Test("A yaw lane on a field (debug builds): written, and refused on a track that plays no field")
    func lanes() {
        Operations.$automationForThisTask.withValue(true) {
            var s = Self.state(channels: 16)
            let id = s.project.tracks[0].id.uuidString
            let refused = Self.run(&s, "set_automation", ["strip": .string(id), "param": .string("yaw"), "points": AutomationStepTests.pairs([(0, 0), (2, 90)])])
            #expect(refused.status == .failed && refused.reason == "no_field")
            _ = Self.run(&s, "set_layout", ["layout": .string("ambix3")])
            let r = Self.run(&s, "set_automation", ["strip": .string(id), "param": .string("yaw"), "points": AutomationStepTests.pairs([(0, 0), (2, 90)])])
            #expect(r.status == .done && s.project.lane(strip: s.project.tracks[0].id, param: .yaw)?.points.count == 2, "\(r.error ?? "")")
        }
    }
}
