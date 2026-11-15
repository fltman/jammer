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
