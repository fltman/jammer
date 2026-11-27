import Foundation
import Testing
@testable import JammerAgent

/// An agent is told why a call can't work in the series' one order, one condition at a time: the schema first, then
/// the document, then what is missing (a model, a key), and the price last (Flimmer's K2a: its baseline said 402
/// before "no one signed in"; the-apps COMFORT.md 706a66d). Jämmer has no sign-in; the document is looked up by the
/// router before any route runs, and that and the routes' requirements before the price are tried against the app in
/// the gathered round. Here: each condition alone for the steps, and the routes' price checks only in CallChecks'
/// price stage.
@Suite("The order of an agent's refusals: schema, document, what is missing, price")
struct CallOrderTests {
    func status(_ json: String) -> Int? {
        do { _ = try AgentAPI.parseSteps(Data(json.utf8)); return nil } catch { return error.status }
    }

    @Test("Steps, each condition alone: a bad body, a bad value, an unknown op, a paid endpoint's name (never 402)")
    func steps() {
        #expect(status(#"{"steps": 3}"#) == 400, "a body that isn't steps")
        #expect(status(#"{"steps": [{"op": "add_marker", "params": {"at": "soon"}}]}"#) == 400, "a value of the wrong kind")
        #expect(status(#"{"steps": [{"op": "no_such_op"}]}"#) == 404, "an op that doesn't exist")
        // The paid calls are endpoints of their own, never steps: as a step a paid name is unknown, without allowPaid too.
        for paid in Operations.endpoints.filter(\.paid).map(\.name) {
            #expect(status(#"{"steps": [{"op": "\#(paid)", "params": {}}]}"#) == 404, "\(paid) as a step")
        }
        #expect(status(#"{"steps": [{"op": "add_marker", "params": {"name": "A", "at": 1}}]}"#) == nil, "a good step passes")
    }

    @Test("Routes, the schema before the document: a bad value or method on a document that isn't there is 400 or 405, not 404")
    func schemaBeforeDocument() {
        let missing = ["api", "v1", "documents", "00000000-0000-0000-0000-000000000000", "transcribe"]
        func refusal(_ method: String, _ body: String) -> Int? { AgentAPI.schemaRefusal(method: method, path: missing, body: Data(body.utf8))?.status }
        #expect(refusal("POST", #"{"engine": "bogus"}"#) == 400, "a value not among the options")
        #expect(refusal("POST", #"{"engine": 3}"#) == 400, "a value of the wrong kind")
        #expect(refusal("GET", "") == 405, "a method the path doesn't take")
        #expect(refusal("POST", #"{"engine": "openai", "language": "sv-SE"}"#) == nil, "a good body: the document comes next (404)")
        #expect(AgentAPI.schemaRefusal(method: "GET", path: ["api", "v1", "documents", "x"], body: Data()) == nil, "a route without a body")
    }

    @Test("In App/AgentServer.swift every price check (allowPaid, paidGates, paid_not_allowed) is in a CallChecks price stage")
    func priceLast() throws {
        let server = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../../App/AgentServer.swift").standardizedFileURL
        let lines = try String(contentsOf: server, encoding: .utf8).components(separatedBy: "\n")
        var stage: String?
        var offenders: [String] = []
        for (n, line) in lines.enumerated() {
            if let m = line.range(of: #"\(\.(schema|requirements|price),"#, options: .regularExpression) {
                stage = String(line[m].dropFirst(2).dropLast())
            }
            let marks = ["\"allowPaid\"] as? Bool", "paidGates(body)", "paidNotAllowed("]
            if let at = marks.compactMap({ line.range(of: $0)?.lowerBound }).min(),
               !line.contains("func paidGates"), !line.contains("e.reason == \"paid_not_allowed\""),
               // paidGates' own body is not a check of its own.
               !lines[max(0, n - 3)...n].contains(where: { $0.contains("func paidGates") }) {
                // On a line of its own, in the stage last opened; on one line with its stages, after "(.price".
                let inline = line.range(of: "(.price,").map { $0.lowerBound < at } ?? false
                if !(inline || stage == "price") { offenders.append("\(n + 1): \(line.trimmingCharacters(in: .whitespaces))") }
            }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("])") { stage = nil }
        }
        #expect(offenders.isEmpty, "a price checked outside CallChecks' price stage: \(offenders)")
    }
}
