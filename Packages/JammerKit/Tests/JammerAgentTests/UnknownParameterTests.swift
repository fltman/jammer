import Foundation
import Testing
@testable import JammerAgent
import JammerCore

/// SIBLINGS.md §3 (2026-11-16): a name Jämmer doesn't know is refused before anything is done, so that a
/// 2xx answer means every value sent was used. Everything here goes through the registry and the route
/// table, so a new step or endpoint can't be left out.
@Suite("Unknown parameters are refused, everywhere")
struct UnknownParameterTests {
    /// A value of the right sort for a parameter, inside its range and among its options.
    static func value(for p: OperationSpec.Param) -> JSONValue {
        switch p.kind {
        case .seconds: .number(p.range?.lowerBound ?? 1)
        case .number: .number(p.range?.lowerBound ?? 1)
        case .string: .string(p.options?.first ?? "x")
        case .boolean: .bool(true)
        case .list: .array([.string("x")])
        case .numbers: .array([.number(1)])
        }
    }

    @Test("Every step in the registry refuses a parameter it doesn't have, by name, and takes rationale")
    func steps() {
        let unknown = "notAParameterOfAnything"
        var checked = 0
        for spec in Operations.all {
            var params: [String: JSONValue] = [:]
            for p in spec.params where p.required { params[p.name] = Self.value(for: p) }
            // As it is, the step passes the check (so that what fails next is the stranger, not something else).
            #expect(throws: Never.self, "\(spec.name) with only its required parameters") { try StepRunner.validate(Step(op: spec.name, params: params)) }
            var with = params
            with[unknown] = .number(3)
            do {
                try StepRunner.validate(Step(op: spec.name, params: with))
                Issue.record("\(spec.name) took \(unknown)")
            } catch {
                #expect(error.localizedDescription.contains("has no parameter \"\(unknown)\""), "\(spec.name): \(error.localizedDescription)")
            }
            var why = params
            why[AgentAPI.rationale] = .string("because")
            #expect(throws: Never.self, "\(spec.name) with rationale") { try StepRunner.validate(Step(op: spec.name, params: why)) }
            checked += 1
        }
        #expect(checked == Operations.all.count && checked > 40)
    }

    @Test("Every schema handed out is closed, all the way down, and has rationale")
    func schemas() {
        func open(_ any: Any, _ path: String) -> [String] {
            var found: [String] = []
            if let d = any as? [String: Any] {
                if d["type"] as? String == "object", d["additionalProperties"] as? Bool != false { found.append(path) }
                for (k, v) in d { found += open(v, path + "/" + k) }
            } else if let a = any as? [Any] {
                for (i, v) in a.enumerated() { found += open(v, path + "/\(i)") }
            }
            return found
        }
        for spec in Operations.all + Operations.endpoints {
            let schema = spec.schema
            #expect(open(schema, spec.name) == [], "\(spec.name)")
            #expect(((schema["properties"] as? [String: Any])?[AgentAPI.rationale] as? [String: Any])?["type"] as? String == "string", "\(spec.name)")
        }
    }

    @Test("restore's settings per kind are published closed, with ranges, and say what the parser enforces")
    func byType() throws {
        for name in ["restore", "restore_preview"] {
            let spec = try #require(Operations.endpoints.first { $0.name == name })
            let kind = try #require((spec.schema["properties"] as? [String: Any])?["kind"] as? [String: Any])
            let table = try #require(kind["x-byType"] as? [String: [String: Any]])
            #expect(Set(table.keys) == Set(Restoration.availableKinds.map(\.rawValue)))
            for (k, schema) in table {
                #expect(schema["additionalProperties"] as? Bool == false, "\(k)")
                let props = try #require(schema["properties"] as? [String: [String: Any]])
                #expect(props["amount"]?["maximum"] as? Int == 1)
                #expect((props["humFrequency"] != nil) == (k == "dehum") && (props["sensitivity"] != nil) == (k == "declick"), "\(k)")
            }
        }
        // And the parser holds to it: a setting of another kind is refused.
        #expect(throws: AgentAPI.APIError.self) { try RestoreRequest.parse(["kind": "declick", "humFrequency": 50]) }
        #expect(throws: AgentAPI.APIError.self) { try RestoreRequest.parse(["kind": "dehum", "sensitivity": 2]) }
        #expect(throws: Never.self) { try RestoreRequest.parse(["kind": "dehum", "humFrequency": 50, "amount": 0.5, "rationale": "the hum"]) }
    }

    @Test("Every route the guide documents, and every endpoint in the registry, is in the table; each refuses a strange query parameter and a strange field, and takes what it says it takes")
    func routes() throws {
        let routes = AgentAPI.routes
        // The guide's table of endpoints: | METHOD | `/path` | …
        let guide = AgentAPI.guide(port: 9003, appVersion: "0", features: .init(dereverb: true, spectralFreeform: true, clap: true))
        var documented = 0
        for line in guide.split(separator: "\n") {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count > 3, ["GET", "POST", "PUT", "DELETE"].contains(cells[1]), cells[2].hasPrefix("`/") else { continue }
            let path = cells[2].dropFirst().prefix { $0 != "`" && $0 != "?" }
            let parts = path.split(separator: "/").map(String.init)
            #expect(routes.contains { $0.method == cells[1] && $0.pattern.count == parts.count && zip($0.pattern, parts).allSatisfy { $0 == "*" || $0 == $1 || $1.hasPrefix("{") } },
                    "\(cells[1]) \(path) is in the guide and not in the table")
            documented += 1
        }
        #expect(documented > 35)
        for spec in Operations.endpoints {
            guard let call = spec.call else { continue }
            #expect(routes.contains { $0.method == call.method && $0.path.split(separator: "/").count == call.path.split(separator: "/").count }, "\(spec.name)")
        }
        for r in routes {
            let path = r.pattern.map { $0 == "*" ? "some-id" : $0 }
            func refused(query: [String] = [], body: [String: Any]? = nil) -> String? {
                do {
                    try AgentAPI.checkParameters(method: r.method, path: path, query: query, body: body.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data())
                    return nil
                } catch { return error.message }
            }
            #expect(refused(query: ["brightness"])?.contains("has no query parameter \"brightness\"") == true, "\(r.method) \(r.path)")
            #expect(refused(query: Array(r.query) + [AgentAPI.rationale]) == nil, "\(r.method) \(r.path)")
            if let body = r.body {
                #expect(refused(body: ["brightness": 3])?.contains("has no field \"brightness\"") == true, "\(r.method) \(r.path)")
                var all: [String: Any] = [AgentAPI.rationale: "because"]
                for k in body { all[k] = 1 }
                #expect(refused(body: all) == nil, "\(r.method) \(r.path)")
            }
        }
        // A route that isn't there is left to the dispatcher's 404.
        #expect(throws: Never.self) { try AgentAPI.checkParameters(method: "GET", path: ["api", "v1", "nothing"], query: ["x"], body: Data()) }
    }

    @Test("Beside op and params a step has nothing; a batch's export and its jobs have only what they take")
    func nested() throws {
        func steps(_ json: String) -> String? {
            do { _ = try AgentAPI.parseSteps(Data(json.utf8)); return nil } catch { return error.message }
        }
        #expect(steps(#"{"steps":[{"op":"gain","params":{"db":-3}}]}"#) == nil)
        #expect(steps(#"{"steps":[{"op":"gain","params":{"db":-3},"db":-6}]}"#)?.contains("has no field \"db\"") == true)
        #expect(steps(#"{"steps":[{"op":"gain","params":{"db":-3,"brightness":1}}]}"#)?.contains("has no parameter \"brightness\"") == true)
        #expect(steps(#"{"steps":[{"op":"gain","rationale":"quieter","params":{"db":-3,"rationale":"quieter"}}]}"#) == nil)
        let dir = FileManager.default.temporaryDirectory.appending(path: "jammer-unknown-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir.appending(path: "in"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "in/a.wav")
        let w = try WAVWriter(url: file, options: .init(encoding: .int16, channels: 1, sampleRate: 48_000))
        try w.write([Float](repeating: 0.1, count: 4_800)); try w.finish()
        func batch(_ more: [String: Any]) -> String? {
            var body: [String: Any] = ["files": [file.path], "output": dir.appending(path: "out").path]
            for (k, v) in more { body[k] = v }
            do { _ = try BatchRequest.parse(body, policy: nil); return nil } catch { return (error as? BatchError)?.message ?? "\(error)" }
        }
        #expect(batch([:]) == nil)
        #expect(batch(["export": ["format": "wav", "bitDepth": 16]]) == nil)
        #expect(batch(["export": ["format": "wav", "quality": 9]])?.contains("export has no field \"quality\"") == true)
        #expect(batch(["export": "wav"])?.contains("export must be an object") == true)
        #expect(batch(["brightness": 1])?.contains("brightness") == true)
        #expect(batch(["jobs": [["op": "restore", "params": ["kind": "dehum"], "when": "now"]]])?.contains("A job has no field \"when\"") == true)
        #expect(batch(["jobs": [["op": "restore", "params": ["kind": "dehum", "strength": 2]]]])?.contains("has no parameter \"strength\"") == true)
        // rationale, wherever a model might put it: beside the fields, in export, in a job, in a job's params.
        #expect(batch(["rationale": "why", "export": ["format": "wav", "rationale": "why"],
                       "jobs": [["op": "restore", "rationale": "why", "params": ["kind": "dehum", "rationale": "why"]]]]) == nil)
        // The timeline import fails here for its own reason (the file isn't there), never for rationale.
        do { _ = try TimelineImport.check(["path": "/nowhere/x.fcpxml", "rationale": "why"], policy: nil); Issue.record("a file that isn't there was read") }
        catch { #expect(!"\(error)".contains("rationale") && !"\(error)".contains("Unknown field"), "\(error)") }
        do { _ = try TimelineImport.check(["path": "/nowhere/x.fcpxml", "frameRate": 25], policy: nil); Issue.record("an unknown field was taken") }
        catch { #expect("\(error)".contains("frameRate"), "\(error)") }
    }
}
