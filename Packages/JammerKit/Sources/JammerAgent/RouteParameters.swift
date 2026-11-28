import Foundation
import JammerCore

/// What every route of the agent API takes by name: in the query, and in a JSON body. A name that isn't
/// here is refused before anything is done (SIBLINGS.md §3, 2026-11-16): a 2xx answer means every value
/// that was sent was used. The endpoints that are also in the operation registry get their names from
/// it; what is written here is added to that, so a parameter can't be in the schema and refused.
extension AgentAPI {
    public struct RouteParameters: Sendable {
        public var method: String
        /// Path components; "*" stands for one of any value (an id).
        public var pattern: [String]
        public var query: Set<String>
        /// The names a JSON body may have. nil: the body isn't a JSON object of named values here
        /// (audio bytes, or nothing), and is not looked at.
        public var body: Set<String>?

        init(_ method: String, _ path: String, query: Set<String> = [], body: Set<String>? = []) {
            self.method = method
            pattern = path.split(separator: "/").map { $0.hasPrefix("{") ? "*" : String($0) }
            self.query = query
            self.body = body
        }
        func matches(_ method: String, _ path: [String]) -> Bool {
            method == self.method && path.count == pattern.count && zip(pattern, path).allSatisfy { $0 == "*" || $0 == $1 }
        }
        public var path: String { "/" + pattern.map { $0 == "*" ? "{id}" : $0 }.joined(separator: "/") }
    }

    /// A field a model adds out of habit to say why it calls a tool. Accepted everywhere, used nowhere.
    public static let rationale = "rationale"

    private static let range: Set<String> = ["start", "end"]
    private static let tracks: Set<String> = ["tracks", "track"]
    private static let doc = "/api/v1/documents/{id}"

    /// Written by hand from what each handler reads.
    static var writtenRoutes: [RouteParameters] { [
        .init("GET", "/"), .init("GET", "/api"), .init("GET", "/api/v1"), .init("GET", "/jammer"), .init("GET", "/jammer.md"),
        .init("GET", "/api/v1/status"), .init("GET", "/api/v1/operations"), .init("GET", "/api/v1/storage"),
        .init("GET", "/api/v1/requirements"), .init("POST", "/api/v1/settings/open", body: ["pane"]),
        .init("GET", "/api/v1/plugins", query: ["q", "format"]),
        .init("POST", "/api/v1/plugins/scan", body: ["force"]),
        .init("POST", "/api/v1/batch", body: BatchRequest.fields),
        .init("POST", "/api/v1/import/fcpxml", body: ["path"]),
        .init("POST", "/api/v1/import/timeline", body: ["path", "rate"]),
        .init("GET", "/api/v1/documents"),
        // The body is the audio itself, or JSON that says where the audio is.
        .init("POST", "/api/v1/documents", query: ["name", "order"], body: ["name", "audio", "upload"]),
        .init("POST", "/api/v1/uploads"),
        .init("GET", "/api/v1/uploads/{id}"), .init("DELETE", "/api/v1/uploads/{id}"),
        .init("PUT", "/api/v1/uploads/{id}", query: ["offset"], body: nil),
        .init("GET", "/api/v1/jobs/{id}"), .init("DELETE", "/api/v1/jobs/{id}"),
        // One short turn of speech: the body is the WAV itself (TurnTranscription).
        .init("POST", "/api/v1/transcribe", query: ["language", "engine"], body: nil),
        // A whole file for another app: the audio itself, or JSON naming an upload; never a path (FileTranscription).
        .init("POST", "/api/v1/transcribe/file", query: ["language", "engine"], body: ["upload"]),
        .init("GET", doc), .init("DELETE", doc),
        // What Send to Flimmer would send, and each item's file (FlimmerSend.returnPreview).
        .init("GET", doc + "/flimmer-return", query: ["mode"]),
        .init("GET", doc + "/recording"),
        .init("GET", doc + "/flimmer-return/{n}/audio", query: ["mode", "bitDepth"]),
        .init("POST", doc + "/steps", body: ["steps", "allowPaid"]),
        .init("POST", doc + "/undo"),
        .init("POST", doc + "/save"), .init("POST", doc + "/redo"),
        .init("POST", doc + "/duplicate"),
        .init("GET", doc + "/analysis", query: range.union(tracks)),
        .init("GET", doc + "/analysis/rhythm", query: range.union(tracks)),
        .init("GET", doc + "/analysis/dialogue", query: range.union(["profile"])),
        .init("GET", doc + "/analysis/restoration", query: range.union(tracks)),
        .init("GET", doc + "/analysis/acx"),
        .init("GET", doc + "/waveform", query: range.union(["width"])),
        .init("POST", doc + "/transcribe-voice-tracks", body: ["tracks", "splitTrack", "nameSpeakers"]),
        .init("GET", doc + "/transcript/export", query: range.union(["format", "track"])),
        .init("POST", doc + "/transcribe", body: ["language", "engine", "replace", "allowPaid", "allowUnknownPrice", "model"]),
        .init("GET", doc + "/transcript", query: range),
        .init("GET", doc + "/history"), .init("POST", doc + "/history/{node}"),
        .init("POST", doc + "/separate", body: ["model", "tracks"]),
        .init("POST", doc + "/diarize", body: ["mode", "tracks"]),
        .init("GET", doc + "/speakers"),
        // Overdub (paid: the voice service's own price list).
        .init("GET", doc + "/voices"),
        .init("POST", doc + "/voices", body: ["name", "attest", "adult", "consent", "samples", "allowPaid", "allowUnknownPrice"]),
        .init("DELETE", doc + "/voices/{voice}"),
        .init("POST", doc + "/overdub", body: ["voice", "start", "end", "text", "track", "model", "allowPaid", "allowUnknownPrice"]),
        .init("GET", doc + "/mixer"),
        .init("GET", doc + "/automation", query: ["strip", "param", "at", "to", "insert", "parameter"]),
        .init("GET", doc + "/tracks"),
        .init("POST", doc + "/tracks", query: ["name", "at", "gainDB"], body: ["name", "audio", "upload"]),
        .init("GET", doc + "/tracks/{track}/inserts/{insert}"), .init("GET", doc + "/buses/{bus}/inserts/{insert}"),
        .init("GET", doc + "/master/inserts/{insert}"),
        .init("GET", doc + "/tracks/{track}/drift", query: ["against"]),
        .init("GET", doc + "/chapters", query: range),
        .init("POST", doc + "/restore", body: RestoreRequest.fields),
        .init("POST", doc + "/restore/preview", body: RestoreRequest.fields),
        .init("POST", doc + "/export/timeline", body: ["format"]),
        .init("POST", doc + "/export", body: ["tracks", "format", "bitDepth", "bitRate", "start", "end", "targetLUFS", "compensate", "sampleRate", "dither", "chapters", "objects"]),
        .init("POST", doc + "/play", body: ["at"]),
        .init("POST", doc + "/stop"),
        .init("POST", doc + "/solo", body: ["strips"]),
        .init("GET", doc + "/debug/heard"),
    ] }

    /// The written routes with the registry's parameters added to them.
    public static var routes: [RouteParameters] {
        var all = writtenRoutes
        for spec in Operations.endpoints {
            guard let call = spec.call else { continue }
            var found = RouteParameters(call.method, call.path)
            let at = all.firstIndex { $0.method == found.method && $0.pattern == found.pattern }
            if let at { found = all[at] }
            for p in spec.allParams where p.location != "path" {
                if p.location == "query" { found.query.insert(p.name) } else { found.body = (found.body ?? []).union([p.name]) }
            }
            if let at { all[at] = found } else { all.append(found) }
        }
        return all
    }

    /// Refuses a name the route doesn't take, in the query or in a JSON body, saying which and what it
    /// does take. A route that isn't known here is left to the dispatcher (which answers 404).
    public static func checkParameters(method: String, path: [String], query: [String], body: Data) throws(APIError) {
        guard let route = routes.first(where: { $0.matches(method, path) }) else { return }
        let here = "\(method) /\(path.joined(separator: "/"))"
        func takes(_ names: Set<String>) -> String { names.isEmpty ? "It takes none." : "It takes: \(names.sorted().joined(separator: ", "))." }
        if let unknown = query.sorted().first(where: { !route.query.contains($0) && $0 != rationale }) {
            throw .badRequest("\(here) has no query parameter \"\(unknown)\". \(takes(route.query))")
        }
        guard let allowed = route.body, !body.isEmpty, let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return }
        if let unknown = object.keys.sorted().first(where: { !allowed.contains($0) && $0 != rationale }) {
            throw .badRequest("\(here) has no field \"\(unknown)\" in its body. \(takes(allowed))")
        }
    }

    /// What a call is told before its document is looked up (Drömmer 3baad5a; Flimmer's K2a: the schema first, then
    /// the document, then what is missing, the price last): the method its path takes (405), and a JSON body against
    /// the operation the route is, its values' kinds, options and ranges and what is required (400). nil: nothing
    /// to say here. Names the route doesn't take at all are checkParameters' (it runs first).
    public static func schemaRefusal(method: String, path: [String], body: Data) -> APIError? {
        let forPath = routes.filter { $0.pattern.count == path.count && zip($0.pattern, path).allSatisfy { $0 == "*" || $0 == $1 } }
        guard !forPath.isEmpty else { return nil }
        guard forPath.contains(where: { $0.method == method }) else {
            let methods = Array(Set(forPath.map(\.method))).sorted()
            return APIError(405, "method_not_allowed", "\(method) isn't allowed here; use \(methods.joined(separator: " or ")).")
        }
        let pattern = forPath.first { $0.method == method }!.pattern
        guard let spec = (Operations.all + Operations.endpoints).first(where: { spec in
                  guard let call = spec.call else { return false }
                  return call.method == method && RouteParameters(call.method, call.path).pattern == pattern
              }),
              !body.isEmpty, let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        var params: [String: JSONValue] = [:]
        for (k, v) in object where spec.params.contains(where: { $0.name == k }) {
            guard let j = JSONValue(v) else { return .badRequest("\(spec.name): \"\(k)\" must be a number, string, boolean or list.") }
            params[k] = j
        }
        do { try StepRunner.validate(Step(op: spec.name, params: params), against: spec) } catch {
            return .badRequest(error.localizedDescription)
        }
        return nil
    }
}
