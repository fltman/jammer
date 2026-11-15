import Foundation
import JammerAgent

/// Glimmer and Flimmer as tools for the assistant (SIBLINGS.md §1–3): found on their
/// local ports, their operations become actions named `<slug>_<name>`, and calling one
/// works on their frontmost document, exactly as an outside agent would.
public struct Sibling: Sendable {
    public var slug: String
    public var name: String
    public var port: Int
    public var header: String
    public var actions: [AssistantAction]
}

public enum SiblingDirectory {
    static let table: [(slug: String, name: String, first: Int, rest: ClosedRange<Int>, header: String)] = [
        ("glimmer", "Glimmer", 9001, 9101...9119, "X-Glimmer-Agent"),
        ("flimmer", "Flimmer", 9002, 9201...9219, "X-Flimmer-Agent"),
    ]

    /// Finds the siblings that run. 1 s on the first port, about 300 ms on the rest.
    public static func discover(session: URLSession = .shared) async -> [Sibling] {
        await withTaskGroup(of: Sibling?.self) { group in
            for entry in table {
                group.addTask {
                    for (i, port) in ([entry.first] + Array(entry.rest)).enumerated() {
                        guard let status = await get("http://127.0.0.1:\(port)/api/v1/status", timeout: i == 0 ? 1 : 0.3, session: session),
                              (status["app"] as? [String: Any])?["name"] as? String == entry.name else { continue }
                        let ops = await get("http://127.0.0.1:\(port)/api/v1/operations", timeout: 2, session: session)?["operations"] as? [[String: Any]] ?? []
                        return Sibling(slug: entry.slug, name: entry.name, port: port, header: entry.header, actions: actions(from: ops, slug: entry.slug))
                    }
                    return nil
                }
            }
            var out: [Sibling] = []
            for await s in group { if let s { out.append(s) } }
            return out.sorted { $0.slug < $1.slug }
        }
    }

    static func get(_ url: String, timeout: TimeInterval, session: URLSession) async -> [String: Any]? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u, timeoutInterval: timeout)
        req.setValue("jammer", forHTTPHeaderField: "X-Sibling")
        guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A sibling's operation list as actions. Paid operations are left out: the assistant
    /// never sends allowPaid to a sibling on its own.
    public static func actions(from ops: [[String: Any]], slug: String) -> [AssistantAction] {
        ops.compactMap { op in
            guard let name = op["name"] as? String, op["paid"] as? Bool != true else { return nil }
            let schema = op["params"] as? [String: Any] ?? [:]
            let props = schema["properties"] as? [String: [String: Any]] ?? [:]
            let required = Set(schema["required"] as? [String] ?? [])
            let params = props.keys.sorted().compactMap { key -> OperationSpec.Param? in
                let p = props[key]!
                // The document id is filled in by Jämmer (the sibling's frontmost document).
                if p["x-in"] as? String == "path", key == "id" { return nil }
                let kind: OperationSpec.Param.Kind = switch p["type"] as? String {
                case "number", "integer": .number
                case "boolean": .boolean
                case "array": .list
                default: .string
                }
                let range: ClosedRange<Double>? = (p["minimum"] as? Double).flatMap { lo in (p["maximum"] as? Double).map { lo...$0 } }
                var param = OperationSpec.Param(key, kind, p["description"] as? String ?? "", required: required.contains(key),
                                                options: p["enum"] as? [String], range: range)
                param.location = p["x-in"] as? String
                return param
            }
            let call = op["call"] as? [String: String]
            return AssistantAction(name: name, description: op["description"] as? String ?? "", params: params,
                                   kind: .sibling(slug: slug, method: call?["method"], path: call?["path"]), destructive: true)
        }
    }

    /// The request that runs `action` with `params` on the sibling's frontmost document.
    public static func request(_ sibling: Sibling, _ action: AssistantAction, _ params: [String: JSONValue], documentID: String) -> URLRequest? {
        guard case .sibling(_, let method, let path) = action.kind else { return nil }
        var url: URLComponents
        var body: [String: Any]
        if let method, let path {
            url = URLComponents(string: "http://127.0.0.1:\(sibling.port)" + path.replacingOccurrences(of: "{id}", with: documentID))!
            var query: [URLQueryItem] = []
            body = [:]
            for (k, v) in params {
                let loc = action.params.first { $0.name == k }?.location
                if loc == "query" { query.append(URLQueryItem(name: k, value: v.queryText)) } else if loc != "path" { body[k] = v.any }
            }
            if !query.isEmpty { url.queryItems = query }
            var req = URLRequest(url: url.url!, timeoutInterval: 30)
            req.httpMethod = method
            if method != "GET" { req.httpBody = try? JSONSerialization.data(withJSONObject: body) }
            return finish(req, sibling)
        }
        url = URLComponents(string: "http://127.0.0.1:\(sibling.port)/api/v1/documents/\(documentID)/steps")!
        body = ["steps": [["op": action.name, "params": params.mapValues(\.any)]], "allowPaid": false]
        var req = URLRequest(url: url.url!, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return finish(req, sibling)
    }

    static func finish(_ r: URLRequest, _ s: Sibling) -> URLRequest {
        var req = r
        req.setValue("1", forHTTPHeaderField: s.header)
        req.setValue("jammer", forHTTPHeaderField: "X-Sibling")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return req
    }

    /// Runs it on the sibling's frontmost document; returns a one-line outcome.
    public static func run(_ sibling: Sibling, _ action: AssistantAction, _ params: [String: JSONValue], session: URLSession = .shared) async -> String {
        let docs = await get("http://127.0.0.1:\(sibling.port)/api/v1/documents", timeout: 2, session: session)?["documents"] as? [[String: Any]] ?? []
        guard let doc = docs.first(where: { $0["frontmost"] as? Bool == true }) ?? docs.first, let id = doc["id"] as? String else {
            return "\(sibling.name) has no open document."
        }
        guard let req = request(sibling, action, params, documentID: id), let (data, resp) = try? await session.data(for: req) else {
            return "\(sibling.name) didn't answer."
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let err = obj?["error"] as? [String: Any] { return "\(sibling.name): \(err["message"] as? String ?? "error \(code)")" }
        if let job = obj?["job"] as? [String: Any] { return "\(sibling.name) started \(job["kind"] as? String ?? "a job")." }
        return code < 300 ? "\(sibling.name) did \(action.name) in “\(doc["name"] as? String ?? "its document")”." : "\(sibling.name) answered \(code)."
    }
}

extension JSONValue {
    var queryText: String {
        switch self {
        case .number(let d): d == d.rounded() ? String(Int(d)) : String(d)
        case .string(let s): s
        case .bool(let b): String(b)
        case .array(let a): a.map(\.queryText).joined(separator: ",")
        case .null: ""
        }
    }
}
