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
