import Foundation
import Testing
@testable import JammerAgent
@testable import JammerCore

@Suite("Automation: the steps an agent writes lanes with")
struct AutomationStepTests {
    static let measure: StepRunner.Measure = { _, _ in
        LoudnessResult(integrated: -20, range: 5, maxMomentary: -15, maxShortTerm: -17, samplePeak: -3, truePeak: -2.5, duration: 1)
    }
    static func state(seconds: Double = 10) -> EditState {
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: Int64(seconds * 48_000), chunks: [], bext: nil, ixml: nil, markers: [])
        return EditState(project: Project(source: SourceRef(name: "t", path: "/dev/null", info: info)))
    }
    static func pairs(_ list: [(Double, Double)]) -> JSONValue { .array(list.map { .array([.number($0.0), .number($0.1)]) }) }
    static func run(_ s: inout EditState, _ op: String, _ params: [String: JSONValue]) -> StepResult {
        StepRunner.run([Step(op: op, params: params)], on: &s, measure: measure)[0]
    }

    @Test("A build without automation doesn't know the steps; a build with it lists them, closed, with rationale")
    func gated() {
        #expect(Operations.named("set_automation") == nil && Operations.named("clear_automation") == nil)
        #expect(throws: (any Error).self) { try StepRunner.validate(Step(op: "set_automation", params: ["strip": .string("master"), "points": Self.pairs([(0, 0)])])) }
        Operations.$automationForThisTask.withValue(true) {
            for name in ["set_automation", "clear_automation"] {
                let spec = Operations.named(name)
                #expect(spec != nil, "\(name)")
                var params: [String: JSONValue] = [:]
                for p in spec?.params ?? [] where p.required { params[p.name] = UnknownParameterTests.value(for: p) }
                #expect(throws: Never.self) { try StepRunner.validate(Step(op: name, params: params)) }
                var stranger = params
                stranger["notAParameterOfAnything"] = .number(1)
                #expect(throws: (any Error).self) { try StepRunner.validate(Step(op: name, params: stranger)) }
                var why = params
                why[AgentAPI.rationale] = .string("the music should be under the speech here")
                #expect(throws: Never.self) { try StepRunner.validate(Step(op: name, params: why)) }
            }
            // Not the assistant's yet.
            #expect(Operations.all.contains { $0.name == "set_automation" })
        }
    }

    @Test("Writing, replacing a range, switching off and clearing: each one step, each only what it says")
    func writing() {
        Operations.$automationForThisTask.withValue(true) {
            var s = Self.state()
            let t = s.project.tracks[0].id
            let strip: JSONValue = .string(t.uuidString)
            var r = Self.run(&s, "set_automation", ["strip": strip, "points": Self.pairs([(0, 0), (2, -6), (4, -12), (6, 0)])])
            #expect(r.status == .done && r.info["points"] == 4)
            // Only what is inside 1…5 s is replaced.
            r = Self.run(&s, "set_automation", ["strip": strip, "points": Self.pairs([(3, -3)]), "start": .number(1), "end": .number(5)])
            #expect(r.status == .done && r.info["points"] == 3)
            #expect(s.project.lane(strip: t, param: .gain)?.points.map(\.value) == [0, -3, 0])
            // The master, by its name.
            r = Self.run(&s, "set_automation", ["strip": .string("master"), "points": Self.pairs([(0, -1)])])
            #expect(r.status == .done && s.project.lane(strip: Master.id, param: .gain) != nil)
            // Off and on again: the points stay.
            r = Self.run(&s, "set_automation", ["strip": strip, "points": .array([]), "enabled": .bool(false)])
            #expect(r.status == .done && s.project.lane(strip: t, param: .gain)?.enabled == false && r.info["points"] == 3)
            r = Self.run(&s, "set_automation", ["strip": strip, "points": .array([]), "enabled": .bool(true)])
            #expect(s.project.lane(strip: t, param: .gain)?.enabled == true)
            // An empty list with a range takes that range's points away.
            r = Self.run(&s, "set_automation", ["strip": strip, "points": .array([]), "start": .number(2), "end": .number(4)])
            #expect(r.status == .done && r.info["points"] == 2)
            // Clearing: one lane of one strip; the master's is still there.
            r = Self.run(&s, "clear_automation", ["strip": strip, "param": .string("gain")])
            #expect(r.status == .done && r.info["removed"] == 2 && s.project.lane(strip: t, param: .gain) == nil)
            #expect(s.project.lane(strip: Master.id, param: .gain) != nil)
            // A clear needs to be told which strip and which lane.
            #expect(throws: (any Error).self) { try StepRunner.validate(Step(op: "clear_automation", params: ["strip": strip])) }
            #expect(throws: (any Error).self) { try StepRunner.validate(Step(op: "clear_automation", params: ["param": .string("gain")])) }
        }
    }

    @Test("Refused before anything runs, with the name of the field")
    func refused() {
        Operations.$automationForThisTask.withValue(true) {
            let s = Self.state(seconds: 10)
            let strip: JSONValue = .string(s.project.tracks[0].id.uuidString)
            func said(_ params: [String: JSONValue], op: String = "set_automation") -> String {
                let step = Step(op: op, params: params)
                do { try StepRunner.validate(step); try StepRunner.check(step, against: s.project); return "" } catch { return error.localizedDescription }
            }
            #expect(said(["strip": strip, "points": Self.pairs([(0, 0), (11, -6)])]).contains("points[1] is at 11 s, after the document's end (10 s)"))
            #expect(said(["strip": strip, "points": Self.pairs([(0, 30)])]).contains("points[0] has the value 30"))
            #expect(said(["strip": strip, "points": Self.pairs([(-1, 0)])]).contains("points[0]"))
            #expect(said(["strip": strip, "points": .array([.array([.number(1)])])]).contains("pairs"))
            #expect(said(["strip": strip, "points": .array([.number(1), .number(2)])]).contains("pairs"))
            #expect(said(["strip": strip, "points": Self.pairs([(6, 0)]), "start": .number(1), "end": .number(5)]).contains("points[0] is at 6 s, outside \"start\"…\"end\""))
            #expect(said(["strip": strip, "points": Self.pairs([(1, 0)]), "start": .number(1)]).contains("go together"))
            #expect(said(["strip": strip, "points": Self.pairs([(1, 0)]), "start": .number(1), "end": .number(12)]).contains("\"end\" is at 12 s"))
            #expect(said(["strip": .string(UUID().uuidString), "points": Self.pairs([(1, 0)])]).contains("\"strip\""))
            #expect(said(["strip": strip, "param": .string("pan"), "points": Self.pairs([(1, 0)])]).contains("\"param\" must be one of gain"))
            #expect(said(["strip": strip, "points": Self.pairs([(1, 0)])]) == "")
            // Two points at one time: refused when it runs, nothing changed.
            var t = s
            let r = Self.run(&t, "set_automation", ["strip": strip, "points": Self.pairs([(1, 0), (1, -3)])])
            #expect(r.status == .failed && r.error?.contains("two points") == true && t.project == s.project)
        }
    }

    @Test("Lining up one track under automation is done, and says that the lane stayed where it was")
    func warned() {
        // Two recorders of one sound, the second started 0.5 s later.
        let n = 48_000 * 20, late = 24_000
        var seed: UInt32 = 12_345
        let noise = (0..<(n + late)).map { _ -> Float in seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(Int32(bitPattern: seed)) / Float(Int32.max) * 0.3 }
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: Int64(n), chunks: [], bext: nil, ixml: nil, markers: [])
        let pool = SourcePool()
        let host = SourceRef(name: "Host", path: "/dev/null", info: info), guest = SourceRef(name: "Guest", path: "/dev/null", info: info)
        pool.register(host.id, memory: (0..<n).flatMap { [noise[$0], noise[$0]] }, channels: 2)
        pool.register(guest.id, memory: (0..<n).flatMap { [noise[$0 + late] * 0.5, noise[$0 + late] * 0.5] }, channels: 2)
        var p = Project(source: host)
        p.addTrack(source: guest)
        Operations.$automationForThisTask.withValue(true) {
            var s = EditState(project: p, pool: pool)
            let guestID = s.project.tracks[1].id
            _ = Self.run(&s, "set_automation", ["strip": .string(guestID.uuidString), "points": Self.pairs([(1, 0), (2, -6)])])
            let lane = s.project.lane(strip: guestID, param: .gain)
            let r = Self.run(&s, "align_tracks", ["reference": .string(s.project.tracks[0].id.uuidString), "window": .number(10)])
            #expect(r.status == .done && s.project.tracks[1].clips[0].start == Frame(late))
            #expect(r.warnings.count == 1 && r.warnings[0].contains("The automation on Guest stays where it is on the timeline (2 points)"))
            #expect(s.project.lane(strip: guestID, param: .gain) == lane)
            // Without a lane on the moved track there is nothing to say.
            var plain = EditState(project: p, pool: pool)
            #expect(Self.run(&plain, "align_tracks", ["reference": .string(p.tracks[0].id.uuidString), "window": .number(10)]).warnings.isEmpty)
            // A delete that closes the timeline moves the lane with the sound: no warning.
            #expect(Self.run(&s, "delete", ["start": .number(0.2), "end": .number(0.4)]).warnings.isEmpty)
        }
    }
}
