import Foundation
import JammerAgent
import Testing
@testable import JammerAssistant

/// A pretend Flimmer on 127.0.0.1:9205; every other port refuses.
final class FakeSiblings: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let url = request.url!
        guard url.port == 9205 else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return
        }
        let body: Any
        switch url.path {
        case "/api/v1/status": body = ["app": ["name": "Flimmer"], "port": 9205]
        case "/api/v1/operations": body = ["operations": [
            ["name": "canvas.addNote", "description": "Adds a note.", "paid": false, "undoable": true, "startsJob": false,
             "params": ["type": "object", "properties": ["text": ["type": "string"], "at": ["type": "number", "minimum": 0, "maximum": 100]], "required": ["text"]]],
            ["name": "generate_shot", "description": "Paid.", "paid": true, "undoable": true, "startsJob": true, "params": ["type": "object", "properties": [:]]],
            ["name": "export_audio", "description": "Exports.", "paid": false, "undoable": false, "startsJob": false,
             "call": ["method": "GET", "path": "/api/v1/documents/{id}/audio"],
             "params": ["type": "object", "properties": ["id": ["type": "string", "x-in": "path"], "format": ["type": "string", "x-in": "query", "enum": ["wav"]]], "required": ["id"]]],
        ]]
        case "/api/v1/documents": body = ["documents": [["id": "A", "name": "Old", "frontmost": false], ["id": "B", "name": "Cut 3", "frontmost": true]]]
        default: body = ["results": [["op": "canvas.addNote", "status": "done"]]]
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Siblings as tools")
struct SiblingToolTests {
    var session: URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FakeSiblings.self]
        return URLSession(configuration: c)
    }

    @Test("Found on a reserve port; paid operations left out; path id hidden, query kept")
    func discover() async throws {
        let found = await SiblingDirectory.discover(session: session)
        let flimmer = try #require(found.first { $0.slug == "flimmer" })
        #expect(found.count == 1 && flimmer.port == 9205)
        #expect(flimmer.actions.map(\.name) == ["canvas.addNote", "export_audio"])
        #expect(OpenRouterPlanner.toolName(flimmer.actions[0]) == "flimmer_canvas_addNote")
        let export = flimmer.actions[1]
        #expect(export.params.map(\.name) == ["format"] && export.params[0].location == "query")
        #expect(flimmer.actions[0].params.first { $0.name == "at" }?.range == 0...100)
        #expect(FakeSiblings.requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Sibling") == "jammer" })
    }

    @Test("A sibling's schema is closed to us: a name it doesn't have is not sent to see what happens; rationale is")
    func closed() async throws {
        let found = await SiblingDirectory.discover(session: session)
        let flimmer = try #require(found.first { $0.slug == "flimmer" })
        let plan = AssistantPlan(reply: "", steps: [
            PlannedStep(op: "canvas.addNote", params: ["text": .string("hello"), "at": .number(5)]),
            PlannedStep(op: "canvas.addNote", params: ["text": .string("hello"), "colour": .string("red")]),
            PlannedStep(op: "canvas.addNote", params: ["text": .string("hello"), "rationale": .string("a note for the editor")]),
            PlannedStep(op: "export_audio", params: ["format": .string("wav"), "bitDepth": .number(16)]),
        ])
        let checked = PlanParser.validate(plan, actions: flimmer.actions)
        #expect(checked.steps.count == 2 && checked.steps.allSatisfy { $0.op == "canvas.addNote" && $0.params["colour"] == nil })
        #expect(checked.dropped.count == 2 && checked.dropped[0].contains("has no parameter \"colour\"") && checked.dropped[1].contains("has no parameter \"bitDepth\""), "\(checked.dropped)")
    }

    @Test("A sibling's settings per sort: read by x-byTypeKey, each name only with its own sort; a table without the key isn't guessed at")
    func byType() {
        let ops: [[String: Any]] = [
            ["name": "add_adjustment", "description": "Adjusts.", "paid": false,
             "params": ["type": "object", "additionalProperties": false, "required": ["type"], "x-byTypeKey": "type",
                        "properties": ["type": ["type": "string", "enum": ["levels", "hue"]], "opacity": ["type": "number"]],
                        "x-byType": ["levels": ["type": "object", "additionalProperties": false, "properties": ["black": ["type": "number", "minimum": 0, "maximum": 1]]],
                                     "hue": ["type": "object", "additionalProperties": false, "properties": ["degrees": ["type": "number"]]]]] as [String: Any]],
            ["name": "apply_filter", "description": "Filters.", "paid": false,
             "params": ["type": "object", "additionalProperties": false, "properties": ["type": ["type": "string"]],
                        "x-byType": ["blur": ["type": "object", "additionalProperties": false, "properties": ["radius": ["type": "number"]]]]] as [String: Any]],
        ]
        let actions = SiblingDirectory.actions(from: ops, slug: "glimmer")
        #expect(actions[0].params.map(\.name).sorted() == ["black", "degrees", "opacity", "type"] && actions[0].byType?.key == "type")
        #expect(actions[1].params.map(\.name) == ["type"] && actions[1].byType == nil && actions[1].uncheckable == ["radius"])
        let plan = AssistantPlan(reply: "", steps: [
            PlannedStep(op: "add_adjustment", params: ["type": .string("levels"), "black": .number(0.1), "opacity": .number(0.5)]),
            PlannedStep(op: "add_adjustment", params: ["type": .string("hue"), "black": .number(0.1)]),
            PlannedStep(op: "add_adjustment", params: ["type": .string("levels"), "gamma": .number(2)]),
            PlannedStep(op: "apply_filter", params: ["type": .string("blur"), "radius": .number(3)]),
            PlannedStep(op: "apply_filter", params: ["type": .string("blur")]),
        ])
        let checked = PlanParser.validate(plan, actions: actions)
        #expect(checked.steps.map(\.op) == ["add_adjustment", "apply_filter"] && checked.steps[0].params["black"] == .number(0.1))
        #expect(checked.dropped.count == 3 && checked.dropped[0].contains("doesn't go with type hue") && checked.dropped[1].contains("has no parameter \"gamma\"")
                && checked.dropped[2].contains("can't be checked"), "\(checked.dropped)")
    }

    @Test("Calls go to the frontmost document: endpoints by call, steps through /steps")
    func calls() async throws {
        let s = session
        let flimmer = try #require(await SiblingDirectory.discover(session: s).first)
        let get = try #require(SiblingDirectory.request(flimmer, flimmer.actions[1], ["format": .string("wav")], documentID: "B"))
        #expect(get.url?.absoluteString == "http://127.0.0.1:9205/api/v1/documents/B/audio?format=wav" && get.httpMethod == "GET")
        #expect(get.value(forHTTPHeaderField: "X-Flimmer-Agent") == "1")
        let step = try #require(SiblingDirectory.request(flimmer, flimmer.actions[0], ["text": .string("Hej")], documentID: "B"))
        #expect(step.url?.path == "/api/v1/documents/B/steps" && step.httpMethod == "POST")
        let body = try JSONSerialization.jsonObject(with: step.httpBody!) as! [String: Any]
        #expect(body["allowPaid"] as? Bool == false)
        let outcome = await SiblingDirectory.run(flimmer, flimmer.actions[0], ["text": .string("Hej")], session: s)
        #expect(outcome.contains("Cut 3"))
    }
}
