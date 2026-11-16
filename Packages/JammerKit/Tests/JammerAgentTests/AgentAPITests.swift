import Foundation
import JammerCore
import Testing
import TestNetGuard
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
        // The site describes the release build, whatever this test process has switched on.
        let guide = AgentAPI.guide(port: AgentAPI.ports[0], appVersion: Self.appVersion,
                                   features: .init(dereverb: Features.dereverb, spectralFreeform: Features.spectralFreeform, clap: Features.clap))
        if ProcessInfo.processInfo.environment["JAMMER_WRITE_GUIDE"] == "1" {
            try guide.write(to: url, atomically: true, encoding: .utf8)
        }
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        #expect(onDisk == guide, "site/agents.md is stale: run scripts/export-agents-guide.sh")
    }

    @Test("The manual says what the release build has")
    func manualFollowsFeatures() throws {
        let p = Process()
        p.executableURL = Self.repo.appending(path: "scripts/apply-features.py")
        p.arguments = ["--check"]
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0, "\(String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")")
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

    @Test("A transcript without word times: words can be corrected and found, not cut")
    func textOnly() throws {
        var (s, words) = state()
        // A file from before the marking reads as a transcript with word times.
        let old = try JSONDecoder().decode(SourceTranscript.self, from: Data(#"{"sourceID":"\#(UUID().uuidString)","language":"sv-SE","engine":"x","words":[],"speakers":[]}"#.utf8))
        #expect(old.textOnly == nil)
        s.project.transcripts[0].textOnly = true
        for i in s.project.transcripts[0].words.indices { s.project.transcripts[0].words[i].untimed = true }
        // Out through the API: no number that could be read as a time.
        let placed = s.project.placedWords()
        let json = AgentAPI.wordJSON(placed[1]) { Double($0) / 48_000 }
        #expect(json["start"] is NSNull && json["end"] is NSNull && json["untimed"] as? Bool == true && json["text"] as? String == placed[1].word.text)
        var timed = placed[1]; timed.word.untimed = nil
        #expect(AgentAPI.wordJSON(timed) { Double($0) / 48_000 }["start"] is Double && AgentAPI.wordJSON(timed) { _ in 0 }["untimed"] == nil)
        let before = s.project
        let cut = run(&s, "delete_words", ["words": .array([.string(words[1].id.uuidString)])])
        #expect(cut.status == .failed && cut.reason == "text_only" && (cut.error ?? "").contains("not the time of each word"), "\(cut.error ?? "")")
        let byText = run(&s, "delete_words", ["text": .string("välkommen")])
        #expect(byText.status == .failed && byText.reason == "text_only")
        #expect(s.project == before)
        #expect(throws: TranscriptError.textOnly) { try s.project.deleteWords([words[1].id]) }
        // The text itself can still be put right, and the marking survives saving.
        #expect(run(&s, "correct_word", ["word": .string(words[1].id.uuidString), "text": .string("samt")]).status == .done)
        let again = try JSONDecoder().decode(Project.self, from: try JSONEncoder().encode(s.project))
        #expect(again.transcripts[0].textOnly == true && again.transcriptText().contains("samt"))
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
        if Features.dereverb {
            // Reverb reduction starts at 0.7; an amount given is kept.
            #expect(try RestoreRequest.parse(["kind": "dereverb"]).settings == Restoration.Settings(kind: .dereverb, amount: 0.7))
            #expect(try RestoreRequest.parse(["kind": "dereverb", "amount": 1]).settings.amount == 1)
        } else {
            // Left out of the build: refused as unavailable, and not offered.
            #expect(error(["kind": "dereverb"]) == .notAvailable("dereverb isn't available in this build."))
            #expect(!Restoration.availableKinds.contains(.dereverb))
        }
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
            let keys: Set<String> = ["name", "description", "params", "paid", "undoable", "startsJob", "tier"]
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

    @Test("limit through steps: the answer says what it did, a second run is refused, wild values never reach the filter")
    func limitThroughSteps() throws {
        let n = 48_000 * 3
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: Int64(n), chunks: [], bext: nil, ixml: nil, markers: [])
        let a = SourceRef(name: "loud", path: "/dev/null", info: info)
        let pool = SourcePool()
        pool.register(a.id, memory: (0..<n).flatMap { i -> [Float] in let v = Float(0.98 * sin(Double(i) * 0.05)); return [v, v] }, channels: 2)
        let media = FileManager.default.temporaryDirectory.appending(path: "jammer-limit-steps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: media) }
        var s = EditState(project: Project(source: a), pool: pool, media: media)
        let quiet: StepRunner.Measure = { _, _ in LoudnessResult(integrated: nil, range: nil, maxMomentary: nil, maxShortTerm: nil, samplePeak: 0, truePeak: 0, duration: 0) }
        let r = StepRunner.run([Step(op: "limit", params: ["ceiling": .number(-3)])], on: &s, measure: quiet)[0]
        #expect(r.status == .done, "\(r.error ?? "")")
        #expect(r.info["ceiling"] == -3 && (r.info["truePeakAfter"] ?? 0) <= -3 && (r.info["truePeakBefore"] ?? -9) > -1 && r.info["latencySamples"] == 0)
        #expect((r.info["reductionMaxDB"] ?? 0) > 2.5 && (r.info["limitedSeconds"] ?? 0) > 2.9 && r.info["tracks"] == 1 && r.info["beforePlugins"] == 0)
        // Again with the same ceiling: nothing to do, said so, and the document is as it was.
        let before = s.project
        let again = StepRunner.run([Step(op: "limit", params: ["ceiling": .number(-3)])], on: &s, measure: quiet)[0]
        #expect(again.status == .failed && again.reason == "nothing_to_do" && (again.error ?? "").contains("Nothing was changed") && s.project == before)
        // Out of range is refused before anything runs (the schema's ranges), and a track that isn't there is not found.
        for bad: [String: JSONValue] in [["ceiling": .number(3)], ["ceiling": .number(-100)], ["release": .number(0)], ["lookahead": .number(500)], ["release": .number(.infinity)]] {
            #expect(throws: (any Error).self) { try StepRunner.validate(Step(op: "limit", params: bad)) }
        }
        let missing = StepRunner.run([Step(op: "limit", params: ["tracks": .array([.string(UUID().uuidString)])])], on: &s, measure: quiet)[0]
        #expect(missing.status == .failed && missing.reason == "not_found")
        #expect(Operations.named("limit")?.tier == "advanced")
    }

    @Test("The mixer through steps: a bus, a track routed and panned, refusals with their reasons, one undo value")
    func mixerThroughSteps() throws {
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: 48_000, chunks: [], bext: nil, ixml: nil, markers: [])
        let a = SourceRef(name: "voice", path: "/dev/null", info: info)
        var s = EditState(project: Project(source: a), pool: nil, media: nil)
        let quiet: StepRunner.Measure = { _, _ in LoudnessResult(integrated: nil, range: nil, maxMomentary: nil, maxShortTerm: nil, samplePeak: 0, truePeak: 0, duration: 0) }
        func run(_ op: String, _ params: [String: JSONValue]) -> StepResult { StepRunner.run([Step(op: op, params: params)], on: &s, measure: quiet)[0] }
        let track = s.project.tracks[0].id.uuidString
        #expect(run("add_bus", ["name": .string("Speech")]).info["bus"] == 1)
        let speech = s.project.buses[0].id.uuidString
        #expect(run("add_bus", ["name": .string("All"), "output": .string("master")]).status == .done)
        let all = s.project.buses[1].id.uuidString
        #expect(run("set_bus", ["bus": .string(speech), "gainDB": .number(-3), "pan": .number(0.25), "output": .string(all), "muted": .bool(true)]).status == .done)
        #expect(s.project.buses[0].gainDB == -3 && s.project.buses[0].pan == 0.25 && s.project.buses[0].output == s.project.buses[1].id && s.project.buses[0].isMuted)
        #expect(run("set_track", ["track": .string(track), "pan": .number(-0.5), "output": .string(speech)]).status == .done)
        #expect(s.project.tracks[0].pan == -0.5 && s.project.tracks[0].output == s.project.buses[0].id && s.project.usesMixer)
        // Refusals, each with its reason, and nothing changed by any of them.
        let before = s.project
        for (op, params, reason): (String, [String: JSONValue], String) in [
            ("set_bus", ["bus": .string(all), "output": .string(speech)], "routing_loop"),
            ("set_bus", ["bus": .string(UUID().uuidString), "gainDB": .number(0)], "not_found"),
            ("set_bus", ["bus": .string(speech), "output": .string("somewhere")], "not_found"),
            ("remove_bus", ["bus": .string(speech)], "in_use"),
            ("remove_bus", ["bus": .string(all)], "in_use"),
            ("set_track", ["track": .string(track), "output": .string(UUID().uuidString)], "not_found"),
            ("add_bus", ["name": .string("  ")], "bad_request"),
        ] {
            let r = run(op, params)
            #expect(r.status == .failed && r.reason == reason, "\(op) \(params): \(r.reason ?? "-") \(r.error ?? "")")
        }
        #expect(s.project == before)
        // Out of range never reaches the model (the schema's ranges).
        for bad: (String, [String: JSONValue]) in [("set_bus", ["bus": .string(speech), "gainDB": .number(99)]), ("set_bus", ["bus": .string(speech), "pan": .number(3)]),
                                                   ("set_track", ["track": .string(track), "pan": .number(-2)])] {
            #expect(throws: (any Error).self) { try StepRunner.validate(Step(op: bad.0, params: bad.1)) }
        }
        // Back to nothing: the track to the output, the buses away. The project is the plain one again.
        #expect(run("set_track", ["track": .string(track), "pan": .number(0), "output": .string("master")]).status == .done)
        #expect(run("remove_bus", ["bus": .string(speech), "reroute": .string("master")]).status == .done)
        #expect(run("remove_bus", ["bus": .string(all)]).status == .done)
        #expect(!s.project.usesMixer && s.project.buses.isEmpty)
        for op in ["add_bus", "set_bus", "remove_bus"] { #expect(Operations.named(op)?.tier == "advanced") }
    }

    @Test("duck through steps: lowers one track under the other, says how, refuses in words, and is a core operation")
    func duckThroughSteps() throws {
        let n = 48_000 * 6
        // Speech: a tone from 2 s to 4 s. Music: a tone all the way.
        let speech = (0..<n).flatMap { i -> [Float] in let v = i >= 96_000 && i < 192_000 ? Float(0.1 * sin(Double(i) * 0.04)) : 0; return [v, v] }
        let music = (0..<n).flatMap { i -> [Float] in let v = Float(0.25 * sin(Double(i) * 0.06)); return [v, v] }
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: Int64(n), chunks: [], bext: nil, ixml: nil, markers: [])
        let a = SourceRef(name: "speech", path: "/dev/null", info: info), b = SourceRef(name: "music", path: "/dev/null", info: info)
        let pool = SourcePool()
        pool.register(a.id, memory: speech, channels: 2)
        pool.register(b.id, memory: music, channels: 2)
        var project = Project(source: a)
        let musicTrack = project.addTrack(source: b, name: "Music")
        let speechTrack = project.tracks[0].id
        let media = FileManager.default.temporaryDirectory.appending(path: "jammer-duck-step-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: media) }
        let quiet: StepRunner.Measure = { _, _ in LoudnessResult(integrated: nil, range: nil, maxMomentary: nil, maxShortTerm: nil, samplePeak: 0, truePeak: 0, duration: 0) }
        func run(_ params: [String: JSONValue], on p: Project) -> (StepResult, Project) {
            var s = EditState(project: p, pool: pool, media: media)
            let r = StepRunner.run([Step(op: "duck", params: params)], on: &s, measure: quiet)
            return (r[0], s.project)
        }
        let (r, q) = run(["tracks": .array([.string(musicTrack.id.uuidString)]), "amount": .number(-10)], on: project)
        #expect(r.status == .done && r.info["tracks"] == 1 && r.info["regions"] == 1 && r.info["replaced"] == 0 && r.ids["trigger"] == "level")
        var solo = q
        solo.tracks = [q.tracks[1]]
        let out = PlanCompiler.compile(solo, pool: pool).render(from: 0, frames: n)
        #expect(abs(20 * log10(Double(out[144_000 * 2 + 20] / music[144_000 * 2 + 20])) + 10) < 0.01 && out[0..<(48_000 * 2)] == music[0..<(48_000 * 2)])
        // Again: in place of the first, not on top of it.
        let (r2, _) = run(["tracks": .array([.string(musicTrack.id.uuidString)])], on: q)
        #expect(r2.status == .done && r2.info["replaced"] == 1)
        // Refusals, each with its reason, and nothing changed.
        let (both, same) = run(["tracks": .array([.string(musicTrack.id.uuidString)]), "under": .array([.string(musicTrack.id.uuidString)])], on: project)
        #expect(both.status == .failed && both.reason == "bad_request" && same == project && (both.error ?? "").contains("under"))
        #expect(run(["tracks": .array([.string("nope")])], on: project).0.reason == "not_found")
        #expect(run(["tracks": .array([.string(musicTrack.id.uuidString)]), "threshold": .number(-10)], on: project).0.reason == "no_speech")
        #expect(run(["tracks": .array([.string(speechTrack.uuidString), .string(musicTrack.id.uuidString)])], on: project).0.reason == "needs_tracks")
        #expect(run(["tracks": .array([])], on: project).0.status == .failed && run([:], on: project).0.status == .failed)
        #expect(run(["tracks": .array([.string(musicTrack.id.uuidString)]), "amount": .number(3)], on: project).0.status == .failed)
        #expect(Operations.named("duck")?.tier == "core")
    }

    @Test("detect_tempo through steps: sets the tempo map from what the analyser found, refuses in words, takes a known tempo")
    func detectTempoThroughSteps() throws {
        // Clicks every 0.5 s from 0.2 s (120 BPM), 20 s.
        let n = 48_000 * 20
        var x = [Float](repeating: 0, count: n * 2)
        for k in 0..<40 { let s = 9_600 + k * 24_000; for i in 0..<480 where s + i < n { let v = Float(exp(-Double(i) / 100) * sin(Double(i) * 0.2)); x[(s + i) * 2] = v; x[(s + i) * 2 + 1] = v } }
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: Int64(n), chunks: [], bext: nil, ixml: nil, markers: [])
        let ref = SourceRef(name: "clicks", path: "/dev/null", info: info)
        let pool = SourcePool()
        pool.register(ref.id, memory: x, channels: 2)
        let project = Project(source: ref)
        let quiet: StepRunner.Measure = { _, _ in LoudnessResult(integrated: nil, range: nil, maxMomentary: nil, maxShortTerm: nil, samplePeak: 0, truePeak: 0, duration: 0) }
        func run(_ params: [String: JSONValue]) -> (StepResult, Project) {
            var s = EditState(project: project, pool: pool)
            let r = StepRunner.run([Step(op: "detect_tempo", params: params)], on: &s, measure: quiet)
            return (r[0], s.project)
        }
        // A tracker that answers as the system's does for this file: beats on the clicks, counted at half speed for the second case.
        func tracker(_ bpm: Double) -> @Sendable (URL) -> Rhythm.Reading? {
            { url in
                let seconds = (try? AudioFileReader.info(at: url)).map { Double($0.frames) / $0.sampleRate } ?? 0
                // The halves start elsewhere in the click pattern; only the spacing matters for them.
                return Rhythm.Reading(bpm: bpm, beats: stride(from: 0.2, to: seconds, by: 60 / bpm).map { $0 })
            }
        }
        Rhythm.analyser = tracker(120)
        let (r, q) = run([:])
        #expect(r.status == .done && r.info["bpm"] == 120 && r.info["firstBeat"] == 0.2 && (r.info["pulse"] ?? 0) > 0.5)
        #expect(q.tempo.changes.count == 2 && q.tempo.changes[1] == TempoChange(position: 9_600, bpm: 120) && q != project)
        // The ruler's beats are on the clicks: tick 0 at the click 3 s in.
        #expect(q.musicalPosition(at: 9_600 + 6 * 24_000).tick == 0)
        // Counted at half speed: 60 comes back; multiply 2, or the known tempo, puts it right.
        Rhythm.analyser = tracker(60)
        #expect(run([:]).0.info["bpm"] == 60 && run(["multiply": .number(2)]).0.info["bpm"] == 120 && run(["bpm": .number(120)]).0.info["bpm"] == 120)
        let (known, _) = run(["bpm": .number(119.5)])
        #expect(known.status == .done && known.info["bpm"] == 119.5)
        // A tempo that doesn't fit the sound, bad parameters, and sound without a beat: refused, nothing changed.
        let (wrong, same) = run(["bpm": .number(100)])
        #expect(wrong.status == .failed && wrong.reason == "tempo_mismatch" && same == project)
        #expect(run(["multiply": .number(1.5)]).0.status == .failed && run(["multiply": .number(2), "bpm": .number(120)]).0.status == .failed)
        #expect(run(["tracks": .array([.string("nope")])]).0.reason == "not_found")
        Rhythm.analyser = tracker(97)
        #expect(run([:]).0.reason == "no_steady_tempo")
        Rhythm.analyser = nil
        #expect(run([:]).0.reason == "not_available")
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

@Suite("Loudness preset step")
struct LoudnessPresetStepTests {
    @Test("Reports when the peaks held the gain back")
    func limited() {
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: 480_000, chunks: [], bext: nil, ixml: nil, markers: [])
        var s = EditState(project: Project(source: SourceRef(name: "t", path: "/dev/null", info: info)))
        let r = StepRunner.run([Step(op: "loudness_preset", params: ["preset": .string("apple_podcasts")])], on: &s) { _, _ in
            LoudnessResult(integrated: -20, range: 5, maxMomentary: nil, maxShortTerm: nil, samplePeak: -3, truePeak: -2.5, duration: 10)
        }
        #expect(r[0].status == .done)
        #expect(r[0].info["gainDB"] == 1.5 && r[0].info["limitedByPeak"] == 1 && r[0].info["integratedAfter"] == -18.5)
        #expect(s.project.tracks[0].clips[0].gainDB == 1.5)
        #expect(throws: StepFailure.self) { try StepRunner.validate(Step(op: "loudness_preset", params: ["preset": .string("acx")])) }
    }
}

@Suite("Drift and spectral steps")
struct DriftSpectralStepTests {
    @Test("correct_drift refuses an uncertain measurement; spectral_attenuate checks its band")
    func steps() {
        let n = 48_000 * 100
        var x: UInt64 = 1
        let a = (0..<n).flatMap { _ -> [Float] in x = x &* 6_364_136_223_846_793_005 &+ 1; let v = Float(Int32(truncatingIfNeeded: x >> 32)) / 4_294_967_296; return [v, v] }
        var y: UInt64 = 2
        let b = (0..<n).flatMap { _ -> [Float] in y = y &* 6_364_136_223_846_793_005 &+ 1; let v = Float(Int32(truncatingIfNeeded: y >> 32)) / 4_294_967_296; return [v, v] }
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: Int64(n), chunks: [], bext: nil, ixml: nil, markers: [])
        let ra = SourceRef(name: "A", path: "/dev/null", info: info), rb = SourceRef(name: "B", path: "/dev/null", info: info)
        let pool = SourcePool()
        pool.register(ra.id, memory: a, channels: 2)
        pool.register(rb.id, memory: b, channels: 2)
        var p = Project(source: ra)
        p.addTrack(source: rb)
        var s = EditState(project: p, pool: pool, media: FileManager.default.temporaryDirectory.appending(path: "jammer-st-\(UUID().uuidString)"))
        let measure: StepRunner.Measure = { _, _ in LoudnessResult(integrated: nil, range: nil, maxMomentary: nil, maxShortTerm: nil, samplePeak: 0, truePeak: 0, duration: 0) }
        let r = StepRunner.run([Step(op: "correct_drift", params: ["track": .string(p.tracks[1].id.uuidString)])], on: &s, measure: measure)
        #expect(r[0].status == .failed && r[0].reason == "drift_uncertain", "\(r[0].error ?? "")")
        #expect(throws: StepFailure.self) { try StepRunner.validate(Step(op: "spectral_attenuate", params: ["low": .number(1_000), "high": .number(2_000), "db": .number(5)])) }
    }
}

@Suite("Insert steps", .serialized)
struct InsertStepTests {
    @Test("add, change, bypass and remove a plugin; refusals carry reasons")
    func steps() throws {
        var p = Project(sampleRate: 48_000, channels: 2)
        p.tracks = [Track(name: "A")]
        let track = p.tracks[0].id.uuidString
        var s = EditState(project: p)
        let measure: StepRunner.Measure = { _, _ in LoudnessResult(integrated: nil, range: nil, maxMomentary: nil, maxShortTerm: nil, samplePeak: 0, truePeak: 0, duration: 0) }
        var r = StepRunner.run([Step(op: "add_insert", params: ["track": .string(track), "plugin": .string("AULowpass")])], on: &s, measure: measure)
        #expect(r[0].status == .done, "\(r[0].error ?? "")")
        let id = try #require(r[0].ids["insert"])
        #expect(s.project.tracks[0].inserts.map(\.name) == ["AULowpass"])
        r = StepRunner.run([Step(op: "set_insert", params: ["track": .string(track), "insert": .string(id), "parameter": .string("global.0"), "value": .number(900)])], on: &s, measure: measure)
        #expect(r[0].status == .done, "\(r[0].error ?? "")")
        let unit = try PluginInstance.makeBlocking(s.project.tracks[0].inserts[0].plugin, channels: 2, sampleRate: 48_000, state: s.project.tracks[0].inserts[0].state)
        #expect(abs((unit.parameters.first { $0.identifier == "global.0" }?.value ?? 0) - 900) < 0.01)
        r = StepRunner.run([Step(op: "set_insert", params: ["track": .string(track), "insert": .string("AULowpass"), "parameter": .string("global.0"), "value": .number(1e9)])], on: &s, measure: measure)
        #expect(r[0].status == .failed && r[0].reason == "out_of_range", "\(r[0].error ?? "")")
        r = StepRunner.run([Step(op: "set_insert", params: ["track": .string(track), "insert": .string(id), "bypass": .bool(true)])], on: &s, measure: measure)
        #expect(s.project.tracks[0].inserts[0].bypass)
        r = StepRunner.run([Step(op: "add_insert", params: ["track": .string(track), "plugin": .string("No Such Plugin")])], on: &s, measure: measure)
        #expect(r[0].reason == "plugin_not_found")
        r = StepRunner.run([Step(op: "remove_insert", params: ["track": .string(track), "insert": .string(id)])], on: &s, measure: measure)
        #expect(r[0].status == .done && s.project.tracks[0].inserts.isEmpty)
        r = StepRunner.run([Step(op: "remove_insert", params: ["track": .string(track), "insert": .string(id)])], on: &s, measure: measure)
        #expect(r[0].reason == "not_found")
    }

    @Test("set_master: the gain, the limiter on with values and off, refusals in words; a plugin goes on the master by name")
    func master() throws {
        var p = Project(sampleRate: 48_000, channels: 2)
        p.tracks = [Track(name: "A")]
        var s = EditState(project: p)
        let measure: StepRunner.Measure = { _, _ in LoudnessResult(integrated: nil, range: nil, maxMomentary: nil, maxShortTerm: nil, samplePeak: 0, truePeak: 0, duration: 0) }
        func run(_ op: String, _ params: [String: JSONValue]) -> StepResult { StepRunner.run([Step(op: op, params: params)], on: &s, measure: measure)[0] }
        #expect(run("set_master", ["gainDB": .number(-3)]).status == .done && s.project.master.gainDB == -3 && s.project.master.limiter == nil)
        var r = run("set_master", ["limiter": .bool(true)])
        #expect(r.status == .done && r.info["limiter"] == 1 && r.info["ceilingDB"] == -1 && s.project.master.limiter == MasterLimiter())
        // A value alone changes the limiter that is on, and keeps the rest.
        #expect(run("set_master", ["ceiling": .number(-2), "release": .number(250)]).status == .done)
        #expect(s.project.master.limiter == MasterLimiter(ceilingDB: -2, releaseMs: 250, lookaheadMs: 5) && s.project.master.gainDB == -3)
        // Refused, and nothing changed: nothing given, a value with "off", a ceiling over full scale.
        let before = s.project
        #expect(run("set_master", [:]).status == .failed)
        #expect(run("set_master", ["limiter": .bool(false), "ceiling": .number(-3)]).status == .failed)
        #expect(run("set_master", ["ceiling": .number(2)]).status == .failed)
        #expect(run("set_master", ["gainDB": .number(60)]).status == .failed)
        #expect(s.project == before)
        #expect(run("set_master", ["limiter": .bool(false)]).status == .done && s.project.master.limiter == nil)
        // A value without a limiter puts one on.
        #expect(run("set_master", ["ceiling": .number(-0.5)]).status == .done && s.project.master.limiter?.ceilingDB == -0.5)
        // Plugins on the master.
        r = run("add_insert", ["track": .string("master"), "plugin": .string("AULowpass")])
        #expect(r.status == .done && s.project.master.inserts.map(\.name) == ["AULowpass"] && s.project.tracks[0].inserts.isEmpty, "\(r.error ?? "")")
        let id = try #require(r.ids["insert"])
        #expect(run("set_insert", ["track": .string("Master"), "insert": .string(id), "bypass": .bool(true)]).status == .done && s.project.master.inserts[0].bypass)
        #expect(run("remove_insert", ["track": .string("master"), "insert": .string(id)]).status == .done && s.project.master.inserts.isEmpty)
        // It is not offered to the assistant until the evaluation has been run with it.
        #expect(Operations.all.contains { $0.name == "set_master" })
    }

    @Test("VCA steps: a group with members, its level and mute, members replaced, added and taken out, removal that keeps the sound, refusals")
    func vca() throws {
        var p = Project(sampleRate: 48_000, channels: 2)
        p.tracks = [Track(name: "A"), Track(name: "B"), Track(name: "C")]
        let bus = try p.addBus(name: "Room")
        var s = EditState(project: p)
        let measure: StepRunner.Measure = { _, _ in LoudnessResult(integrated: nil, range: nil, maxMomentary: nil, maxShortTerm: nil, samplePeak: 0, truePeak: 0, duration: 0) }
        func run(_ op: String, _ params: [String: JSONValue]) -> StepResult { StepRunner.run([Step(op: op, params: params)], on: &s, measure: measure)[0] }
        let ids = s.project.tracks.map(\.id.uuidString)
        var r = run("add_vca", ["name": .string("Voices"), "members": .array([.string(ids[0]), .string(ids[1])])])
        let v = try #require(r.ids["vca"])
        #expect(r.status == .done && r.info["members"] == 2 && s.project.tracks[0].vca?.uuidString == v && s.project.tracks[2].vca == nil)
        r = run("set_vca", ["vca": .string(v), "gainDB": .number(-6), "muted": .bool(true), "name": .string("Speech")])
        #expect(r.status == .done && s.project.vcas[0] == VCA(id: UUID(uuidString: v)!, name: "Speech", gainDB: -6, isMuted: true))
        #expect(run("set_vca", ["vca": .string(v), "add": .array([.string(bus.id.uuidString)]), "remove": .array([.string(ids[0])])]).info["members"] == 2)
        #expect(s.project.tracks[0].vca == nil && s.project.buses[0].vca?.uuidString == v)
        #expect(run("set_vca", ["vca": .string(v), "members": .array([.string(ids[2])])]).info["members"] == 1)
        #expect(s.project.tracks[2].vca?.uuidString == v && s.project.tracks[1].vca == nil && s.project.buses[0].vca == nil)
        let before = s.project
        for (op, params, reason): (String, [String: JSONValue], String?) in [
            ("set_vca", ["vca": .string(UUID().uuidString), "gainDB": .number(0)], "not_found"),
            ("set_vca", ["vca": .string(v), "add": .array([.string(UUID().uuidString)])], "not_found"),
            ("set_vca", ["vca": .string(v)], nil),
            ("add_vca", ["name": .string("  ")], "bad_request"),
            ("remove_vca", ["vca": .string("nope")], "not_found"),
        ] {
            let r = run(op, params)
            #expect(r.status == .failed && (reason == nil || r.reason == reason), "\(op): \(r.reason ?? "-") \(r.error ?? "")")
        }
        #expect(s.project == before)
        #expect(run("remove_vca", ["vca": .string(v)]).status == .done)
        #expect(s.project.vcas.isEmpty && s.project.tracks[2].gainDB == -6 && s.project.tracks[2].isMuted && s.project.tracks[2].vca == nil)
    }

    @Test("set_insert key: off unless the build has it; a plugin without the input says so; a keyed plugin takes a key, loses it with none, and a loop is refused")
    func key() throws {
        #expect(KeyedGateAU.registered)
        var p = Project(sampleRate: 48_000, channels: 2)
        p.tracks = [Track(name: "A", inserts: [Insert(plugin: PluginID("aufx/lpas/appl")!, name: "AULowpass"), Insert(plugin: KeyedGateAU.plugin, name: "Gate")]), Track(name: "K")]
        let bus = try p.addBus(name: "Bus")
        try p.setTrackRoute(p.tracks[0].id, output: .some(bus.id))
        var s = EditState(project: p)
        let measure: StepRunner.Measure = { _, _ in LoudnessResult(integrated: nil, range: nil, maxMomentary: nil, maxShortTerm: nil, samplePeak: 0, truePeak: 0, duration: 0) }
        func run(_ params: [String: JSONValue]) -> StepResult { StepRunner.run([Step(op: "set_insert", params: params)], on: &s, measure: measure)[0] }
        let a = p.tracks[0].id.uuidString, k = p.tracks[1].id.uuidString
        let plain = p.tracks[0].inserts[0].id.uuidString, gate = p.tracks[0].inserts[1].id.uuidString
        // A build without sidechain keys: the parameter isn't in the schema and is refused.
        #expect(!Operations.all.first { $0.name == "set_insert" }!.params.contains { $0.name == "key" })
        let off = run(["track": .string(a), "insert": .string(gate), "key": .string(k)])
        #expect(off.status == .failed && (off.error ?? "").contains("has no parameter \"key\"") && s.project == p, "\(off.error ?? "")")
        Operations.$sidechainForThisTask.withValue(true) {
            #expect(Operations.all.first { $0.name == "set_insert" }!.params.contains { $0.name == "key" })
            var r = run(["track": .string(a), "insert": .string(plain), "key": .string(k)])
            #expect(r.status == .failed && r.reason == "no_key_input" && (r.error ?? "").contains("no sidechain input"), "\(r.error ?? "")")
            r = run(["track": .string(a), "insert": .string(gate), "key": .string(bus.id.uuidString)])
            #expect(r.status == .failed && r.reason == "routing_loop", "\(r.reason ?? "-") \(r.error ?? "")")
            r = run(["track": .string(a), "insert": .string(gate), "key": .string(UUID().uuidString)])
            #expect(r.status == .failed && r.reason == "not_found")
            r = run(["track": .string("master"), "insert": .string(gate), "key": .string(k)])
            #expect(r.status == .failed)
            #expect(s.project == p)
            r = run(["track": .string(a), "insert": .string(gate), "key": .string(k)])
            #expect(r.status == .done && s.project.tracks[0].inserts[1].key?.uuidString == k, "\(r.error ?? "")")
            #expect(run(["track": .string(a), "insert": .string(gate), "key": .string("none")]).status == .done && s.project.tracks[0].inserts[1].key == nil)
        }
    }

    @Test("The same steps put a plugin on a bus, by the bus's id; the track's plugins are not touched")
    func onBus() throws {
        var p = Project(sampleRate: 48_000, channels: 2)
        p.tracks = [Track(name: "A")]
        let bus = try p.addBus(name: "Speech")
        var s = EditState(project: p)
        let measure: StepRunner.Measure = { _, _ in LoudnessResult(integrated: nil, range: nil, maxMomentary: nil, maxShortTerm: nil, samplePeak: 0, truePeak: 0, duration: 0) }
        func run(_ op: String, _ params: [String: JSONValue]) -> StepResult { StepRunner.run([Step(op: op, params: params)], on: &s, measure: measure)[0] }
        var r = run("add_insert", ["track": .string(bus.id.uuidString), "plugin": .string("AUPeakLimiter")])
        #expect(r.status == .done && (r.info["latencyMs"] ?? 0) > 0, "\(r.error ?? "")")
        let id = try #require(r.ids["insert"])
        #expect(s.project.buses[0].inserts.map(\.name) == ["AUPeakLimiter"] && s.project.tracks[0].inserts.isEmpty && s.project.hasActiveInserts)
        r = run("add_insert", ["track": .string(bus.id.uuidString), "plugin": .string("AULowpass"), "position": .number(0)])
        #expect(s.project.buses[0].inserts.map(\.name) == ["AULowpass", "AUPeakLimiter"])
        #expect(run("set_insert", ["track": .string(bus.id.uuidString), "insert": .string(id), "bypass": .bool(true)]).status == .done && s.project.buses[0].inserts[1].bypass)
        #expect(run("set_insert", ["track": .string(bus.id.uuidString), "insert": .string("AULowpass"), "parameter": .string("global.0"), "value": .number(900)]).status == .done)
        #expect(s.project.buses[0].inserts[0].state != nil)
        // The plugin is on the bus, not on the track, and an id that is neither is refused.
        #expect(run("remove_insert", ["track": .string(s.project.tracks[0].id.uuidString), "insert": .string(id)]).reason == "not_found")
        #expect(run("add_insert", ["track": .string(UUID().uuidString), "plugin": .string("AULowpass")]).reason == "not_found")
        #expect(run("remove_insert", ["track": .string(bus.id.uuidString), "insert": .string(id)]).status == .done)
        #expect(s.project.buses[0].inserts.map(\.name) == ["AULowpass"])
    }
}

@Suite("Tests reach only this Mac")
struct NetGuardTests {
    @Test("A request to a public address is refused: shared session, default and ephemeral configurations")
    func refused() async throws {
        let url = URL(string: "https://\(JMNetGuardSelfTestHost)/x")!
        let before = JMNetGuardRefused().count
        for session in [URLSession.shared, URLSession(configuration: .default), URLSession(configuration: .ephemeral)] {
            do {
                _ = try await session.data(from: url)
                Issue.record("the request went out")
            } catch {
                #expect(error.localizedDescription.contains("test network guard refused"), "\(error.localizedDescription)")
            }
        }
        #expect(JMNetGuardRefused().count == before + 3)
        // This Mac is let through to fail on its own (nothing listens on port 9).
        do { _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:9/")!) } catch {
            #expect(!error.localizedDescription.contains("network guard"))
        }
    }

    /// A test's stand-in server takes the guard's place in its session, so it has to answer everything:
    /// one that passes on a request it doesn't know would let that request out.
    @Test("Every stand-in server in the tests answers every request")
    func standInsAnswerAll() throws {
        let tests = SourceRuleTests.app.deletingLastPathComponent().appending(path: "Packages/JammerKit/Tests")
        var seen = 0
        for case let f as URL in FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil)! where f.pathExtension == "swift" {
            let s = try String(contentsOf: f, encoding: .utf8)
            for line in s.split(separator: "\n") where line.contains("override class func " + "canInit(with") {
                seen += 1
                #expect(line.contains("{ true }"), "\(f.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(seen >= 3)
    }
}

@Suite("Rules the app's source has to keep")
struct SourceRuleTests {
    static let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appending(path: "App")

    /// Selectable text (`.textSelection(.enabled)`) with an accessibility label, value or hint of its own on
    /// the same view crashes the app with endless recursion in SwiftUI as soon as VoiceOver, or any
    /// assistive technology, reads it. The name goes on a group around the text.
    static func offences(in source: String) -> [Int] {
        var out: [Int] = [], chain: [(Int, String)] = []
        func close() {
            if chain.contains(where: { $0.1.hasPrefix(".textSelection(.enabled)") }),
               let bad = chain.first(where: { $0.1.hasPrefix(".accessibilityLabel") || $0.1.hasPrefix(".accessibilityValue") || $0.1.hasPrefix(".accessibilityHint") }) { out.append(bad.0) }
            chain = []
        }
        for (i, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(".") { chain.append((i + 1, t)) } else { close() }
        }
        close()
        return out
    }

    @Test("Selectable text never has an accessibility label of its own")
    func selectableTextHasNoLabel() throws {
        // The rule finds the pattern, and passes the repair.
        #expect(Self.offences(in: "Text(x)\n    .font(.body)\n    .textSelection(.enabled)\n    .padding(4)\n    .accessibilityLabel(\"Text\")\nButton {}") == [5])
        #expect(Self.offences(in: "Group {\n    Text(x)\n        .textSelection(.enabled)\n}\n.accessibilityElement(children: .contain)\n.accessibilityLabel(\"Text\")").isEmpty)
        let files = try FileManager.default.contentsOfDirectory(at: Self.app, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(files.count > 20)
        for f in files {
            let bad = Self.offences(in: try String(contentsOf: f, encoding: .utf8))
            #expect(bad.isEmpty, "\(f.lastPathComponent): selectable text with its own accessibility label at line \(bad)")
        }
    }
}

@Suite("Operation tiers")
struct TierTests {
    @Test("10–15 core operations, all of them real; every operation has a tier")
    func tiers() {
        let all = Operations.all + Operations.endpoints
        #expect((10...15).contains(OperationSpec.core.count))
        #expect(OperationSpec.core.isSubset(of: Set(all.map(\.name))))
        // What a sibling's assistant gets when its tools don't all fit: "turn it up and add an echo" has to work.
        let listed = Dictionary(AgentAPI.operations.compactMap { op in (op["name"] as? String).map { ($0, op["tier"] as? String ?? "") } }, uniquingKeysWith: { a, _ in a })
        #expect(listed["gain"] == "core" && listed["echo"] == "core" && listed["duck"] == "core" && listed["measure_loudness"] == "advanced")
        #expect(AgentAPI.operations.allSatisfy { ["core", "advanced"].contains($0["tier"] as? String ?? "") })
    }
}

@Suite("Spectral edit step")
struct SpectralEditStepTests {
    @Test("Without freeform areas only the box is offered, in the schema and in the guide")
    func boxOnly() throws {
        let full = try #require(Operations.all(freeform: true).first { $0.name == "spectral_edit" })
        let box = try #require(Operations.all(freeform: false).first { $0.name == "spectral_edit" })
        #expect(full.params.first { $0.name == "shape" }?.options == ["box", "polygon", "brush"])
        #expect(box.params.first { $0.name == "shape" }?.options == ["box"])
        #expect(!box.params.contains { ["points", "radius", "radiusTime"].contains($0.name) } && !box.description.contains("polygon"))
        #expect(Operations.all(freeform: false).count == Operations.all(freeform: true).count)
        let off = AgentAPI.guide(port: 9003, appVersion: "1", features: .init(dereverb: false, spectralFreeform: false, clap: false))
        let on = AgentAPI.guide(port: 9003, appVersion: "1", features: .init(dereverb: true, spectralFreeform: true, clap: true))
        #expect(!off.contains("polygon") && !off.contains("brush") && !off.contains("dereverb"))
        #expect(on.contains("polygon") && on.contains("brush") && on.contains("dereverb"))
        // CLAP: the scan call, the id form and the helper-process promise only where the build has it.
        #expect(on.contains("/api/v1/plugins/scan") && on.contains("clap:com.vendor.plugin") && on.contains("plugin_blocked"))
        #expect(!off.contains("CLAP") && !off.contains("clap") && !off.contains("plugins/scan") && off.contains("Audio Unit effects (AUv2 and AUv3)"))
        #expect(Operations.all(freeform: true, clap: false).first { $0.name == "add_insert" }?.description.contains("CLAP") == false)
        #expect(Operations.all(freeform: true, clap: true).first { $0.name == "add_insert" }?.description.contains("CLAP") == true)
    }

    @Test("polygon via JSON numbers; too_long and bad_shape reasons; numbers are validated")
    func step() throws {
        let n = 48_000 * 2
        let x = (0..<n).flatMap { i -> [Float] in let v = Float(0.1 * sin(2 * .pi * 440 * Double(i) / 48_000)); return [v, v] }
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: Int64(n), chunks: [], bext: nil, ixml: nil, markers: [])
        let ref = SourceRef(name: "t", path: "/dev/null", info: info)
        let pool = SourcePool()
        pool.register(ref.id, memory: x, channels: 2)
        var s = EditState(project: Project(source: ref), pool: pool, media: FileManager.default.temporaryDirectory.appending(path: "jammer-se-\(UUID().uuidString)"))
        let measure: StepRunner.Measure = { _, _ in LoudnessResult(integrated: nil, range: nil, maxMomentary: nil, maxShortTerm: nil, samplePeak: 0, truePeak: 0, duration: 0) }
        var r = StepRunner.run([Step(op: "spectral_edit", params: ["action": .string("attenuate"), "shape": .string("polygon"),
                                                                    "points": .array([0.5, 3_000, 1.0, 3_000, 1.0, 6_000, 0.5, 6_000].map { .number($0) })])], on: &s, measure: measure)
        #expect(r[0].status == .done, "\(r[0].error ?? "")")
        #expect(s.project.sources.count == 2)
        r = StepRunner.run([Step(op: "spectral_edit", params: ["action": .string("heal"), "shape": .string("box"), "start": .number(0.2), "end": .number(1.0),
                                                                "low": .number(1_000), "high": .number(2_000)])], on: &s, measure: measure)
        #expect(r[0].reason == "too_long")
        r = StepRunner.run([Step(op: "spectral_edit", params: ["action": .string("attenuate"), "shape": .string("polygon"), "points": .array([.number(1), .number(2)])])], on: &s, measure: measure)
        #expect(r[0].reason == "bad_shape")
        #expect(throws: StepFailure.self) { try StepRunner.validate(Step(op: "spectral_edit", params: ["action": .string("heal"), "shape": .string("brush"), "points": .array([.string("x")])])) }
    }
}


@Suite("Status")
struct StatusTests {
    @Test("app carries the bundle id, so debug and release builds never pair up")
    func bundleID() {
        let debug = AgentAPI.appInfo(version: "0.1.0", bundleID: "com.brattoo.jammer.debug")
        #expect(debug["bundleID"] as? String == "com.brattoo.jammer.debug" && debug["name"] as? String == "Jammer")
        #expect(AgentAPI.appInfo(version: "0.1.0", bundleID: nil)["bundleID"] as? String == "com.brattoo.jammer")
    }
}

@Suite("Track and group steps")
struct TrackGroupStepTests {
    @Test("set_track changes one track; set_group moves a group's gains together")
    func steps() {
        var p = Project(sampleRate: 44_100, channels: 2)
        let g = UUID()
        p.tracks = [Track(name: "V", gainDB: -3), Track(name: "D", gainDB: 0), Track(name: "Other")]
        p.tracks[0].group = g; p.tracks[1].group = g
        var s = EditState(project: p)
        let measure: StepRunner.Measure = { _, _ in LoudnessResult(integrated: nil, range: nil, maxMomentary: nil, maxShortTerm: nil, samplePeak: 0, truePeak: 0, duration: 0) }
        var r = StepRunner.run([Step(op: "set_group", params: ["group": .string(g.uuidString), "gainDB": .number(-6)]),
                                Step(op: "set_track", params: ["track": .string(p.tracks[1].id.uuidString), "muted": .bool(true), "name": .string("Drums")])], on: &s, measure: measure)
        #expect(r.allSatisfy { $0.status == .done })
        #expect(s.project.tracks.map(\.gainDB) == [-9, -6, 0] && s.project.tracks[1].isMuted && s.project.tracks[1].name == "Drums")
        r = StepRunner.run([Step(op: "set_group", params: ["group": .string(UUID().uuidString), "gainDB": .number(1)])], on: &s, measure: measure)
        #expect(r[0].reason == "not_found")
    }
}

/// What Config/Features.xcconfig says a release has, mirrored into this test process so the
/// guide written to site/ and the request tests describe the build that ships.
enum Features {
    static func setting(_ name: String) -> Bool {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = (try? String(contentsOf: root.appending(path: "Config/Features.xcconfig"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").contains { $0.replacingOccurrences(of: " ", with: "") == "\(name)=YES" }
    }
    /// Read only: the package always has the freeform shapes; the guide is asked for the release's.
    static let spectralFreeform = setting("JAMMER_SPECTRAL_FREEFORM")
    static let clap = setting("JAMMER_CLAP")
    static let dereverb: Bool = {
        let on = setting("JAMMER_DEREVERB")
        // A stand-in: these tests check parsing and text, not the sound (JammerDereverbTests does that).
        if on { Restoration.dereverber = { x, _, _ in x } }
        return on
    }()
}
