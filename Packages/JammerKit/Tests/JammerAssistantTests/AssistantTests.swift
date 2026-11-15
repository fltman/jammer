import Foundation
import JammerAgent
import JammerCore
import Testing
@testable import JammerAssistant

/// Mocks a model service (no keys, no network).
final class MockModelService: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var reply: Data = Data()
    nonisolated(unsafe) static var lastBody: [String: Any] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data(); var buf = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            Self.lastBody = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.reply)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Assistant")
struct AssistantTests {
    let actions = AssistantCatalog.actions

    func project() -> (Project, SourcePool) {
        var stereo = [Float](repeating: 0, count: 48_000 * 6 * 2)
        for i in 0..<(48_000 * 6) {
            let t = Double(i) / 48_000
            if t < 1.5 || t >= 3.2 {
                let v = Float(0.3 * sin(2 * .pi * 220 * t))
                stereo[i * 2] = v
                stereo[i * 2 + 1] = v
            }
        }
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: 48_000 * 6, chunks: [], bext: nil, ixml: nil, markers: [])
        let ref = SourceRef(name: "t", path: "/dev/null", info: info)
        let pool = SourcePool()
        pool.register(ref.id, memory: stereo, channels: 2)
        var p = Project(source: ref)
        let spoken: [(String, Double)] = [("Ehm", 0.1), ("hej", 0.5), ("och", 1.0), ("välkommen", 3.3), ("öh", 4.0), ("igen", 4.5)]
        let words = spoken.map { (text, at) -> Word in
            let start = Frame(at * 48_000)
            return Word(text: text, start: start, end: start + 14_400)
        }
        p.setTranscript(SourceTranscript(sourceID: p.sources[0].id, language: "sv-SE", engine: "t", words: words))
        return (p, pool)
    }

    @Test("The catalogue comes from the registry: every step and the macros, compact")
    func catalogue() {
        let names = Set(actions.map(\.name))
        #expect(Operations.all.allSatisfy { names.contains($0.name) || AssistantCatalog.stepsNotForAssistant.contains($0.name) })
        #expect(names.isSuperset(of: ["restore", "transcribe", "remove_fillers", "remove_silences"]))
        let text = AssistantCatalog.catalogue(actions)
        #expect(text.contains("- gain(db*, start, end):"))
        #expect(text.contains("kind*=dehum|declip|declick|denoise"))
        #expect(text.count < 6_000)
    }

    @Test("Values are typed by the registry; invalid steps are dropped, not run")
    func parsing() {
        let s = PlanParser.typed(op: "normalize", args: [("target", "loudness"), ("level", "−16"), ("bogus", "1")], why: "", actions: actions)
        #expect(s?.params == ["target": .string("loudness"), "level": .number(-16)])
        let plan = PlanParser.validate(AssistantPlan(reply: "", steps: [s!, PlannedStep(op: "gain"), PlannedStep(op: "make_coffee"),
                                                                         PlannedStep(op: "echo", params: ["delay": .number(9)])]), actions: actions)
        #expect(plan.steps.map(\.op) == ["normalize"])
        #expect(plan.dropped.count == 3)
        #expect(plan.isDestructive(actions) == false)
        #expect(AssistantPlan(reply: "", steps: [PlannedStep(op: "remove_fillers")]).isDestructive(actions))
    }

    @Test("Macros become concrete steps against the document as it will be")
    func macros() throws {
        let (p, pool) = project()
        let state = EditState(project: p, pool: pool)
        let steps = try MacroExpander.expand([PlannedStep(op: "remove_fillers"), PlannedStep(op: "remove_silences", params: ["min_length": .number(1), "keep": .number(0.3)])], state: state)
        #expect(steps.first?.op == "delete_words")
        #expect(steps.dropFirst().allSatisfy { $0.op == "delete" } && steps.count == 2)
        var run = state
        let r = StepRunner.run(steps, on: &run) { _, _ in LoudnessResult(integrated: nil, range: nil, maxMomentary: nil, maxShortTerm: nil, samplePeak: 0, truePeak: 0, duration: 0) }
        #expect(r.allSatisfy { $0.status == .done })
        #expect(run.project.transcriptText() == "hej och välkommen igen")
        // The 1.7 s pause is now about 0.3 s: the document is about 1.4 s plus the fillers shorter.
        let shorter = 6 - run.project.duration
        #expect(shorter > 1.8 && shorter < 2.2, "shortened by \(shorter) s")
    }

    @Test("OpenRouter: tools from the registry, tool calls become steps, cost is read; no key, no call")
    func openRouter() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockModelService.self]
        let session = URLSession(configuration: config)
        MockModelService.reply = Data(#"{"choices":[{"message":{"content":"Jag normaliserar.","tool_calls":[{"function":{"name":"normalize","arguments":"{\"target\":\"loudness\",\"level\":-16}"}},{"function":{"name":"nope","arguments":"{}"}}]}}],"usage":{"cost":0.0012}}"#.utf8)
        let planner = OpenRouterPlanner(endpoint: URL(string: "https://mock.local/api/v1")!, model: "test/model", key: { "sk-test" }, session: session)
        let (p, _) = project()
        let plan = try await planner.plan(goal: "normalisera till -16 LUFS", context: AssistantContext(project: p, selection: nil, playhead: 0), history: [], actions: actions)
        #expect(plan.steps == [PlannedStep(op: "normalize", params: ["target": .string("loudness"), "level": .number(-16)])])
        #expect(plan.dropped == ["nope"] && plan.cost == 0.0012 && plan.reply == "Jag normaliserar.")
        let tools = MockModelService.lastBody["tools"] as? [[String: Any]] ?? []
        #expect(tools.count == actions.count)
        let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        #expect(names.allSatisfy { $0.range(of: "^[a-zA-Z0-9_-]{1,64}$", options: .regularExpression) != nil })
        let noKey = OpenRouterPlanner(model: "x", key: { nil }, session: session)
        await #expect(throws: AssistantError.noKey) { try await noKey.plan(goal: "normalize to -16 LUFS", context: AssistantContext(project: p, selection: nil, playhead: 0), history: [], actions: actions) }
        #expect(planner.paid && !OnDevicePlanner().paid)
    }

    @Test("Sibling tools are named slug_name")
    func siblingNames() {
        let a = AssistantAction(name: "canvas.addNote", description: "", params: [], kind: .sibling(slug: "flimmer", method: "POST", path: "/x"), destructive: false)
        #expect(OpenRouterPlanner.toolName(a) == "flimmer_canvas_addNote")
    }

    @Test("The on-device schema builds from the catalogue")
    func schema() throws {
        _ = try OnDevicePlanner.schema(actions)
    }

    @Test("The keyword safety net adds a missed filler or pause step, and nothing else")
    func augment() {
        let only = AssistantPlan(reply: "", steps: [PlannedStep(op: "remove_silences", params: ["min_length": .number(1)])])
        #expect(PlanParser.augment(goal: "ta bort alla ehm och tystnader längre än en sekund", plan: only).steps.map(\.op) == ["remove_fillers", "remove_silences"])
        #expect(PlanParser.augment(goal: "remove the pauses", plan: AssistantPlan(reply: "", steps: [])).steps.map(\.op) == ["remove_silences"])
        #expect(PlanParser.augment(goal: "normalisera till -16 LUFS", plan: only).steps.map(\.op) == ["remove_silences"])
        #expect(PlanParser.augment(goal: "cut 10 to 15", plan: AssistantPlan(reply: "", steps: [PlannedStep(op: "delete")])).steps.map(\.op) == ["delete"])
    }

    @Test("Clock times become seconds")
    func clockTimes() {
        #expect(PlanParser.typed(op: "add_marker", args: [("at", "1:30"), ("name", "K")], why: "", actions: actions)?.params["at"] == .number(90))
        #expect(PlanParser.typed(op: "set_playhead", args: [("at", "1:02:03")], why: "", actions: actions)?.params["at"] == .number(3_723))
    }

    @Test("Guardrails: recording and deleting files are refused, vague requests get a question, real tasks pass")
    func guardrails() {
        #expect(PlanParser.guardrail("spela in en ny tagning")?.contains("inspelning") == true)
        #expect(PlanParser.guardrail("delete the original file from disk") != nil)
        #expect(PlanParser.guardrail("fixa ljudet")?.hasPrefix("Vad vill du") == true)
        #expect(PlanParser.guardrail("make it better") != nil)
        #expect(PlanParser.guardrail("move the file to my desktop") != nil)
        for task in ["the recording is distorted", "turn everything up a bit", "ta bort alla ehm", "normalize to -16 LUFS", "fade in the first two seconds", "ta bort brummet på talare 2", "cut from 10 to 15 seconds", "hur högt är det, i LUFS?"] {
            #expect(PlanParser.guardrail(task) == nil, "\(task)")
        }
    }

    @Test("Plan impact: numbers from the steps, and warnings for the hold-out set's dangerous plans")
    func impact() {
        let (p, pool) = project()
        let state = EditState(project: p, pool: pool)
        // "tona ut de sista två sekunderna" planned as a delete.
        let fadeAsDelete = AssistantPlan(reply: "", steps: [PlannedStep(op: "delete", params: ["start": .number(4), "end": .number(6)])])
        let a = PlanImpact.compute(fadeAsDelete, goal: "tona ut de sista två sekunderna", state: state)
        #expect(a.lines == ["Deletes 2.0 s of 6.0 s at the end."])
        #expect(a.warnings.count == 2)   // 33 % and no removal verb
        // "radera originalfilen" planned as cutting everything.
        let cutAll = PlanImpact.compute(AssistantPlan(reply: "", steps: [PlannedStep(op: "cut", params: ["start": .number(0), "end": .number(6)])]),
                                        goal: "radera originalfilen från disken", state: state)
        #expect(cutAll.lines.first == "Deletes 6.0 s of 6.0 s the whole document.")
        #expect(cutAll.fractionRemoved == 1 && cutAll.isAlarming)
        // A real fade: no warnings.
        let fade = PlanImpact.compute(AssistantPlan(reply: "", steps: [PlannedStep(op: "fade_out", params: ["start": .number(4), "end": .number(6)])]),
                                      goal: "tona ut de sista två sekunderna", state: state)
        #expect(fade.lines == ["Fades out over 2.0 s at the end."] && !fade.isAlarming)
        // Fillers and pauses asked for: numbers, and no verb warning.
        let clean = PlanImpact.compute(AssistantPlan(reply: "", steps: [PlannedStep(op: "remove_fillers"), PlannedStep(op: "remove_silences")]),
                                       goal: "ta bort alla ehm och tystnader", state: state)
        #expect(clean.lines.count == 2 && clean.lines[0].hasPrefix("Removes 2 words"))
        #expect(!clean.warnings.contains { $0.contains("doesn't ask") })
    }
}
