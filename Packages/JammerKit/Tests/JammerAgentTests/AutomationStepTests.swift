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
            // A pan lane and a mute lane beside the gain lane, each its own; clearing one leaves the others.
            r = Self.run(&s, "set_automation", ["strip": strip, "param": .string("pan"), "points": Self.pairs([(0, -1), (5, 1)])])
            #expect(r.status == .done && r.info["points"] == 2)
            r = Self.run(&s, "set_automation", ["strip": strip, "param": .string("mute"), "points": Self.pairs([(1, 1), (2, 0)])])
            #expect(r.status == .done && s.project.lanes(of: t).count == 3 && s.project.lane(strip: t, param: .mute)?.shape == .hold)
            r = Self.run(&s, "clear_automation", ["strip": strip, "param": .string("pan")])
            #expect(r.info["removed"] == 2 && s.project.lanes(of: t).map(\.param.rawValue).sorted() == ["gain", "mute"])
            r = Self.run(&s, "clear_automation", ["strip": strip, "param": .string("mute")])
            #expect(r.info["removed"] == 2)
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
            #expect(said(["strip": strip, "param": .string("level"), "points": Self.pairs([(1, 0)])]).contains("\"param\" must be one of gain, pan, mute, send"))
            #expect(said(["strip": strip, "param": .string("send"), "points": Self.pairs([(1, 0)])]).contains("\"to\" is needed with param send"))
            #expect(said(["strip": strip, "param": .string("send"), "to": .string(UUID().uuidString), "points": Self.pairs([(1, 0)])]).contains("\"to\": that strip has no send to"))
            #expect(said(["strip": strip, "to": .string(UUID().uuidString), "points": Self.pairs([(1, 0)])]).contains("\"to\" goes with param send only"))
            #expect(said(["strip": strip, "param": .string("pan"), "points": Self.pairs([(1, 1.5)])]).contains("points[0] has the value 1.5; a pan is −1 (left) to 1 (right)"))
            #expect(said(["strip": strip, "param": .string("mute"), "points": Self.pairs([(1, 0.5)])]).contains("points[0] has the value 0.5; a mute is 1 (muted) or 0 (heard)"))
            #expect(said(["strip": .string("master"), "param": .string("mute"), "points": Self.pairs([(1, 1)])]).contains("\"param\" is gain or plugin for the master"))
            var withGroup = s.project
            let group = try! withGroup.addVCA(name: "V"), bus = try! withGroup.addBus(name: "B")
            try! withGroup.setSend(from: withGroup.tracks[0].id, to: bus.id)
            func saidIn(_ params: [String: JSONValue]) -> String {
                let step = Step(op: "set_automation", params: params)
                do { try StepRunner.validate(step); try StepRunner.check(step, against: withGroup); return "" } catch { return error.localizedDescription }
            }
            #expect(saidIn(["strip": .string(group.id.uuidString), "param": .string("pan"), "points": Self.pairs([(1, 0)])]).contains("gain or mute for a VCA group"))
            #expect(saidIn(["strip": .string(group.id.uuidString), "param": .string("mute"), "points": Self.pairs([(1, 1)])]) == "")
            #expect(saidIn(["strip": strip, "param": .string("send"), "to": .string(bus.id.uuidString), "points": Self.pairs([(1, -6)])]) == "")
            var es = EditState(project: withGroup)
            let done = Self.run(&es, "set_automation", ["strip": strip, "param": .string("send"), "to": .string(bus.id.uuidString), "points": Self.pairs([(1, -6), (2, 0)])])
            #expect(done.status == .done && done.info["points"] == 2 && es.project.lane(strip: withGroup.tracks[0].id, param: .send, to: bus.id) != nil)
            let cleared = Self.run(&es, "clear_automation", ["strip": strip, "param": .string("send"), "to": .string(bus.id.uuidString)])
            #expect(cleared.info["removed"] == 2)
            #expect(said(["strip": strip, "param": .string("pan"), "points": Self.pairs([(1, -1), (2, 1)])]) == "")
            #expect(said(["strip": strip, "param": .string("mute"), "points": Self.pairs([(1, 1), (2, 0)])]) == "")
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

    @Test("A lane on a plugin's parameter, by step: the plugin by its name, the parameter by its name, kept by the plugin's own identifier; refused with the reason where the plugin or the parameter isn't there, a value is outside the parameter's range, or the fields are missing")
    func pluginParameter() throws {
        Operations.$automationForThisTask.withValue(true) {
            var s = Self.state()
            let track = s.project.tracks[0].id
            s.project.tracks[0].inserts = [Insert(plugin: PluginID("aufx/lpas/appl")!, name: "AULowpass")]
            let insert = s.project.tracks[0].inserts[0].id
            // By name, and by the parameter's display name.
            let made = Self.run(&s, "set_automation", ["strip": .string(track.uuidString), "param": .string("plugin"), "insert": .string("AULowpass"),
                                                       "parameter": .string("cutoff frequency"), "points": Self.pairs([(0, 20_000), (8, 300)])])
            #expect(made.status == .done && made.info["points"] == 2, "\(made.error ?? "")")
            let lane = s.project.pluginLanes(of: track).first
            #expect(lane?.insert == insert && lane?.parameter?.isEmpty == false && lane?.points.map(\.value) == [20_000, 300])
            // Again by the identifier it was kept by: the same lane, not a second one.
            let again = Self.run(&s, "set_automation", ["strip": .string(track.uuidString), "param": .string("plugin"), "insert": .string(insert.uuidString),
                                                        "parameter": .string(lane?.parameter ?? ""), "points": Self.pairs([(0, 10_000)])])
            #expect(again.status == .done && s.project.pluginLanes(of: track).count == 1 && s.project.pluginLanes(of: track)[0].points.count == 1)
            // Refused, each with what is wrong.
            func refused(_ params: [String: JSONValue], _ words: String, reason: String? = nil) {
                var all: [String: JSONValue] = ["strip": .string(track.uuidString), "param": .string("plugin"), "points": Self.pairs([(0, 1_000)])]
                for (k, v) in params { all[k] = v }
                let r = Self.run(&s, "set_automation", all)
                #expect(r.status == .failed && (r.error ?? "").contains(words), "\(words): \(r.error ?? "not refused")")
                if let reason { #expect(r.reason == reason, "\(r.reason ?? "")") }
            }
            refused([:], "\"insert\" and \"parameter\" are needed")
            refused(["insert": .string("Nothing"), "parameter": .string("x")], "no plugin Nothing", reason: "not_found")
            refused(["insert": .string("AULowpass"), "parameter": .string("warmth")], "no parameter warmth", reason: "not_found")
            refused(["insert": .string("AULowpass"), "parameter": .string("cutoff frequency"), "points": Self.pairs([(0, 9e9)])], "the parameter takes")
            let stray = Self.run(&s, "set_automation", ["strip": .string(track.uuidString), "insert": .string("AULowpass"), "points": Self.pairs([(0, 0)])])
            #expect(stray.status == .failed && (stray.error ?? "").contains("go with param plugin only"))
            // Switched off and cleared.
            let off = Self.run(&s, "set_automation", ["strip": .string(track.uuidString), "param": .string("plugin"), "insert": .string("AULowpass"),
                                                      "parameter": .string("cutoff frequency"), "points": Self.pairs([]), "enabled": .bool(false)])
            #expect(off.status == .done && s.project.pluginLanes(of: track).isEmpty && s.project.liveLanes.count == 1, "\(off.error ?? "")")
            let gone = Self.run(&s, "clear_automation", ["strip": .string(track.uuidString), "param": .string("plugin"), "insert": .string("AULowpass"), "parameter": .string("cutoff frequency")])
            #expect(gone.status == .done && gone.info["removed"] == 1 && s.project.liveLanes.isEmpty, "\(gone.error ?? "")")
        }
    }
}
