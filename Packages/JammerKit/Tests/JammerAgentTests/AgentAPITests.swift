import Foundation
import JammerCore
import Testing
@testable import JammerAgent

@Suite("Agent API")
struct AgentAPITests {
    private func request(_ method: String = "GET", _ path: String = "/api/v1/status", headers: [String: String] = [:], body: Data = Data()) -> AgentAPI.Request {
        var h = ["host": "127.0.0.1:9003"]
        for (k, v) in headers { h[k.lowercased()] = v }
        return AgentAPI.Request(method: method, path: path, headers: h, body: body)
    }

    @Test("Ports: 9003 first, then 9301–9319, never Glimmer's or Flimmer's")
    func ports() {
        #expect(AgentAPI.ports.first == 9003)
        #expect(AgentAPI.ports.dropFirst().allSatisfy { (9301...9319).contains($0) })
        #expect(AgentAPI.ports.count == 20)
        #expect(AgentAPI.agentPrompt(port: 9003) == "Learn all about Jämmer and how to interact with it: fetch and follow this guide http://127.0.0.1:9003/jammer")
    }

    @Test("Security: host, origin and agent header")
    func security() {
        #expect(AgentAPI.check(request(), port: 9003) == nil)
        #expect(AgentAPI.check(request(headers: ["Host": "localhost:9003"]), port: 9003) == nil)
        #expect(AgentAPI.check(request(headers: ["Host": "evil.example:9003"]), port: 9003)?.status == 403)
        #expect(AgentAPI.check(request(headers: ["Host": "127.0.0.1:9004"]), port: 9003)?.status == 403)
        #expect(AgentAPI.check(request(headers: ["Origin": "https://example.com"]), port: 9003)?.status == 403)
        #expect(AgentAPI.check(request("POST", "/api/v1/documents"), port: 9003)?.code == "forbidden")
        #expect(AgentAPI.check(request("POST", "/api/v1/documents", headers: ["X-Jammer-Agent": "1"]), port: 9003) == nil)
        #expect(AgentAPI.check(request("PUT", "/api/v1/uploads/x", headers: ["X-Jammer-Agent": "0"]), port: 9003)?.status == 403)
    }

    @Test("HTTP parsing: incomplete, complete, query and limits")
    func parsing() {
        let raw = "POST /api/v1/documents?name=T%C3%A5g HTTP/1.1\r\nHost: 127.0.0.1:9003\r\nContent-Length: 5\r\n\r\nhel"
        #expect(AgentAPI.parse(Data(raw.utf8)) == .incomplete)
        guard case .request(let r) = AgentAPI.parse(Data((raw + "lo").utf8)) else { Issue.record("not parsed"); return }
        #expect(r.method == "POST")
        #expect(r.path == "/api/v1/documents")
        #expect(r.query["name"] == "Tåg")
        #expect(r.body == Data("hello".utf8))
        let huge = "POST / HTTP/1.1\r\nContent-Length: \(AgentAPI.maxBody + 1)\r\n\r\n"
        guard case .invalid = AgentAPI.parse(Data(huge.utf8)) else { Issue.record("should refuse"); return }
        let chunked = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
        guard case .invalid = AgentAPI.parse(Data(chunked.utf8)) else { Issue.record("should refuse chunked"); return }
    }

    @Test("Error format matches the series")
    func errorFormat() throws {
        let r = AgentAPI.Response.error(AgentAPI.APIError(422, "step_failed", "Step 1 failed", step: 1))
        #expect(r.status == 422)
        let obj = try #require(try JSONSerialization.jsonObject(with: r.body) as? [String: Any])
        let e = try #require(obj["error"] as? [String: Any])
        #expect(e["code"] as? String == "step_failed")
        #expect(e["step"] as? Int == 1)
        #expect(e["message"] as? String == "Step 1 failed")
    }

    @Test("Steps are checked before anything runs")
    func stepValidation() throws {
        func parse(_ json: String) -> AgentAPI.APIError? {
            do { _ = try AgentAPI.parseSteps(Data(json.utf8)); return nil } catch { return error }
        }
        #expect(parse(#"{"steps": [{"op": "delete", "params": {"start": 0, "end": 1}}]}"#) == nil)
        #expect(parse(#"{"steps": []}"#)?.code == "bad_request")
        #expect(parse(#"{"steps": [{"op": "explode"}]}"#)?.status == 404)
        #expect(parse(#"{"steps": [{"op": "gain"}]}"#)?.step == 0) // missing db
        #expect(parse(#"{"steps": [{"op": "gain", "params": {"db": "loud"}}]}"#)?.code == "bad_request")
        #expect(parse(#"{"steps": [{"op": "gain", "params": {"db": 1, "volume": 2}}]}"#)?.code == "bad_request")
        #expect(parse(#"{"steps": [{"op": "fade_in", "params": {"shape": "wobbly"}}]}"#)?.code == "bad_request")
        #expect(parse(#"{"steps": [{"op": "select", "params": {"start": -1, "end": 2}}]}"#)?.code == "bad_request")
        let ok = try AgentAPI.parseSteps(Data(#"{"steps": [{"op": "add_marker", "params": {"name": "Intro", "at": 1.5}}], "allowPaid": true}"#.utf8))
        #expect(ok.allowPaid)
        #expect(ok.steps[0].params["at"] == .number(1.5))
    }

    @Test("The guide documents every operation and the series rules")
    func guide() {
        let g = AgentAPI.guide(port: 9301, appVersion: "0.1.0")
        for op in Operations.all { #expect(g.contains("### `\(op.name)`"), "\(op.name) missing") }
        for needle in ["http://127.0.0.1:9301", "X-Jammer-Agent: 1", "allowPaid", "step_failed", "app.name", "/api/v1/uploads",
                       "/api/v1/operations", "Origin"] {
            #expect(g.contains(needle), "\(needle) missing")
        }
        // The quick start has 5 commands.
        #expect(g.components(separatedBy: "curl -s").count - 1 >= 5)
    }
}

@Suite("Step runner")
struct StepRunnerTests {
    private func state(seconds: Double = 10) -> EditState {
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: Int64(seconds * 48_000), chunks: [], bext: nil,
                                 ixml: nil, markers: [])
        return EditState(project: Project(source: SourceRef(name: "t", path: "/dev/null", info: info)))
    }

    private let fakeMeasure: StepRunner.Measure = { _, _ in
        LoudnessResult(integrated: -20, range: 5, maxMomentary: -15, maxShortTerm: -17, samplePeak: -3, truePeak: -2.5, duration: 1)
    }

    private func steps(_ list: [(String, [String: JSONValue])]) -> [Step] { list.map { Step(op: $0.0, params: $0.1) } }

    @Test("A typical podcast clean-up runs in order")
    func sequence() {
        var s = state()
        let r = StepRunner.run(steps([
            ("delete", ["start": .number(0), "end": .number(2.5)]),
            ("fade_in", ["start": .number(0), "end": .number(0.5)]),
            ("normalize", ["target": .string("loudness"), "level": .number(-16)]),
            ("add_marker", ["name": .string("Intro"), "at": .number(1)]),
        ]), on: &s, measure: fakeMeasure)
        #expect(r.map(\.status) == [.done, .done, .done, .done])
        #expect(s.project.length == 7 * 48_000 + 24_000)
        #expect(r[2].info["gainDB"] == 4)
        #expect(s.project.tracks[0].clips.allSatisfy { $0.gainDB == 4 })
        #expect(s.project.markers.map(\.name) == ["Intro"])
    }

    @Test("Tempo: set, change the meter, follow a delete, remove; bad values fail the step")
    func tempo() {
        var s = state()
        var r = StepRunner.run(steps([
            ("set_tempo", ["bpm": .number(90)]),
            ("set_tempo", ["bpm": .number(140), "at": .number(4), "beats": .number(6), "unit": .number(8)]),
            ("set_tempo", ["bpm": .number(70), "at": .number(6)]),
            ("delete", ["start": .number(1), "end": .number(2)]),
        ]), on: &s, measure: fakeMeasure)
        #expect(r.map(\.status) == [.done, .done, .done, .done])
        #expect(s.project.tempo.changes.map(\.position) == [0, 3 * 48_000, 5 * 48_000])
        #expect(s.project.tempo.changes.map(\.bpm) == [90, 140, 70])
        #expect(s.project.tempo.changes.map(\.meter) == [.common, Meter(6, 8), Meter(6, 8)])

        r = StepRunner.run(steps([("remove_tempo_change", ["at": .number(5)])]), on: &s, measure: fakeMeasure)
        #expect(r.map(\.status) == [.done])
        #expect(s.project.tempo.changes.count == 2)

        for bad: [String: JSONValue] in [["bpm": .number(5)], ["bpm": .number(120), "beats": .number(3)],
                                         ["bpm": .number(120), "beats": .number(3), "unit": .number(5)],
                                         ["bpm": .number(120), "beats": .number(2.5), "unit": .number(4)]] {
            var t = s
            #expect(StepRunner.run(steps([("set_tempo", bad)]), on: &t, measure: fakeMeasure).map(\.status) == [.failed])
            #expect(t.project.tempo == s.project.tempo)
        }
        r = StepRunner.run(steps([("remove_tempo_change", ["at": .number(0)])]), on: &s, measure: fakeMeasure)
        #expect(r.map(\.status) == [.failed])
        r = StepRunner.run(steps([("remove_tempo_change", ["at": .number(2)])]), on: &s, measure: fakeMeasure)
        #expect(r[0].error?.contains("Changes are at: 3 s.") == true)
    }

    @Test("The first failure stops the rest")
    func failure() {
        var s = state()
        let r = StepRunner.run(steps([
            ("select", ["start": .number(1), "end": .number(2)]),
            ("paste", [:]), // empty clipboard
            ("delete", [:]),
        ]), on: &s, measure: fakeMeasure)
        #expect(r.map(\.status) == [.reverted, .failed, .skipped])
        #expect(r[1].error?.contains("clipboard") == true)
    }

    @Test("Ranges: explicit beats selection; gain without either means everything")
    func ranges() {
        var s = state()
        _ = StepRunner.run(steps([("select", ["start": .number(1), "end": .number(2)]), ("gain", ["db": .number(-3)])]), on: &s, measure: fakeMeasure)
        let changed = s.project.tracks[0].clips.filter { $0.gainDB == -3 }
        #expect(changed.count == 1 && changed[0].start == 48_000 && changed[0].length == 48_000)
        var t = state()
        _ = StepRunner.run(steps([("gain", ["db": .number(2)])]), on: &t, measure: fakeMeasure)
        #expect(t.project.tracks[0].clips.allSatisfy { $0.gainDB == 2 })
        var u = state()
        let r = StepRunner.run(steps([("delete", [:])]), on: &u, measure: fakeMeasure)
        #expect(r[0].status == .failed)
        let past = StepRunner.run(steps([("delete", ["start": .number(20), "end": .number(21)])]), on: &u, measure: fakeMeasure)
        #expect(past[0].error?.contains("after the end") == true)
    }

    @Test("Cut and paste through the clipboard")
    func clipboard() {
        var s = state()
        let r = StepRunner.run(steps([
            ("cut", ["start": .number(0), "end": .number(1)]),
            ("paste", ["at": .number(9)]),
        ]), on: &s, measure: fakeMeasure)
        #expect(r.allSatisfy { $0.status == .done })
        #expect(s.project.length == 10 * 48_000)
        #expect(s.selection == Frame(9 * 48_000)..<Frame(10 * 48_000))
    }
}

@Suite("JSON output")
struct JSONOutputTests {
    @Test("Doubles print short, ints and bools stay as they are")
    func tidy() {
        let r = AgentAPI.Response.json(["a": 7.624292, "b": 365_966 as Int64, "c": true, "d": [0.1, 2.5], "e": -0.9])
        let text = String(decoding: r.body, as: UTF8.self)
        #expect(text.contains("7.624292"))
        #expect(!text.contains("7.62429199"))
        #expect(text.contains("365966"))
        #expect(text.contains("true"))
        #expect(text.contains("0.1,") || text.contains("0.1\n") || text.contains("0.1 "))
        #expect(text.contains("-0.9"))
    }
}

/// site/agents.md is the guide the app serves, generated, never hand-edited.
/// `scripts/export-agents-guide.sh` rewrites it; this test fails when it drifts.
@Suite("Site copy of the guide")
struct SiteGuideTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../..").standardized

    static var appVersion: String {
        let yml = (try? String(contentsOf: repo.appending(path: "project.yml"), encoding: .utf8)) ?? ""
        let line = yml.split(separator: "\n").first { $0.contains("MARKETING_VERSION:") } ?? ""
        return line.split(separator: "\"").dropFirst().first.map(String.init) ?? "?"
    }

    @Test("site/agents.md matches GET /jammer")
    func siteGuide() throws {
        let url = Self.repo.appending(path: "site/agents.md")
        let guide = AgentAPI.guide(port: AgentAPI.ports[0], appVersion: Self.appVersion)
        if ProcessInfo.processInfo.environment["JAMMER_WRITE_GUIDE"] == "1" {
            try guide.write(to: url, atomically: true, encoding: .utf8)
        }
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        #expect(onDisk == guide, "site/agents.md is stale: run scripts/export-agents-guide.sh")
    }
}

@Suite("Transcript steps and jobs")
struct TranscriptStepTests {
    private let measure: StepRunner.Measure = { _, _ in
        LoudnessResult(integrated: -20, range: 5, maxMomentary: -15, maxShortTerm: -17, samplePeak: -3, truePeak: -2.5, duration: 1)
    }

    /// "hej och välkommen hej igen", one word a second.
    private func state() -> (EditState, [Word]) {
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: 480_000, chunks: [], bext: nil, ixml: nil, markers: [])
        var p = Project(source: SourceRef(name: "t", path: "/dev/null", info: info))
        let words = ["Hej", "och", "välkommen.", "Hej", "igen"].enumerated().map {
            Word(text: $1, start: Frame($0) * 48_000, end: Frame($0) * 48_000 + 24_000)
        }
        p.setTranscript(SourceTranscript(sourceID: p.sources[0].id, language: "sv-SE", engine: "test", words: words))
        return (EditState(project: p), words)
    }

    private func run(_ s: inout EditState, _ op: String, _ params: [String: JSONValue]) -> StepResult {
        StepRunner.run([Step(op: op, params: params)], on: &s, measure: measure)[0]
    }

    @Test("delete_words by id removes exactly those words")
    func byID() {
        var (s, words) = state()
        let r = run(&s, "delete_words", ["words": .array([.string(words[1].id.uuidString), .string(words[2].id.uuidString)])])
        #expect(r.status == .done)
        #expect(s.project.transcriptText() == "Hej Hej igen")
        #expect(r.info["words"] == 2)
        let bad = run(&s, "delete_words", ["words": .array([.string(UUID().uuidString)])])
        #expect(bad.status == .failed && bad.reason == "not_found")
    }

    @Test("Text must be unambiguous unless occurrence or all is given")
    func byText() {
        var (s, words) = state()
        let r = run(&s, "delete_words", ["text": .string("hej")])
        #expect(r.status == .failed && r.reason == "ambiguous" && r.details["matches"] == 2)
        #expect(s.project.transcriptText() == "Hej och välkommen. Hej igen")
        #expect(run(&s, "delete_words", ["text": .string("hej"), "occurrence": .number(2)]).status == .done)
        #expect(s.project.transcriptText() == "Hej och välkommen. igen")
        #expect(s.project.placedWords().first?.word.id == words[0].id)
        var t = state().0
        #expect(run(&t, "delete_words", ["text": .string("HEJ"), "all": .bool(true)]).status == .done)
        #expect(t.project.transcriptText() == "och välkommen. igen")
        var u = state().0
        #expect(run(&u, "delete_words", ["text": .string("välkommen")]).status == .done)
        #expect(run(&u, "delete_words", ["text": .string("hej"), "occurrence": .number(3)]).reason == "not_found")
        #expect(run(&u, "delete_words", ["text": .string("finns inte")]).reason == "not_found")
        #expect(run(&u, "delete_words", [:]).status == .failed)
    }

    @Test("correct_word changes text only; list params are checked")
    func correct() throws {
        var (s, words) = state()
        let before = s.project.tracks
        #expect(run(&s, "correct_word", ["word": .string(words[2].id.uuidString), "text": .string("Välkomna")]).status == .done)
        #expect(s.project.transcriptText() == "Hej och Välkomna Hej igen")
        #expect(s.project.tracks == before)
        #expect(run(&s, "correct_word", ["word": .string("nope"), "text": .string("x")]).reason == "not_found")
        #expect(throws: StepFailure.self) { try StepRunner.validate(Step(op: "delete_words", params: ["words": .string("x")])) }
        // JSON arrays parse into list params.
        let body = #"{"steps":[{"op":"delete_words","params":{"words":["a","b"]}}]}"#
        let parsed = try AgentAPI.parseSteps(Data(body.utf8))
        #expect(parsed.steps[0].params["words"]?.strings == ["a", "b"])
    }

    @Test("Jobs have the series' shape")
    func jobShape() throws {
        var job = Job(id: "J1", kind: "transcribe", documentID: "D")
        #expect(job.json["status"] as? String == "queued")
        job.status = .failed
        job.progress = 0.4567
        job.error = ("unsupported_language", "No Swedish here.")
        job.result = ["words": .number(12)]
        let j = job.json
        #expect(Set(j.keys) == ["id", "kind", "status", "progress", "error", "result", "document"])
        #expect(j["progress"] as? Double == 0.457)
        #expect((j["error"] as? [String: String]) == ["code": "unsupported_language", "message": "No Swedish here."])
        #expect(job.isFinished)
        _ = try JSONSerialization.data(withJSONObject: ["job": j])
    }
}

@Suite("Restore requests")
struct RestoreRequestTests {
    func error(_ body: [String: Any]) -> AgentAPI.APIError? {
        do { _ = try RestoreRequest.parse(body); return nil } catch { return error }
    }

    @Test("Valid bodies parse with defaults")
    func valid() throws {
        let r = try RestoreRequest.parse(["kind": "dehum"])
        #expect(r.settings == Restoration.Settings(kind: .dehum) && r.start == nil && r.tracks == nil)
        let id = UUID()
        let s = try RestoreRequest.parse(["kind": "declick", "amount": 0.5, "sensitivity": 2, "start": 1, "end": 3.5, "tracks": [id.uuidString]])
        #expect(s.settings.amount == 0.5 && s.settings.sensitivity == 2 && s.end == 3.5 && s.tracks == [id])
    }

    @Test("Bad bodies are 400 before anything starts; denoise isn't available yet")
    func invalid() {
        for body: [String: Any] in [[:], ["kind": "louder"], ["kind": "dehum", "amount": 1.5], ["kind": "dehum", "amount": true],
                                    ["kind": "dehum", "humFrequency": 5], ["kind": "declip", "humFrequency": 50],
                                    ["kind": "declick", "sensitivity": 0], ["kind": "dehum", "start": 2],
                                    ["kind": "dehum", "start": 3, "end": 1], ["kind": "dehum", "tracks": ["x"]],
                                    ["kind": "dehum", "tracks": []], ["kind": "dehum", "volume": 3]] {
            #expect(error(body)?.status == 400, "\(body)")
        }
        #expect(error(["kind": "denoise"])?.status == 409)
    }

    @Test("Precondition errors carry a reason")
    func reason() throws {
        let e = AgentAPI.APIError.unprocessable("no_hum", "No hum.")
        let r = AgentAPI.Response.error(e)
        let json = try JSONSerialization.jsonObject(with: r.body) as! [String: [String: Any]]
        #expect(r.status == 422 && json["error"]?["reason"] as? String == "no_hum" && json["error"]?["code"] as? String == "unprocessable")
    }
}

@Suite("Siblings")
struct SiblingTests {
    @Test("/api/v1/operations has the series' shape with JSON Schema params")
    func operationsShape() throws {
        let ops = AgentAPI.operations
        #expect(!ops.isEmpty)
        for op in ops {
            let keys: Set<String> = ["name", "description", "params", "paid", "undoable", "startsJob"]
            #expect(Set(op.keys) == keys || Set(op.keys) == keys.union(["call"]), "\(op["name"] ?? "?")")
            let schema = try #require(op["params"] as? [String: Any])
            #expect(schema["type"] as? String == "object")
            #expect(schema["properties"] is [String: Any])
            #expect(schema["required"] is [String])
        }
        let echo = try #require(ops.first { $0["name"] as? String == "echo" })
        let props = (echo["params"] as! [String: Any])["properties"] as! [String: [String: Any]]
        #expect(props["delay"]?["type"] as? String == "number")
        #expect(props["delay"]?["minimum"] as? Double == 0.02 && props["delay"]?["maximum"] as? Double == 2)
        #expect(props["feedback"]?["maximum"] as? Double == 0.95)
        #expect(props["tracks"]?["type"] as? String == "array")
        #expect(props["tail"]?["type"] as? String == "boolean")
        #expect((echo["params"] as! [String: Any])["required"] as? [String] == ["delay"])
        let gain = try #require(ops.first { $0["name"] as? String == "gain" })
        #expect(gain["undoable"] as? Bool == true && gain["paid"] as? Bool == false && gain["startsJob"] as? Bool == false)
        _ = try JSONSerialization.data(withJSONObject: ["operations": ops])
    }

    @Test("Out-of-range numbers fail before anything runs; echo needs the app")
    func echoStep() {
        #expect(throws: StepFailure.self) { try StepRunner.validate(Step(op: "echo", params: ["delay": .number(3)])) }
        #expect(throws: StepFailure.self) { try StepRunner.validate(Step(op: "echo", params: ["delay": .number(0.3), "feedback": .number(1)])) }
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: 48_000, chunks: [], bext: nil, ixml: nil, markers: [])
        var s = EditState(project: Project(source: SourceRef(name: "t", path: "/dev/null", info: info)))
        let r = StepRunner.run([Step(op: "echo", params: ["delay": .number(0.3)])], on: &s) { _, _ in
            LoudnessResult(integrated: nil, range: nil, maxMomentary: nil, maxShortTerm: nil, samplePeak: 0, truePeak: 0, duration: 0)
        }
        #expect(r[0].status == .failed)
    }

    @Test("echo through steps, as a sibling would call it")
    func echoThroughSteps() throws {
        let signal = (0..<96_000).map { $0 % 9_600 == 0 ? Float(0.5) : 0 }
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: 48_000, chunks: [], bext: nil, ixml: nil, markers: [])
        let ref = SourceRef(name: "t", path: "/dev/null", info: info)
        let pool = SourcePool()
        pool.register(ref.id, memory: signal, channels: 2)
        let media = FileManager.default.temporaryDirectory.appending(path: "jammer-echo-step-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: media) }
        var s = EditState(project: Project(source: ref), pool: pool, media: media)
        let steps = [Step(op: "gain", params: ["db": .number(3)]),
                     Step(op: "echo", params: ["delay": .number(0.25), "feedback": .number(0.3), "mix": .number(0.4), "tail": .bool(true)])]
        let r = StepRunner.run(steps, on: &s) { _, _ in
            LoudnessResult(integrated: nil, range: nil, maxMomentary: nil, maxShortTerm: nil, samplePeak: 0, truePeak: 0, duration: 0)
        }
        #expect(r.map(\.status) == [.done, .done])
        #expect(s.project.length > 48_000)
        #expect(s.project.sources.contains { $0.name.hasSuffix("(echo)") })
    }
}


@Suite("Endpoints in the operation list")
struct EndpointListTests {
    @Test("Jobs and analysis are listed with call and startsJob; steps have no call")
    func endpoints() throws {
        let ops = AgentAPI.operations
        let restore = try #require(ops.first { $0["name"] as? String == "restore" })
        #expect(restore["startsJob"] as? Bool == true)
        #expect((restore["call"] as? [String: String]) == ["method": "POST", "path": "/api/v1/documents/{id}/restore"])
        let analysis = try #require(ops.first { $0["name"] as? String == "analyze_restoration" })
        #expect((analysis["call"] as? [String: String])?["method"] == "GET" && analysis["startsJob"] as? Bool == false)
        #expect(ops.first { $0["name"] as? String == "transcribe" }?["startsJob"] as? Bool == true)
        #expect(ops.first { $0["name"] as? String == "gain" }?["call"] == nil)
        // The restore schema and the body parser accept exactly the same fields.
        let schema = restore["params"] as! [String: Any]
        let properties = schema["properties"] as! [String: [String: Any]]
        #expect(Set(properties.filter { $0.value["x-in"] == nil }.keys) == RestoreRequest.keys)
        #expect(properties["id"]?["x-in"] as? String == "path" && (schema["required"] as! [String]).contains("id"))
        let aProps = (analysis["params"] as! [String: Any])["properties"] as! [String: [String: Any]]
        #expect(aProps["start"]?["x-in"] as? String == "query" && aProps["id"]?["x-in"] as? String == "path")
        #expect(((ops.first { $0["name"] as? String == "gain" }!["params"] as! [String: Any])["properties"] as! [String: [String: Any]]).values.allSatisfy { $0["x-in"] == nil })
        // Endpoints aren't steps.
        #expect(throws: StepFailure.self) { try StepRunner.validate(Step(op: "restore", params: [:])) }
    }
}
