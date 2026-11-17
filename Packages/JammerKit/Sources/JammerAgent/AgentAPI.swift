import Foundation
import JammerCore

/// The local HTTP API that lets agents drive Jammer: request parsing, the
/// security rules, the error format and the guide. Pure, so it's tested
/// without a socket; the app owns the listener. Same conventions as Glimmer
/// and Flimmer.
public enum AgentAPI {
    public static let appName = "Jammer"

    /// The `app` object of GET /api/v1/status (SIBLINGS.md §2): with the bundle id, so a
    /// sibling never pairs a debug build (com.brattoo.jammer.debug) with a release one.
    /// A debug build, or a visiting test's guest copy of one (com.brattoo.<app>.debug.guest).
    public static func isDebugBundle(_ id: String) -> Bool { id.hasSuffix(".debug") || id.hasSuffix(".debug.guest") }

    public static func appInfo(version: String, bundleID: String?) -> [String: Any] {
        ["name": appName, "displayName": "Jämmer", "version": version, "bundleID": bundleID ?? "com.brattoo.jammer"]
    }
    public static let version = "v1"
    /// Header every state-changing request must carry (a web page can't add it
    /// without a CORS preflight, which the server never grants).
    public static let agentHeader = "X-Jammer-Agent"
    /// 9003 first, then Jammer's own range (Glimmer has 91xx, Flimmer 92xx).
    public static let ports: [UInt16] = [9003] + Array(9301...9319)
    public static let guidePath = "/jammer"

    /// Largest body sent in one request. Bigger files go through /api/v1/uploads.
    public static let maxBody = 256 * 1024 * 1024
    /// Largest upload assembled from chunks.
    public static let maxUpload: Int64 = 16 * 1024 * 1024 * 1024
    /// Largest export returned in one response.
    public static let maxExport: Int64 = 2 * 1024 * 1024 * 1024
    /// Uploads untouched for this long are deleted.
    public static let uploadIdleLimit: TimeInterval = 3_600
    /// Free space to keep on the disk after an upload chunk.
    public static let diskReserve: Int64 = 2 * 1024 * 1024 * 1024

    public static func agentPrompt(port: UInt16) -> String {
        "Learn all about Jämmer and how to interact with it: fetch and follow this guide http://127.0.0.1:\(port)\(guidePath)"
    }

    // MARK: HTTP

    public struct Request: Sendable, Equatable {
        public var method: String
        public var path: String
        public var query: [String: String]
        /// Header names lowercased.
        public var headers: [String: String]
        public var body: Data

        public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
            self.method = method
            self.path = path
            self.query = query
            self.headers = headers
            self.body = body
        }

        public var segments: [String] { path.split(separator: "/").map(String.init) }
    }

    public enum ParseResult: Equatable {
        case incomplete
        case request(Request)
        case invalid(String)
    }

    /// Parses one HTTP/1.1 request from the bytes received so far.
    public static func parse(_ data: Data) -> ParseResult {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 64 * 1024 ? .invalid("Headers too large.") : .incomplete
        }
        guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid("Headers are not UTF-8.")
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid("Malformed request line.") }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .invalid("Bad Content-Length.") }
        guard length <= maxBody else { return .invalid("Body too large: send at most 256 MB per request, or use /api/v1/uploads.") }
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            return .invalid("Chunked bodies aren't supported; send Content-Length.")
        }
        let bodyStart = headerEnd.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return .incomplete }
        let body = data[bodyStart..<(bodyStart + length)]
        let target = String(requestLine[1])
        let parts = target.split(separator: "?", maxSplits: 1)
        var query: [String: String] = [:]
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                query[kv[0]] = kv.count > 1 ? kv[1] : ""
            }
        }
        let path = String(parts.first ?? "/").removingPercentEncoding ?? "/"
        return .request(Request(method: String(requestLine[0]).uppercased(), path: path.isEmpty ? "/" : path,
                                query: query, headers: headers, body: Data(body)))
    }

    public struct Response: Sendable {
        public var status: Int
        public var contentType: String
        public var body: Data
        public var extraHeaders: [String: String]

        public init(status: Int, contentType: String, body: Data, extraHeaders: [String: String] = [:]) {
            self.status = status
            self.contentType = contentType
            self.body = body
            self.extraHeaders = extraHeaders
        }

        public static func json(_ object: Any, status: Int = 200) -> Response {
            let data = (try? JSONSerialization.data(withJSONObject: tidy(object), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
            return Response(status: status, contentType: "application/json; charset=utf-8", body: data + Data("\n".utf8))
        }

        /// Doubles print with their shortest exact form (7.624292, not 7.6242919999999996).
        static func tidy(_ value: Any) -> Any {
            if type(of: value) == Double.self, let d = value as? Double, d.isFinite {
                return NSDecimalNumber(string: "\(d)")
            }
            if let dict = value as? [String: Any] { return dict.mapValues(tidy) }
            if let array = value as? [Any] { return array.map(tidy) }
            return value
        }

        public static func text(_ string: String, contentType: String = "text/markdown; charset=utf-8", status: Int = 200) -> Response {
            Response(status: status, contentType: contentType, body: Data(string.utf8))
        }

        public static func error(_ error: APIError) -> Response {
            var body: [String: Any] = ["code": error.code, "message": error.message]
            if let step = error.step { body["step"] = step }
            if let reason = error.reason { body["reason"] = reason }
            return .json(["error": body], status: error.status)
        }

        public var serialized: Data {
            var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
            head += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
            head += "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
            for (k, v) in extraHeaders.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
            return Data((head + "\r\n").utf8) + body
        }

        static func reason(_ status: Int) -> String {
            [200: "OK", 201: "Created", 400: "Bad Request", 402: "Payment Required", 403: "Forbidden",
             404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 413: "Payload Too Large",
             422: "Unprocessable Content", 500: "Internal Server Error", 503: "Service Unavailable", 507: "Insufficient Storage"][status] ?? "Status"
        }
    }

    public struct APIError: Error, Sendable, Equatable {
        public var status: Int
        public var code: String
        public var message: String
        public var step: Int?
        /// Why, for agents (e.g. "no_hum", "nothing_in_range").
        public var reason: String?

        public init(_ status: Int, _ code: String, _ message: String, step: Int? = nil, reason: String? = nil) {
            self.status = status
            self.code = code
            self.message = message
            self.step = step
            self.reason = reason
        }

        /// The request is fine but the document doesn't allow it (checked before any job starts).
        public static func unprocessable(_ reason: String, _ m: String) -> APIError { APIError(422, "unprocessable", m, reason: reason) }

        public static func badRequest(_ m: String) -> APIError { APIError(400, "bad_request", m) }
        public static func notFound(_ m: String) -> APIError { APIError(404, "not_found", m) }
        public static func forbidden(_ m: String) -> APIError { APIError(403, "forbidden", m) }
        public static func notAvailable(_ m: String) -> APIError { APIError(409, "not_available", m) }
        public static func paidNotAllowed(_ m: String) -> APIError { APIError(402, "paid_not_allowed", m) }
        public static func tooLarge(_ m: String) -> APIError { APIError(413, "too_large", m) }
        public static func insufficientStorage(_ m: String) -> APIError { APIError(507, "insufficient_storage", m) }
        public static func internalError(_ m: String) -> APIError { APIError(500, "internal", m) }
    }

    /// The security rules, checked before routing:
    /// - the Host must be this machine (stops DNS rebinding),
    /// - requests from web pages (an Origin header) are refused,
    /// - anything that changes state needs the agent header.
    public static func check(_ request: Request, port: UInt16) -> APIError? {
        let host = (request.headers["host"] ?? "").lowercased()
        let allowed = ["127.0.0.1", "localhost", "[::1]"].flatMap { ["\($0):\(port)", $0] }
        guard allowed.contains(host) else {
            return .forbidden("Host must be 127.0.0.1:\(port) or localhost:\(port).")
        }
        if request.headers["origin"] != nil {
            return .forbidden("Requests from web pages are not accepted. Call the API from a local process (curl, a script, an agent).")
        }
        if request.method != "GET", request.method != "HEAD", request.headers[agentHeader.lowercased()] != "1" {
            return .forbidden("Add the header \(agentHeader): 1 to every request that isn't a GET.")
        }
        return nil
    }

    /// A word as `GET …/transcript` gives it. A word nobody knows the time of (`Word.untimed`) has `start`
    /// and `end` null and `"untimed": true`: its place in the project is a spread, and a number here would
    /// be read as a time.
    public static func wordJSON(_ w: PlacedWord, seconds: (Frame) -> Double) -> [String: Any] {
        let untimed = w.word.untimed == true
        var d: [String: Any] = ["id": w.word.id.uuidString, "text": w.word.text, "partial": w.isPartial,
                                "start": untimed ? NSNull() : seconds(w.start) as Any, "end": untimed ? NSNull() : seconds(w.end) as Any]
        if untimed { d["untimed"] = true }
        d["confidence"] = w.word.confidence.map { ($0 * 100).rounded() / 100 } ?? NSNull()
        d["speaker"] = w.word.speaker ?? NSNull()
        return d
    }

    /// Parses `{"steps": [{"op", "params"}], "allowPaid": false}`, checking ops and params before anything runs.
    public static func parseSteps(_ body: Data) throws(APIError) -> (steps: [Step], allowPaid: Bool) {
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            throw .badRequest("The body isn't a JSON object. Send {\"steps\": [{\"op\": \"…\", \"params\": {…}}]}.")
        }
        guard let raw = obj["steps"] as? [Any], !raw.isEmpty else {
            throw .badRequest("Send {\"steps\": [{\"op\": \"…\", \"params\": {…}}]}. GET /api/v1/operations lists the ops.")
        }
        let allowPaid = obj["allowPaid"] as? Bool ?? false
        var steps: [Step] = []
        for (i, item) in raw.enumerated() {
            guard let dict = item as? [String: Any], let op = dict["op"] as? String else {
                throw .badRequest("Step \(i) needs an \"op\".")
            }
            guard let spec = Operations.named(op) else {
                throw APIError(404, "not_found", "Step \(i): unknown op \"\(op)\". GET /api/v1/operations lists them.", step: i)
            }
            // A step is its op and its params; anything else beside them would be something the caller
            // thinks was used.
            if let stray = (item as? [String: Any])?.keys.sorted().first(where: { !["op", "params", rationale].contains($0) }) {
                throw APIError(400, "bad_request", "Step \(i) has no field \"\(stray)\" (did you mean it inside \"params\"?). A step takes: op, params.", step: i)
            }
            var params: [String: JSONValue] = [:]
            if let p = dict["params"] {
                guard let pd = p as? [String: Any] else { throw APIError(400, "bad_request", "Step \(i): \"params\" must be an object.", step: i) }
                for (k, v) in pd where k != rationale {
                    guard let jv = JSONValue(v) else { throw APIError(400, "bad_request", "Step \(i): \"\(k)\" must be a number, string or boolean.", step: i) }
                    params[k] = jv
                }
            }
            let step = Step(op: op, params: params)
            do { try StepRunner.validate(step) } catch {
                throw APIError(400, "bad_request", "Step \(i): \(error.localizedDescription)", step: i)
            }
            if spec.paid, !allowPaid {
                throw APIError(402, "paid_not_allowed", "Step \(i) (\(op)) calls a paid service. Pass \"allowPaid\": true to allow it.", step: i)
            }
            steps.append(step)
        }
        return (steps, allowPaid)
    }

    // MARK: Operations

    /// GET /api/v1/operations, in the series' shape (SIBLINGS.md §3): params as JSON Schema.
    public static var operations: [[String: Any]] {
        (Operations.all + Operations.endpoints).map { op in
            var d: [String: Any] = ["name": op.name, "description": op.description, "params": op.schema,
                                    "paid": op.paid, "undoable": op.edits, "startsJob": op.startsJob, "tier": op.tier]
            if let call = op.call { d["call"] = ["method": call.method, "path": call.path] }
            return d
        }
    }

    // MARK: Guide

    /// What an agent fetches first: what Jammer is and exactly how to drive it.
    /// What a build can leave out (docs/RELEASE.md). The guide only describes what works.
    public struct Features: Sendable, Equatable {
        public var dereverb: Bool
        public var spectralFreeform: Bool
        /// CLAP plugins in helper processes.
        public var clap: Bool
        public init(dereverb: Bool, spectralFreeform: Bool, clap: Bool) {
            self.dereverb = dereverb
            self.spectralFreeform = spectralFreeform
            self.clap = clap
        }
        /// As this process has them.
        public static var current: Features { .init(dereverb: Restoration.dereverber != nil, spectralFreeform: Operations.spectralFreeform, clap: InsertUnits.external != nil) }
    }

    public static func guide(port: UInt16, appVersion: String, features: Features = .current) -> String {
        let base = "http://127.0.0.1:\(port)"
        let h = agentHeader
        // CLAP plugins can be left out of a build (and are, in releases, until they have been tried there).
        let pluginRows = features.clap ? "| GET | `/api/v1/plugins` | The effects installed on this Mac, optionally filtered by `?q=` and `?format=au|clap`: `{\"plugins\": [{\"id\", \"format\", \"name\", \"manufacturer\", \"kind\", \"version\", \"v3\"}], \"scan\": {\"state\": \"idle\"|\"running\", \"found\", \"failed\": [{\"name\", \"format\", \"reason\", \"kept\"}]}, \"safeMode\"}`. `format` is `au` (Audio Unit, id like `aufx/lmtr/appl`) or `clap` (id like `clap:com.vendor.plugin`). `scan` is about CLAP: plugins the last scan couldn't use have `reason` `crashed`, `timed_out`, `scan_failed` or `invalid`. `timed_out` and `scan_failed` say the scan got no answer, nothing about the plugin, and that bundle is tried again at every scan; `kept: true` means the plugin is still listed from an earlier scan that went well (one failed scan doesn't take a plugin away); and `blocked` means Jämmer switched the plugin off after it failed in use (only the user switches it on again). File paths are never shown. |\n| POST | `/api/v1/plugins/scan` | Looks for CLAP plugins again (a job). Body `{\"force\": true}` loads every bundle again; without it only new and changed ones. Each bundle is loaded in a helper process with a time limit, so a plugin that crashes or hangs is noted and the scan goes on. |" : "| GET | `/api/v1/plugins` | The Audio Unit effects installed on this Mac, optionally filtered by `?q=`: `{\"plugins\": [{\"id\", \"format\", \"name\", \"manufacturer\", \"kind\", \"version\", \"v3\"}], \"safeMode\"}`. |"
        let pluginSafety = features.clap ? "Plugins are third-party code. A CLAP plugin runs in a helper process of its own, never inside Jämmer: if it crashes or stops answering, its track plays without it (still in time), the plugin is switched off and the user is told; `add_insert` then fails with `plugin_blocked` until the user switches it on again. At most 64 such plugins run at once. An Audio Unit runs inside Jämmer unless safe mode is on (Audio › Plugins, or ask the user), which runs every Audio Unit in macOS's separate plugin host process. A CLAP plugin's parameters are identified by number (`\"parameter\": \"7\"`) or by name." : "Plugins are third-party code that runs inside Jämmer. If one crashes or misbehaves, the right fix is safe mode (Audio › Plugins, or ask the user): every Audio Unit then runs in macOS's separate plugin host process instead of inside Jämmer."
        // Reverb reduction can be left out of a build; the guide only describes what works.
        let dereverbKind = features.dereverb ? "\\|\"dereverb\"" : ""
        let dereverbText = features.dereverb ? " `dereverb` takes down the room's echo after each sound (the late reverberation, by linear prediction; no model) and leaves the direct sound; its `amount` defaults to 0.7, and it does little when `reverb.present` is false. It lowers the tail by 5 to 10 dB without shortening it, so judge a preview by ear or by level, not by `rt60` after." : ""
        var s = """
        # Jämmer: guide for agents

        Jämmer \(appVersion) is a native macOS audio editor (speech, restoration, post). This page tells an agent how to drive the running app through its local HTTP API. Everything here works today; nothing else does yet. Any agent the user runs themselves can use it (Claude Code, Codex, or another that can make HTTP requests on this Mac): Jämmer doesn't start agents and never sees an agent's login.

        - Base URL: `\(base)` (this Mac only; the server listens on loopback). Before you change anything, check that `app.name` in `GET /api/v1/status` is exactly `"Jammer"` (ASCII, no ä); `app.bundleID` is `com.brattoo.jammer`, or `com.brattoo.jammer.debug` for a development build. The window and splash say "Jämmer"; it's the same app. Glimmer and Flimmer run similar APIs on nearby ports.
        - Every request that isn't a GET needs the header **`\(h): 1`**. Without it you get `403 forbidden`.
        - Don't send an `Origin` header: requests that look like they come from a web page are refused.
        - Audio travels in request and response bodies. The API never reads or writes file paths.
        - Edits land in document windows the user can see, and can be undone. One `steps` request is one undo step. The source files are never changed.
        - Times are in **seconds** (decimals allowed). Jämmer rounds them to the nearest sample; replies give both seconds and frames.
        - Steps that cost money are refused unless you pass `"allowPaid": true`. Where Jämmer doesn't know the price it also wants `"allowUnknownPrice": true`, and answers 422 with reason `unknown_price` without it. The one thing that costs money today is transcribing with `engine` `openai`; everything else runs on the Mac.

        ## Quick start

        Run these in order. Replace `talk.wav` with any audio file (WAV, AIFF, MP3, AAC/M4A, FLAC, ALAC, CAF).

        ```sh
        BASE=\(base)

        # 1. Is Jämmer there? Check "app": {"name": "Jammer", …}.
        curl -s $BASE/api/v1/status

        # 2. Open the file as a new document. The reply contains its id.
        curl -s -X POST -H '\(h): 1' -H 'Content-Type: audio/wav' \\
             --data-binary @talk.wav "$BASE/api/v1/documents?name=Talk"
        # → {"document": {"id": "3F2A…", "duration": 754.2, …}}
        ID=3F2A…

        # 3. Measure it: loudness (LUFS), loudness range, true peak.
        curl -s $BASE/api/v1/documents/$ID/analysis

        # 4. Edit: cut the first 2.5 seconds, fade in, then bring it to -16 LUFS.
        curl -s -X POST -H '\(h): 1' -H 'Content-Type: application/json' \\
             -d '{"steps": [{"op": "delete", "params": {"start": 0, "end": 2.5}},
                            {"op": "fade_in", "params": {"start": 0, "end": 0.5}},
                            {"op": "normalize", "params": {"target": "loudness", "level": -16}}]}' \\
             $BASE/api/v1/documents/$ID/steps

        # 5. Export the result as a 24-bit WAV.
        curl -s -X POST -H '\(h): 1' -H 'Content-Type: application/json' \\
             -d '{"format": "wav", "bitDepth": 24}' $BASE/api/v1/documents/$ID/export -o talk-edited.wav
        ```

        Opening a document answers `201 Created`. To send the audio inside JSON instead: `-d '{"audio": "<base64 of the file>", "name": "Talk"}'`. Files over 256 MB go through uploads (below).

        ## Endpoints

        | Method | Path | What it does |
        |---|---|---|
        | GET | `\(guidePath)` | This guide (Markdown). |
        | GET | `/api/v1/status` | App name and version, API version, port, open documents. |
        | GET | `/api/v1/operations` | Everything this API can do, as JSON: every step operation with its parameters, and the calls that have an endpoint of their own (`restore`, `transcribe`, `export` and so on). The latter carry `"call": {"method", "path"}` and are not valid in `steps`. |
        | GET | `/api/v1/documents` | The open documents: `id`, `name`, `duration` (seconds), `frames`, `sampleRate`, `channels`, `playing`, `edited` (it has changes that aren't saved) and `frontmost` (the one the user has in front). |
        | POST | `/api/v1/documents` | Open audio: raw bytes (`Content-Type: audio/…` or `application/octet-stream`, optional `?name=`), JSON `{"audio": "<base64>", "name"}`, or JSON `{"upload": "<id>", "name"}`. Answers `201` with `{"document"}`, plus `"warning"` when the file was cut short and opened with the sound that was there. A file is untrusted: one that is damaged, has no sound in it, claims more than 32 channels or a sample rate outside 8–768 kHz, or would decode to more than the disk has room for, is refused with `400` and the reason in words. |
        | GET | `/api/v1/documents/{id}` | Duration, sample rate, channels, tracks and clips (each clip with its place on the timeline, its place in its source, `gainDB` and fades), `sources` (the audio files the clips play from), markers, tempo, selection, playhead. |
        | POST | `/api/v1/documents/{id}/steps` | Run steps in order. Body: `{"steps": [{"op": "…", "params": {…}}], "allowPaid": false}`. |
        | POST | `/api/v1/documents/{id}/undo` | Undo the last change (a whole `steps` request counts as one). Answers `{"undone": "<name of the change>", "document"}`. Undo doesn't check the result: after undoing a level change, run `analysis` again before exporting (a track back at 0 dB can push the mix over full scale). |
        | POST | `/api/v1/documents/{id}/redo` | Redo. Answers `{"redone": "<name of the change>", "document"}`. |
        | GET | `/api/v1/documents/{id}/analysis` | Loudness of the document, or of `?start=&end=` (seconds): integrated LUFS, range LU, max momentary and short-term, sample peak dBFS, true peak dBTP. `integratedLUFS` is `null` when the whole range is under −70 LUFS (the measurement's absolute gate), and `rangeLU` and `maxShortTermLUFS` are `null` for ranges shorter than about 3 s; `maxMomentaryLUFS` and the peaks are still there, which is how to measure the noise in a pause. `?tracks=id,id` (or `?track=id`) measures those tracks alone, as they sound (gain, fades, effects) without the others; a track you name is measured even if it is muted. The answer then lists `tracks`. |
        | GET | `/api/v1/documents/{id}/waveform` | Min/max per column for `?width=` columns (default 200, max 4000), optionally over `?start=&end=`. Lets you see where the sound is. |
        | POST | `/api/v1/documents/{id}/export` | The rendered audio as bytes. Body: `{"format": "wav"\\|"aiff"\\|"flac"\\|"alac"\\|"aac"\\|"opus"\\|"mp3", "bitDepth", "bitRate", "start", "end", "dither", "tracks"}`; all optional (24-bit WAV of everything by default). `"tracks": ["id", …]` exports those tracks alone, as they sound without the others (a track you name is exported even if it is muted); the file still covers the whole timeline from 0, so files exported track by track line up. bitDepth: wav 16, 24 or 32; aiff, flac, alac 16 or 24. `"sampleRate"` (8000, 11025, 16000, 22050, 32000, 44100, 48000, 88200, 96000, 176400 or 192000) converts the file to that rate when it isn't the document's; the document isn't changed, times stay, and the header `X-Jammer-Sample-Rate` says the rate written. Opus is always 48000. `"dither": true` adds TPDF dither to a 16- or 24-bit WAV, only on the samples that rounding would change, so audio that is already at that depth is not dithered again; the response header `X-Jammer-Dither` says what was done: `tpdf`, `none`, or `not_needed` (asked for, and every sample already sat on a step of that depth). bitRate: aac 64000–320000 (default 192000), opus 16000–256000 (default 96000; Ogg Opus, mono or stereo), mp3 64000–320000 in standard steps (default 160000). The formats this copy of Jämmer can write are listed in `GET /api/v1/operations` (export). `"chapters": true` (default) writes the markers as chapters: ID3 CHAP in mp3, a QuickTime chapter track in aac and alac (as Apple Podcasts reads them), CHAPTERxxx comments in opus; wav keeps markers as cue points; aiff and flac have none. Content-Type follows the format; only WAV carries Broadcast Wave metadata and markers. For mp3, aac and opus, `"targetLUFS": -16` delivers the file at that loudness: it is measured as written (an encoder shifts it a few tenths) and the gain before the encoder corrected, at most two more encodes, never past −1 dBTP. Without `targetLUFS` the target is the loudness preset the document was last brought to, if nothing changed since; `"compensate": false` encodes once. The response then carries `X-Jammer-Target-LUFS`, `X-Jammer-Loudness` (LUFS of the file as delivered), `X-Jammer-Compensated-DB`, `X-Jammer-True-Peak`, `X-Jammer-Limited-By-Peak` and `X-Jammer-Loudness-From` (`file`, or `mix` if the file couldn't be read back). Loudness and true peak are those of the delivered file, after the correction (an MP3 encoder lowers the level about 0.4 dB, so a correction of +0.44 dB with an unchanged true peak is normal). Up to 2 GB per response; export a range for more. |
        | POST | `/api/v1/documents/{id}/transcribe` | Starts transcribing the document (a job, see below). Body: `{"language": "sv-SE", "engine": "auto"}`; both optional (the Mac's language and the best engine for it). `engine`: `auto`, `apple`, `parakeet` (25 European languages), `whisper` (KB-Whisper, Swedish), or `openai` (the audio leaves the Mac and costs money: needs `"allowPaid": true` and, since Jämmer has no price for it, `"allowUnknownPrice": true`, the user's OpenAI key and `"model"`; text only, without word times; never chosen by `auto`; built from OpenAI's documentation, not tried with a real request). Models are installed by the user in Jämmer's Settings, never by the API; asking for one that isn't there answers 422 with reason `model_missing`. Every track is transcribed, and a recognizer finds "words" in music too: in a document with a music track, expect words on it that nobody said, and don't take a track with words to be speech. Answers `202` with the job. |
        | GET | `/api/v1/documents/{id}/transcript` | The transcript as it plays now: `{"words": [{"id", "text", "start", "end", "confidence", "speaker", "partial"}], "text", "speakers": [{"id", "name"}]}`, times in seconds on the timeline, optionally over `?start=&end=`. Empty until transcribed. |
        | GET | `/api/v1/documents/{id}/analysis/rhythm` | The tempo and beats of music, without changing anything; `?start=&end=` and `?tracks=id,id` as for the loudness (it looks at up to 120 s from the start of the range, which has to be at least 8 s). Answers `{"rhythm": {"bpm", "firstBeat", "beats": [seconds…], "pulse", "alternatives": [half, double], "start", "end", "analyzedSeconds"}}`. `pulse` is how strongly the sound itself repeats at that beat (0 to 1; a click track is near 1, a dense song around 0.3). Only music with one steady tempo has an answer: for speech, noise, silence, or music whose tempo changes, `bpm` is `null`, `beats` and `alternatives` are empty and `reason` is `no_steady_tempo`. A fast tempo can come back at half speed (174 as 87): `alternatives` always holds half and double, and the `detect_tempo` step takes `multiply` or the `bpm` you know. Where bars begin is not found. Tried on click and drum tracks at known tempi (within 0.1 BPM, first beat within 20 ms), one synthesised song, and speech, noise and silence (all refused). |
        | GET | `/api/v1/documents/{id}/mixer` | The mixer: `{"tracks": [{"id", "name", "gainDB", "pan", "muted", "output", "sends": [{"to", "gainDB", "pre"}]}], "buses": [{"id", "name", "gainDB", "pan", "muted", "output", "sends", "inserts", "inputs": {"tracks": [ids], "buses": [ids]}}], "master": {"gainDB", "inserts", "limiter", "latencySamples"}, "usesMixer", "panAvailable", "totalLatencySamples", "limits"}`. `vcas` lists the VCA groups (`add_vca`, `set_vca`, `remove_vca`): `{"id", "name", "gainDB", "muted", "members": {"tracks": [ids], "buses": [ids]}}`. No audio goes through a VCA; its level is added to each member's fader and its mute mutes them, so every track and bus also says `vca` (the group's id or null) and `heard` (`{"gainDB", "muted"}`: its own with the group's). The master is what everything goes through last: its plugins (`add_insert` with `track: "master"`; `GET …/master/inserts/{insert}`), its gain, and a true-peak limiter after all of it (`set_master`); `limiter` is null or `{"ceilingDB", "releaseMs", "lookaheadMs", "guarantee": "exports"}`: an export through it is measured as written and rendered again further under the ceiling until the file holds it (the answer's `X-Jammer-Master-Limiter` header says `ceiling`, the `truePeak` the file measured and the `margin` it took; if it can't be held the export fails with 422, reason `ceiling_not_met`, the measured peak in the message, and leaves no file), while playback has one pass, aims 0.1 dB under, and can go a little over. Every track and bus also has `latencySamples` (what its own plugins add) and `compensationSamples` (the delay the mixer adds to its way out so it meets the longest path on the sample); `totalLatencySamples` is the longest path, which playback and exports hide, so the mix is on time. Since 2026-11-16 every strip is worked out in one graph, so a track's own plugins count in these figures too: `totalLatencySamples` includes them, and a track's `compensationSamples` is the wait added to it for the others' sake. (Before, a track made up for its own plugins by itself and these figures spoke of buses only. The sound is the same, sample for sample.) `output` is a bus id, or `"master"` for the output. Change it with the steps `add_bus`, `set_bus`, `remove_bus`, `set_send` and `set_track` (`pan`, `output`). A send is a copy of a strip to a bus at its own level, after the fader and pan unless `pre`; a muted strip sends nothing; 16 sends per strip. `pan` is −1 (left) to 1 (right) and only for stereo documents; at 0 a strip is untouched, and a document that uses none of this plays exactly as it did before the mixer. A route that would send a bus back into itself fails with reason `routing_loop`; removing a bus that something is routed to fails with `in_use` unless `reroute` is given. |
        | GET | `/api/v1/documents/{id}/analysis/acx` | Measures the document against ACX's (Audible's) published audio submission requirements, as read on the date in `readOn`, without changing anything: `{"statement", "source", "articleDate", "readOn", "measuredOn": "mp3"\\|"mix", "failed": [names], "requirements": [{"name", "required" (ACX's words), "measured", "pass": true\\|false\\|null, "note"}]}`. Names: `rms` (−23 to −18 dB), `peak` (sample peak and true peak both no higher than −3), `noiseFloor` (no higher than −60 dB RMS), `format` (192 kbps or higher constant bit rate MP3 at 44.1 kHz), `channels`, `length` (120 minutes at most), `roomTone` (5 s at most at each end), `narration`. The document is encoded to that MP3 (converted to 44.1 kHz when it is at another rate) and measured as it decodes; if no MP3 could be made, `format` fails and the rest is measured on the mix. `pass: null` is something one file's measurement can't decide. It says what was measured, never that ACX approves. |
        | GET | `/api/v1/documents/{id}/analysis/restoration` | Looks for problems without changing anything: mains hum (frequency, how prominent), clipping (runs, samples, level), clicks (`count`: impulses of a few samples that stand out from the sound around them; a voice's own pulses and a note's attack aren't counted, and in dense music only clicks well over the music are found), the noise floor (`noiseFloor`: `dBFS`, the RMS level of the pauses, and `pauseSeconds`, how much pause it was measured over; null without pauses of 150 ms or more that are 10 dB under the loud parts) and reverberation (`reverb`: `rt60` in seconds, within about 0.1 s up to 1 s and reading short above that, or null when it can't tell (few pauses, or noise close under the voice); on sound that has been through `denoise` or `dehum` (also in their previews) it isn't measured at all, because what those repairs leave after each word reads as a room: `rt60` and `present` are then null and `unknown` is `"after_noise_reduction"`, so judge reverberation before those repairs; `present` when there is enough to reduce), over `?start=&end=` and `?tracks=id,id` (default: the selection, else everything; all tracks). Long ranges are sampled. |
        | POST | `/api/v1/documents/{id}/restore/preview` | The repaired audio of a stretch (at most 30 s), without changing the document. Same body as `restore`, with `start` and `end`. Answers a 24-bit WAV; with `Accept: application/json` it answers `{"before": {…}, "after": {…}}` instead: the detector numbers plus `integratedLUFS` and `truePeakDBTP`. This is not a job: the answer comes when the stretch has been processed, which can take about as long as the stretch plays, so preview a few seconds and allow a long timeout. |
        | POST | `/api/v1/documents/{id}/restore` | Repairs audio (a job). Body: `{"kind": "dehum"\\|"declip"\\|"declick"\\|"denoise"\(dereverbKind), "amount": 0–1, "start", "end", "tracks": [id], "humFrequency", "sensitivity"}`; only `kind` is required. The repaired clips play from new files; the originals are untouched and one undo step brings them back. |
        | POST | `/api/v1/documents/{id}/tracks` | Adds a track from audio sent like `POST /api/v1/documents` (bytes, base64 or upload; `?name=`). Audio at another sample rate than the document's is converted to it. It is placed at the start of the timeline at 0 dB unless you say otherwise: `?at=` is where it starts, in seconds, and `?gainDB=` the track's gain (−96 to 24), both part of the same undo step, so one undo takes the track away. Answers `201` with `{"track": {"id", "name", "gainDB", "at"}, "document"}` (and `"warning"` if the file was cut short). A level set afterwards with `set_track` is a separate undo step: undoing once then brings the track back to the gain it was added with, not away. To put music under speech, add it with a `gainDB` and run `duck` on it. For double-enders, add each speaker's recording and the call recording, then run `align_tracks`. |
        | GET | `/api/v1/documents/{id}/tracks/{trackId}/drift?against=<trackId>` | How far two recorders' clocks part: `{"drift": {"ppm", "msPerHour", "confidence"}}`. Needs at least 90 s of overlap. |
        | GET | `/api/v1/documents/{id}/tracks` | The tracks with their ids, clips and plugins (`inserts`). |
        | GET | `/api/v1/documents/{id}/tracks/{trackId}/inserts/{insert}` | One plugin: `{"insert": {"id", "plugin", "name", "bypass", "latencyMs", "factoryPresets", "params": [{"identifier", "name", "unit", "min", "max", "value"}]}}`. |
        | POST | `/api/v1/documents/{id}/separate` | Splits tracks into stems (a job). Body: `{"model": "music4"\\|"dialog", "tracks": [id]}`; both optional. Result: `{"stems": [names], "tracks": [ids]}`. |
        | GET | `/api/v1/documents/{id}/history` | The history tree: `{"current", "pruned", "limit", "nodes": [{"id", "parent", "action", "time", "branch"}]}`. A change made after an undo starts a branch; the old future stays reachable. |
        | POST | `/api/v1/documents/{id}/history/{node}` | Goes to that step (any branch). One undo step; `undo` goes back. |
        | POST | `/api/v1/import/fcpxml` | Opens the sound of a film timeline as a new document. Body: `{"path": "/…/film.fcpxml"}`; the file and the media it uses must lie in a folder the user allows (Settings › Agents), else 422 `folder_not_allowed`. Answers `201` with `{"document", "import": {"tracks", "clips", "sources", "shots": [{"name", "start", "duration"}], "flimmer": {"exportVersion"} or null, "warnings": [{"code", "message", "clip"}]}}`. One track per lane (lane −1 first), with each clip's position, trim, level, linear fades and mute; a video clip's own sound lands on a track called Video; the pictures become shot markers (`kind: "shot"` in the document), which are never chapters and are written as cue points labeled `Shot: <name>` in a WAV export. Tried with Flimmer's exports and hand-written FCPXML, not yet with files written by Final Cut Pro or DaVinci Resolve. Flimmer's exports carry exact times and separate clip and track levels, which are used; other programs' files are read from the FCPXML fields. Warnings to expect: `resampled` (a file at another sample rate than the timeline plays from a converted copy), `missing_media`, `unreadable_media`, `disabled_clip` (a clip switched off in a lane that is otherwise on is left out), `overlap`. |
        | POST | `/api/v1/batch` | Processes files by path (a job). Body: `{"files": [paths] or "folder": path, "steps": […], "jobs": [{"op", "params"}], "export": {"format", "bitDepth", "bitRate", "chapters", "targetLUFS", "compensate", "sampleRate"}, "output": path, "suffix", "overwrite"}`. Result: `{"done", "outputs", "loudness", "loudnessFrom", "compensatedDB", "limitedByPeak", "skipped", "failed", "warnings"}` (`warnings`: files that were cut off and went in with the sound that was there), the middle four lining up with `outputs`. `loudness` is the LUFS of the file as written, read back after encoding (`loudnessFrom` is `file`; `mix` if the file couldn't be read back). An mp3, aac or opus encoder changes the loudness a little, so when there is a target (`export.targetLUFS`, or a `loudness_preset` as the last step) the file is measured, the gain before the encoder corrected and the file encoded again, at most twice and never past the true-peak ceiling; `compensatedDB` is what was added. `"compensate": false` turns that off. `limitedByPeak`: the target wasn't reached because of the peaks (the step ran without `"limit": true`; with it the limiter holds the peaks and the target is reached). |
        \(pluginRows)
        | POST | `/api/v1/documents/{id}/diarize` | Finds who speaks when (a job). Body: `{"mode": "by_track"\\|"ml", "tracks": [id], "speakers", "minSpeakers", "maxSpeakers"}`; all optional. The result has `speakers` (names) and `seconds` (each one's speaking time) in order of id. |
        | GET | `/api/v1/documents/{id}/speakers` | `{"speakers": [{"id", "name", "seconds"}], "turns": [{"speaker", "track", "start", "end"}]}`, as it plays now, optionally over `?start=&end=`. |
        | GET | `/api/v1/documents/{id}/chapters` | The markers as Podcasting 2.0 chapters: `{"version": "1.2.0", "chapters": [{"startTime", "endTime", "title"}]}` (Content-Type `application/json+chapters`), optionally over `?start=&end=`. |
        | GET | `/api/v1/jobs/{id}` | A job's state. |
        | DELETE | `/api/v1/jobs/{id}` | Cancels a job. |
        | POST | `/api/v1/documents/{id}/play` | Starts playback in the document's window, from `{"at": seconds}` or the playhead. Only works when the window is visible. |
        | GET | `/api/v1/storage` | What takes room in Jämmer's media folder: `{"storage": {"canBeFreed", "inUse", "unknown", "notJammers": each {"bytes", "files": [{"name", "bytes", "kind", "created", "projects"}]}, "inTrash", "register", "note"}}`. `canBeFreed`: files Jämmer made (effects, repairs, frozen strips) that no project that has used them uses any more, now or anywhere in its history. `unknown`: made by Jämmer and last used by a project that can't be read just now. `notJammers`: the user's own audio and anything Jämmer has no record of having made; never touched. Reading only: there is no call that removes anything. The user chooses in File › Storage…, and what is chosen goes to the Trash. |
        | POST | `/api/v1/documents/{id}/freeze` | `{"strip": track or bus id}`. Renders the strip through its plugins into a file and plays it from that, with the plugins idle (a job; one undo step). Its level, pan, mute, sends and route stay live. Until it is unfrozen, a step that would change what it was frozen from fails with 422 `step_failed`, `reason: "frozen"`. `GET …/mixer` says `frozen: {"start", "seconds"}` on the strip. Refused: `already_frozen`, `nothing_to_freeze`. |
        | POST | `/api/v1/documents/{id}/unfreeze` | `{"strip": id}`. The strip is worked out live again, from exactly what it was (one undo step). Answers the mixer. Refused: `not_frozen`. |
        | GET | `/api/v1/documents/{id}/automation?strip=&at=` | The level of a strip at a time (`strip`: a track or bus id, or `master`; `at`: seconds): with `param` (gain by default, or pan, mute, send with `to`, or plugin with `insert` and `parameter`) `value` is that lane's there (dB, −1 to 1, or 1 for muted; null without one), `faderDB` the fader with its VCA group, `levelDB` that and the gain lane together, `muted` whether anything silences the strip then. For checking what `set_automation` wrote without rendering. The lanes themselves are in `GET …/mixer`, under `automation` on each strip. (`set_automation` writes them, in builds that have automation.) |\(Operations.dialogueLoudness ? "\n| GET | `/api/v1/documents/{id}/analysis/dialogue` | Dialogue-gated loudness (this build only; not yet set beside a reference meter): `dialogueLKFS`, the loudness over the parts that are speech (BS.1770 K-weighting, every 100 ms of speech above −70 LKFS, no relative gate; null without speech); `speechShare` (0 to 1) and `speechSeconds`; `speechFrom`, where the speech was taken from (`speakers`: who speaks when; `words`: a transcript; `none`: the document has neither, so find the speakers or transcribe first); `program`, the same range measured the ordinary way. With `start` and `end` for a range. With `profile` (\(DialogueProfile.allCases.map(\.rawValue).joined(separator: ", "))): `profile` in the answer sets the numbers beside a delivery target's (which measurement it goes by, the target, how far from it, the true peak and its ceiling, where the target was read and when), without a verdict. It is Jämmer's own measurement, not Dolby's Dialogue Intelligence. |" : "")
        | POST | `/api/v1/documents/{id}/solo` | `{"strips": [track and bus ids]}`; `[]` ends it. Solo is a way of listening, not an edit: only the soloed tracks, and the tracks that reach a soloed bus by output or send, are heard in playback. It is not a step, not undone and not saved, and exports, measurements and bounces are not changed by it. Answers `{"solo": {"strips", "heardTracks", "affects": "listening", "note"}}`, which `GET …/mixer` has too. |
        | POST | `/api/v1/documents/{id}/stop` | Stops playback. Answers `underruns`: the times since playback started that the sound card asked for audio and not enough was rendered, each a gap that was heard. A document's summary (`GET /api/v1/status`, `GET /api/v1/documents`) has the same count while it plays. 0 is what it should be. |
        | POST | `/api/v1/uploads` | Starts an upload for a big file. Answers `{"upload": {"id": "…", "size": 0}}`. |
        | PUT | `/api/v1/uploads/{id}?offset=N` | Appends a chunk (≤ 256 MB). `offset` must equal the bytes received so far. |
        | GET | `/api/v1/uploads/{id}` | How many bytes have arrived. |
        | DELETE | `/api/v1/uploads/{id}` | Throws an upload away. |

        Document ids are stable while the window is open. A document a sibling app handed over to edit (SIBLINGS.md §6) has `"linkedFile": {"name", "format", "requester", "available"}` in the document list (with `"unreturnedSteps"`, how many steps have not been saved back, while there are any; and, when Jämmer brought it back at start with such changes, `"kept": true` if it had been kept on purpose (Jämmer was quit, or the window closed with Keep for Later) or `"recovered": true` if Jämmer had stopped unexpectedly, never both, until the changes are saved back or given up; `GET /api/v1/status` has `"linkJournal": {"entries", "broken"}`, how many linked documents Jämmer keeps a record of and how many records it couldn't read); the user saves it back with ⌘S, and the API never writes that file. `available` is `false`, with `reason` in words, when the file can no longer be reached or written (it was removed, made read-only, or replaced by another kind of file); the document is then still open with the edit in it. It follows the file while the document is open (looked at once a second and at every listing), so it turns false when the sibling removes its file and true again when the file is back. The same file handed over again brings the open document forward instead of opening another. `GET /api/v1/documents` also lists documents the user opened.

        ### Big files

        ```sh
        UP=$(curl -s -X POST -H '\(h): 1' $BASE/api/v1/uploads | sed -E 's/.*"id" *: *"([^"]+)".*/\\1/')
        split -b 100m long.wav part.
        OFF=0; for p in part.*; do
          curl -s -X PUT -H '\(h): 1' --data-binary @$p "$BASE/api/v1/uploads/$UP?offset=$OFF" >/dev/null
          OFF=$((OFF + $(stat -f%z $p)))
        done
        curl -s -X POST -H '\(h): 1' -H 'Content-Type: application/json' -d "{\\"upload\\": \\"$UP\\"}" $BASE/api/v1/documents
        ```

        Uploads are deleted once they're opened, after an hour without new chunks, or when Jämmer quits. Jämmer checks free disk space before taking a chunk and answers `507 insufficient_storage` instead of filling the disk.

        ### Steps

        A steps request runs every step in order and stops at the first failure. Then nothing from the request is applied: steps that had run are reported as `reverted`, later ones as `skipped`. The reply lists each step:

        ```json
        {"results": [{"index": 0, "op": "delete", "status": "done"},
                     {"index": 1, "op": "normalize", "status": "done", "info": {"gainDB": 3.4, "before": -19.4}}],
         "document": {…}}
        ```

        Ranges: most operations take `start` and `end` in seconds. Without them they act on the selection (`select`, `select_all`); `gain` and `normalize` act on everything when there's no range and no selection. Edits work on all tracks at once, like a waveform editor.

        ## Errors

        A name Jämmer doesn't know is refused, never skipped: a parameter of a step, a field beside `op` and `params`, a field in a JSON body, a query parameter. The answer is 400 `bad_request` with the name and what the call does take, and nothing is done (in `/steps`, no step runs). So a 2xx answer means every value you sent was used. The schemas in `/api/v1/operations` are closed (`"additionalProperties": false`). One name is accepted everywhere and used for nothing: `rationale`, a string saying why you make the call.

        Errors are JSON: `{"error": {"code": "…", "message": "…"}}`. A failed step also gives its index: `{"error": {"code": "step_failed", "message": "…", "step": 1}}`.

        | Status | Code | Meaning |
        |---|---|---|
        | 400 | `bad_request` | The body or a parameter is malformed. The message says which (and `step` which step). |
        | 402 | `paid_not_allowed` | A step costs money and `allowPaid` wasn't `true`. |
        | 422 | `unprocessable`, reason `unknown_price` | It costs money, Jämmer doesn't know how much, and `allowUnknownPrice` wasn't `true` beside `allowPaid`. Allowing a paid request is not allowing any price. |
        | 403 | `forbidden` | Missing `\(h): 1`, an `Origin` header, or a Host other than this Mac. |
        | 404 | `not_found` | No such document, upload, path or operation. |
        | 405 | `method_not_allowed` | Wrong HTTP method for the path. |
        | 409 | `not_available` | Not possible right now: nothing to undo, the window isn't visible for playback, the upload offset is wrong. |
        | 413 | `too_large` | A body over 256 MB (use uploads), an upload over 16 GB, or an export over 2 GB (export a range). |
        | 507 | `insufficient_storage` | Not enough free disk space for the upload or export. |
        | 422 | `step_failed` | A step ran and failed. `error.step` is its index; `results` has the status of every step. Some failures add `error.reason` (`ambiguous`, `not_found`) and numbers such as `error.matches`. |
        | 422 | `unprocessable` | The request is fine, but the document doesn't allow it; `error.reason` says why (`no_hum`, `nothing_in_range`). Nothing started. |
        | 500 | `internal` | Jämmer failed unexpectedly. The message has the detail. |

        ## Jobs

        Transcription, repairs (`restore`), finding speakers, stem separation, batch and scanning run as jobs. The request that starts it answers `202` with `{"job": {"id", "kind", "status", "progress"}}`. `status` is `queued`, `running`, `done`, `failed` or `canceled`; `progress` goes from 0 to 1. Poll `GET /api/v1/jobs/{id}` every second or two. When it's `done`, `result` has a summary and the document has changed (one undo step); a failed job has `error: {code, message}`. `DELETE /api/v1/jobs/{id}` cancels. Running jobs are also listed under `jobs` in `GET /api/v1/status`. The user can keep editing while a job runs; words are anchored to the audio itself, so they land right regardless.

        ## Transcripts

        A transcript is a view of the edit: it always reads what plays now. Each word has an `id` that stays the same across edits, undo, redo and saving, so you can keep ids between requests. Delete words with `delete_words` and `{"words": ["<id>", …]}`. You can pass `{"text": "…"}` instead, but it must match in exactly one place; otherwise the step fails with `reason: "ambiguous"` and `matches`, and you pick one with `occurrence` or all with `"all": true`. `correct_word` changes the spelling only. Things to know when you read a transcript: words follow each other without gaps, so a pause is inside one of the words beside it, usually the word after the pause ("mattor" at 13.32–14.52 can start with 0.8 s of silence). Deleting a sentence therefore usually takes the pause before it and leaves the one after it; look at `waveform` over the words when the exact cut matters. `confidence: null` means the recognizer gave that word no proper time (the Mac's own recognizer does this for the last sentence of a recording): its `start` and `end` are rough and can be seconds off the sound, so check them against `waveform` before cutting there, or transcribe with `whisper` or `parakeet` when they're installed; sentence punctuation comes from the recognizer and is often missing, so pick the words of a sentence by reading them, not by splitting on full stops; `languages` lists the language of each transcribed source. The job's `result.engine` is the full name of the engine that ran (for example `apple-dictation`), which is more specific than the `engine` value you asked for.

        ## Restoration

        Look, listen, then repair. `GET …/analysis/restoration` tells you whether there is hum, clipping, clicks or reverberation. `POST …/restore/preview` with `Accept: application/json` gives the numbers before and after for a short stretch, so you can check that a repair helps (and that `amount` isn't too much) without listening. `POST …/restore` then runs it as a job. `dehum` finds 50 or 60 Hz by itself; pass `humFrequency` if it says `no_hum` and you know better. `denoise` reduces steady background noise (hiss, fans, room tone) with DeepFilterNet 3, on this Mac; its `amount` defaults to 1. It isn't meant for mains hum: when the analysis reports `hum`, run `dehum` as well. To show what a repair did to the noise (this goes for `dehum` too), compare `noiseFloor` in the analysis or the preview before and after: the level in the pauses, in dBFS. It is null when there are no pauses to measure in, and after a repair that leaves digital silence between the words. A hum that is louder than the rest of the noise is part of the floor before `dehum`. When both are needed, run `dehum` first and `denoise` after it. Hum and noise count in the loudness, so a repaired recording measures lower than before (1.2 LU lower in a noisy test take): set the loudness after repairing, not before.\(dereverbText) `amount` blends between the original (0) and the full repair (1). Use `tracks` to repair one speaker in a multitrack recording.

        ## Speakers

        `POST …/diarize` labels the document with speakers as a job. For a double-ender (several tracks playing at once, one person per track) the default is `"mode": "by_track"`: each track is its speaker, named after the track, and bleed from the other tracks doesn't count. Otherwise it's `"ml"`, a diarisation model run on each track; tell it `speakers` when you know how many, especially for similar voices and short back-and-forth, where it's much weaker (docs/DIARISATION.md has the numbers). If `ml` finds only one speaker, the job's result has a `hint`: when the recording is a conversation, run it again with `speakers`, since the model often merges voices that sound alike. The first `ml` run downloads the model (about 20 MB); if that fails the job fails with `error.code` `model_unavailable`. Afterwards `GET …/speakers` lists who talks when, `GET …/transcript` gives each word a `speaker` id and lists `speakers`, and `rename_speaker` names them ("0" → "Anna"). Turns are anchored in the audio, so they stay right through edits.

        ## Batch

        Everything else in this API works on documents the user has open; `POST /api/v1/batch` is the one call that reads and writes files by path. So it only works inside folders the user has allowed under Jämmer › Settings… › Agents ("Folders agents may use"; the list starts empty, and `agentFolders` in `GET /api/v1/status` is how many there are). A path outside them, also through a symlink or `..`, answers 422 with reason `folder_not_allowed`: ask the user to add the folder. Each file is processed without a window: `steps` as in `…/steps`, then `jobs` (`restore`, `transcribe`, `diarize`, `separate`, with the same parameters as their endpoints), then exported into `output` as “name (Jämmer).mp3” (or your `suffix` and format). The input files are never changed, not even with `overwrite` (reason `would_overwrite_source`); a result that already exists is skipped unless `overwrite` is true; a file that fails is listed under `failed` and the rest carry on.

        ## Stems

        `POST …/separate` (a job) splits each track into vocals, drums, bass and other with Spleeter's 4-stem model, on this Mac. The stems replace the track as four tracks in one group (`group` in `GET …/tracks`) and add up to exactly what the track was, so the mix is unchanged until you change a stem: `set_track` mutes or turns one, `set_group` moves them all together. The model works up to 11 kHz; everything above it, and whatever the model leaves, goes to `other`, so nothing is lost. `"model": "dialog"` splits film or video sound into speech, music and effects instead (MERL's MRX; slower, and what it leaves is shared between music and effects). The user installs the models (146 MB and 122 MB, both MIT, from their publishers) in Settings › Models.

        ## Plugins

        \(features.clap ? "A track can run through effects before its gain: Audio Units (AUv2 and AUv3) and CLAP plugins." : "A track can run through Audio Unit effects (AUv2 and AUv3) before its gain.") `GET /api/v1/plugins` lists what's installed; `add_insert` puts one on a track (by id like `aufx/lmtr/appl` or by its exact name) and answers its id in `info.insert`; give a bus's id as `track` and the plugin goes on the bus, after its sum and before its level (`GET …/buses/{busId}/inserts/{insert}` for its parameters), and the same for `set_insert` and `remove_insert`; `GET …/tracks/{trackId}/inserts/{insert}` lists its parameters with their ranges; `set_insert` changes one parameter, a factory preset or bypass; `remove_insert` takes it off. A value outside a parameter's range fails with `reason: "out_of_range"`; nothing is clipped. Every change is one undo step, settings are saved in the document, and each plugin's latency is compensated so the tracks stay in time. Exports and loudness measurements (including `normalize` and `loudness_preset`) hear the plugins. You can't open a plugin's window; the user can, under Audio › Plugins.

        \(pluginSafety) Errors: `plugin_not_found`, `plugin_unsupported_format` (it can't take the document's mono or stereo float audio), `plugin_failed` (it didn't start).

        ## Sibling apps

        Glimmer and Flimmer call Jämmer the same way you do (see their own guides). They add `X-Sibling: <slug>`; Jämmer logs it and shows "Requested by …" in the window, and it gives no extra rights. `GET /api/v1/operations` lists every op with `params` as a JSON Schema, plus `paid`, `undoable` and `startsJob`, so an assistant can turn them into tools named `jammer.<op>`. `tier` is `"core"` for the 15 most useful ones and `"advanced"` for the rest: start from core when tools are scarce.

        ## Operations

        These are the `op` values for `steps`, with their `params`. `GET /api/v1/operations` has the same list as JSON, followed by the calls that have their own endpoint (those have a `call` field and can't be used as steps).

        """
        for op in Operations.withKeys(Operations.all(freeform: features.spectralFreeform, clap: features.clap)) {
            s += "\n### `\(op.name)`\(op.paid ? " (paid)" : "")\n\n\(op.description)\n"
            if op.params.isEmpty {
                s += "\nNo params: `{\"op\": \"\(op.name)\"}`\n"
                continue
            }
            s += "\n| Param | Type | Description |\n|---|---|---|\n"
            for p in op.params {
                var d = p.description.replacingOccurrences(of: "|", with: "\\|")
                if p.required { d = "**Required.** " + d }
                if let o = p.options { d += " One of: `" + o.joined(separator: "`, `") + "`." }
                s += "| `\(p.name)` | \(p.kind.rawValue) | \(d) |\n"
            }
        }
        s += """

        ## Good to know

        - Nothing is destructive: clips play from the original files, so you can always undo. `GET /api/v1/documents/{id}` shows the clips.
        - Measure before and after: `analysis` gives the numbers, `waveform` shows the shape.
        - An export is at the document's own sample rate and channel count (`sampleRate`, `channels`) unless you pass `sampleRate` to `export`; then the file is converted and the document stays as it is.
        - To put one document's audio into another, export it as WAV and send the bytes to the other document's `…/tracks`. The clipboard steps (`copy`, `paste`) work inside one document.
        - `analysis` and `export` cover the whole mix; there is no way yet to measure or export one track alone. To check a track you added, read its clip (`start`, `end`, `gainDB`) in `GET …/documents/{id}`, or compare a stretch of the mix where the other tracks are silent.
        - `undo`, `redo` and `steps` answer with the document as it is afterwards, so there's no need to fetch it again. A range that reaches past the end of the document is clamped; the answer says what was used.
        - Several changes are one undo step only when they go in one `steps` request. Calls with their own endpoint (adding a track, a repair, a transcription) are each a step of their own, so "undo the last change" undoes the last request, not the last task.
        - Common targets: podcasts −16 LUFS (Apple) with true peak at most −1 dBTP; EBU broadcast −23 LUFS.
        - The user may be editing the same document. Read it before you act on it, and keep requests small.
        - `tempo.changes` in the document lists each tempo change with `at` (seconds), `bpm` and `meter` (e.g. `"3/4"`); the first is at 0. The API speaks seconds only: to work in bars and beats, compute them yourself from `tempo.changes`. A beat lasts 60 / `bpm` × 4 / unit seconds, and a new time signature starts a new bar.
        - Playback is for the user to hear what you did. Don't start it unless they asked; recording can only be started by the user.

        """
        return s
    }
}
