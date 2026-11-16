import AppKit
import JammerAgent
import JammerCore
import JammerResample
import JammerPlugins
import JammerStems
import Network
import OSLog

// MARK: Open documents

/// The editor sessions the API can address, by a stable id per window.
@MainActor
final class AgentRegistry {
    static let shared = AgentRegistry()
    private struct Entry { weak var session: EditorSession? }
    private var entries: [Entry] = []

    func register(_ session: EditorSession) {
        entries.removeAll { $0.session == nil || $0.session === session }
        entries.append(Entry(session: session))
    }

    func unregister(_ session: EditorSession) {
        entries.removeAll { $0.session == nil || $0.session === session }
    }

    var sessions: [EditorSession] {
        entries.removeAll { $0.session == nil }
        return entries.compactMap(\.session)
    }

    func session(_ id: String) -> EditorSession? {
        sessions.first { $0.agentID.caseInsensitiveCompare(id) == .orderedSame }
    }
}

// MARK: Uploads

/// Big files arrive in chunks. Kept in a temporary folder; removed when opened,
/// after an hour without chunks, and when the app quits.
@MainActor
final class UploadStore {
    static let shared = UploadStore()

    struct Upload {
        let id: String
        let url: URL
        var size: Int64
        var touched: Date
    }

    private var uploads: [String: Upload] = [:]
    private var sweeper: Timer?
    let folder = FileManager.default.temporaryDirectory.appending(path: "jammer-uploads")

    func start() {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        sweeper = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            MainActor.assumeIsolated { UploadStore.shared.sweep() }
        }
    }

    func create() -> Upload {
        let id = UUID().uuidString.lowercased()
        let url = folder.appending(path: id)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let u = Upload(id: id, url: url, size: 0, touched: Date())
        uploads[id] = u
        return u
    }

    func get(_ id: String) -> Upload? { uploads[id.lowercased()] }

    func append(_ id: String, offset: Int64, data: Data) throws(AgentAPI.APIError) -> Upload {
        guard var u = uploads[id.lowercased()] else { throw .notFound("No upload with id \(id). They expire after an hour without chunks.") }
        guard offset == u.size else { throw .notAvailable("offset must be \(u.size) (the bytes received so far), not \(offset).") }
        guard u.size + Int64(data.count) <= AgentAPI.maxUpload else { throw .tooLarge("Uploads can be at most 16 GB.") }
        try Self.checkSpace(for: Int64(data.count), at: folder)
        do {
            let h = try FileHandle(forWritingTo: u.url)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: data)
        } catch {
            throw .internalError("Couldn't store the chunk: \(error.localizedDescription)")
        }
        u.size += Int64(data.count)
        u.touched = Date()
        uploads[u.id] = u
        return u
    }

    func remove(_ id: String) {
        if let u = uploads.removeValue(forKey: id.lowercased()) { try? FileManager.default.removeItem(at: u.url) }
    }

    func sweep() {
        let limit = Date().addingTimeInterval(-AgentAPI.uploadIdleLimit)
        for (id, u) in uploads where u.touched < limit { remove(id) }
    }

    func removeAll() {
        uploads.removeAll()
        try? FileManager.default.removeItem(at: folder)
    }

    /// Refuses work that would leave less than `AgentAPI.diskReserve` free.
    static func checkSpace(for bytes: Int64, at url: URL) throws(AgentAPI.APIError) {
        let free = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? .max
        if free - bytes < AgentAPI.diskReserve {
            let gb = Double(max(0, free)) / 1_073_741_824
            throw .insufficientStorage(String(format: "Only %.1f GB free on the disk; Jämmer keeps 2 GB spare. Free some space or send less.", gb))
        }
    }
}

// MARK: Server

/// The local HTTP server for agents: the guide at `/jammer` and the API under
/// `/api/v1`. Loopback only, on 9003 or the first free port in 9301–9319.
@MainActor
@Observable
final class AgentServer {
    static let shared = AgentServer()

    private(set) var port: UInt16?
    private(set) var failure: String?
    @ObservationIgnored private var listener: NWListener?
    nonisolated static let queue = DispatchQueue(label: "jammer.agent-server")

    var guideURL: String? { port.map { "http://127.0.0.1:\($0)\(AgentAPI.guidePath)" } }
    var agentPrompt: String? { port.map(AgentAPI.agentPrompt) }

    func start() {
        guard listener == nil else { return }
        UploadStore.shared.start()
        Task {
            for candidate in AgentAPI.ports {
                if let l = await Self.listen(on: candidate) {
                    listener = l
                    port = candidate
                    return
                }
            }
            failure = "Ports 9003 and 9301–9319 are all in use, so agents can't reach Jämmer."
        }
    }

    nonisolated private static func listen(on port: UInt16) async -> NWListener? {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = false
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        guard let listener = try? NWListener(using: params) else { return nil }
        listener.newConnectionHandler = { connection in Self.handle(connection, port: port) }
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<NWListener?, Never>) in
            listener.stateUpdateHandler = { state in
                guard !once.done else { return }
                switch state {
                case .ready:
                    once.done = true
                    continuation.resume(returning: listener)
                case .failed, .cancelled:
                    once.done = true
                    listener.cancel()
                    continuation.resume(returning: nil)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    nonisolated private static func handle(_ connection: NWConnection, port: UInt16) {
        connection.start(queue: queue)
        receive(connection, buffer: Data(), port: port)
    }

    nonisolated private static func receive(_ connection: NWConnection, buffer: Data, port: UInt16) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8 << 20) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            switch AgentAPI.parse(buffer) {
            case .incomplete:
                if isComplete || error != nil { connection.cancel() } else { receive(connection, buffer: buffer, port: port) }
            case .invalid(let message):
                let tooLarge = message.contains("too large")
                send(.error(AgentAPI.APIError(tooLarge ? 413 : 400, tooLarge ? "too_large" : "bad_request", message)), on: connection)
            case .request(let request):
                if let refusal = AgentAPI.check(request, port: port) {
                    send(.error(refusal), on: connection)
                    return
                }
                Task { @MainActor in
                    let response = await AgentRouter.route(request, port: port)
                    send(response, on: connection)
                }
            }
        }
    }

    nonisolated private static func send(_ response: AgentAPI.Response, on connection: NWConnection) {
        connection.send(content: response.serialized, completion: .contentProcessed { _ in connection.cancel() })
    }
}

// MARK: Routes

@MainActor
enum AgentRouter {
    typealias Response = AgentAPI.Response
    typealias APIError = AgentAPI.APIError

    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }

    static func route(_ r: AgentAPI.Request, port: UInt16) async -> Response {
        do {
            return try await dispatch(r, port: port)
        } catch let error as APIError {
            return .error(error)
        } catch {
            return .error(.internalError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
        }
    }

    static let siblingLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.brattoo.jammer", category: "siblings")
    static let siblingNames = ["glimmer": "Glimmer", "flimmer": "Flimmer", "jammer": "Jämmer"]

    private static func dispatch(_ r: AgentAPI.Request, port: UInt16) async throws -> Response {
        let s = r.segments
        // A sibling app (SIBLINGS.md): logged and shown, never given extra rights.
        if let sib = r.headers["x-sibling"]?.lowercased() {
            siblingLog.notice("\(r.method, privacy: .public) \(r.path, privacy: .public) requested by \(sib, privacy: .public)")
            if s.count >= 4, s[2] == "documents", let session = AgentRegistry.shared.session(s[3]), r.method != "GET" {
                session.status = "Requested by \(siblingNames[sib] ?? sib)"
            }
        }
        func only(_ methods: String...) throws {
            guard methods.contains(r.method) else {
                throw APIError(405, "method_not_allowed", "\(r.method) isn't allowed here; use \(methods.joined(separator: " or ")).")
            }
        }
        switch s {
        case [], ["api"], ["api", "v1"]:
            try only("GET")
            return .json(["guide": "http://127.0.0.1:\(port)\(AgentAPI.guidePath)", "api": "http://127.0.0.1:\(port)/api/v1"])
        case ["jammer"], ["jammer.md"]:
            try only("GET")
            return .text(AgentAPI.guide(port: port, appVersion: appVersion))
        case ["api", "v1", "status"]:
            try only("GET")
            return .json(["app": AgentAPI.appInfo(version: appVersion, bundleID: Bundle.main.bundleIdentifier),
                          "api": AgentAPI.version, "port": Int(port), "agentFolders": AgentFolders.urls.count,
                          "documents": AgentRegistry.shared.sessions.map(summary),
                          "jobs": JobRegistry.shared.running.map(\.json)])
        case let p where p.count == 4 && Array(p.prefix(3)) == ["api", "v1", "jobs"]:
            try only("GET", "DELETE")
            let job = r.method == "GET" ? JobRegistry.shared.job(p[3]) : JobRegistry.shared.cancel(p[3])
            guard let job else { throw APIError.notFound("No job with id \(p[3]).") }
            return .json(["job": job.json])
        case ["api", "v1", "batch"]:
            try only("POST")
            guard let body = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] else { throw APIError.badRequest("The body isn't a JSON object.") }
            do {
                // Paths from an agent must lie in a folder the user allowed in Settings › Agents.
                let request = try BatchRequest.parse(body, policy: AgentFolders.policy)
                return .json(["job": JobRegistry.shared.startBatch(request).json, "files": request.inputs.count], status: 202)
            } catch let e as BatchError {
                if e.reason == "bad_request" { throw APIError.badRequest(e.message) }
                throw APIError.unprocessable(e.reason, e.message)
            }
        case ["api", "v1", "import", "fcpxml"]:
            try only("POST")
            guard let body = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] else { throw APIError.badRequest("The body isn't a JSON object.") }
            do {
                // Like batch: the file and its media must lie in a folder the user allowed in Settings › Agents.
                let timeline = try TimelineImport.check(body, policy: AgentFolders.policy)
                let opened = try await TimelineImporter.open(timeline)
                guard let session = opened.session else { throw APIError.internalError("The document window didn't open.") }
                return .json(["document": detail(session), "import": TimelineImport.json(opened.imported)], status: 201)
            } catch let e as BatchError {
                if e.reason == "bad_request" { throw APIError.badRequest(e.message) }
                if e.reason == "not_found" { throw APIError.notFound(e.message) }
                throw APIError.unprocessable(e.reason, e.message)
            }
        case ["api", "v1", "plugins"]:
            try only("GET")
            let q = r.query["q"]?.lowercased()
            let format = r.query["format"]?.lowercased()
            if let format, !["au", "clap"].contains(format) { throw APIError.badRequest("format must be au or clap.") }
            let list = PluginCatalog.effects().filter { (q == nil || q!.isEmpty || $0.name.lowercased().contains(q!) || $0.manufacturer.lowercased().contains(q!))
                && (format == nil || $0.format.rawValue == format) }
            // No file paths: where a plugin is installed is the user's business.
            var answer: [String: Any] = ["plugins": list.map { ["id": $0.id.description, "format": $0.format.rawValue, "name": $0.name, "manufacturer": $0.manufacturer, "kind": $0.kind,
                                                                 "version": $0.version, "v3": $0.isV3] as [String: Any] },
                                         "safeMode": EditorSession.pluginSafeMode]
            if HostedPluginsController.available {
                answer["scan"] = scanJSON(HostedPlugins.current())
                answer["note"] = "Plugins are third-party code. CLAP plugins each run in a helper process of their own, never inside Jämmer; if one crashes or stops answering, its track plays without it and the plugin is switched off until the user switches it on again. Audio Units run inside Jämmer unless Safe Mode is on (Audio › Plugins), which runs every Audio Unit in macOS's separate plugin host process."
            } else {
                answer["note"] = "Plugins are third-party code that runs inside Jämmer. If one crashes or misbehaves, turn on Safe Mode in Jämmer (Audio › Plugins) so every Audio Unit runs in macOS's separate plugin host process instead."
            }
            return .json(answer)
        case ["api", "v1", "plugins", "scan"]:
            try only("POST")
            guard HostedPluginsController.available else { throw APIError.notAvailable("This copy of Jämmer doesn't run CLAP plugins, so there is nothing to scan for.") }
            let body = try json(r)
            if let unknown = body.keys.first(where: { $0 != "force" }) { throw APIError.badRequest("Unknown field \"\(unknown)\". plugins/scan takes: force.") }
            if let f = body["force"], !(f is Bool) { throw APIError.badRequest("force must be true or false.") }
            return .json(["job": JobRegistry.shared.startPluginScan(force: body["force"] as? Bool ?? false).json], status: 202)
        case ["api", "v1", "operations"]:
            try only("GET")
            return .json(["operations": AgentAPI.operations])
        case ["api", "v1", "documents"]:
            try only("GET", "POST")
            if r.method == "GET" { return .json(["documents": AgentRegistry.shared.sessions.map(summary)]) }
            return try await createDocument(r)
        case ["api", "v1", "uploads"]:
            try only("POST")
            let u = UploadStore.shared.create()
            return .json(["upload": ["id": u.id, "size": 0]], status: 201)
        case let p where p.count == 4 && Array(p.prefix(3)) == ["api", "v1", "uploads"]:
            try only("GET", "PUT", "DELETE")
            switch r.method {
            case "GET":
                guard let u = UploadStore.shared.get(p[3]) else { throw APIError.notFound("No upload with id \(p[3]).") }
                return .json(["upload": ["id": u.id, "size": u.size]])
            case "DELETE":
                guard UploadStore.shared.get(p[3]) != nil else { throw APIError.notFound("No upload with id \(p[3]).") }
                UploadStore.shared.remove(p[3])
                return .json(["deleted": true])
            default:
                guard let offset = Int64(r.query["offset"] ?? "") else { throw APIError.badRequest("Add ?offset=<bytes received so far>.") }
                let u = try UploadStore.shared.append(p[3], offset: offset, data: r.body)
                return .json(["upload": ["id": u.id, "size": u.size]])
            }
        case let p where p.count >= 4 && Array(p.prefix(3)) == ["api", "v1", "documents"]:
            guard let session = AgentRegistry.shared.session(p[3]) else {
                throw APIError.notFound("No open document with id \(p[3]). GET /api/v1/documents lists them.")
            }
            switch Array(p.dropFirst(4)) {
            case []:
                try only("GET")
                return .json(["document": detail(session)])
            case ["steps"]:
                try only("POST")
                return try await steps(session, r)
            case ["undo"], ["redo"]:
                try only("POST")
                return try await undoRedo(session, redo: p.last == "redo")
            case ["analysis"]:
                try only("GET")
                let range = try queryRange(r, session)
                let only = try namedTracks(session, (r.query["tracks"] ?? r.query["track"])?.split(separator: ",").map(String.init))
                let result = await session.analyze(range, tracks: only)
                var body = result.json
                if let range { body["start"] = seconds(session, range.lowerBound); body["end"] = seconds(session, range.upperBound) }
                if let only { body["tracks"] = session.project.tracks.filter { only.contains($0.id) }.map(\.id.uuidString) }
                return .json(["analysis": body])
            case ["analysis", "rhythm"]:
                try only("GET")
                let range = try queryRange(r, session) ?? 0..<session.project.length
                let named = try namedTracks(session, (r.query["tracks"] ?? r.query["track"])?.split(separator: ",").map(String.init))
                let project = session.project, pool = session.pool
                let found = await Task.detached(priority: .userInitiated) { Result { try Rhythm.estimate(project, range: range, tracks: named, pool: pool) } }.value
                var body: [String: Any] = ["start": seconds(session, range.lowerBound), "end": seconds(session, range.upperBound),
                                           "analysedSeconds": min(session.project.seconds(Frame(range.count)), Rhythm.maxSeconds)]
                let offset = session.project.seconds(range.lowerBound)
                switch found {
                case .success(let e):
                    body["bpm"] = e.bpm
                    body["firstBeat"] = ((offset + e.firstBeat) * 1_000).rounded() / 1_000
                    body["beats"] = e.beats.map { (($0 + offset) * 1_000).rounded() / 1_000 }
                    body["pulse"] = e.pulse
                    body["alternatives"] = e.alternatives
                case .failure(let error):
                    guard let f = error as? Rhythm.Failure, f != .unavailable else { throw APIError.notAvailable("Tempo detection isn't available in this build.") }
                    body["bpm"] = NSNull()
                    body["beats"] = [Double]()
                    body["alternatives"] = [Double]()
                    body["reason"] = f.reason
                    body["message"] = f.localizedDescription
                }
                return .json(["rhythm": body])
            case ["waveform"]:
                try only("GET")
                return try waveform(session, r)
            case ["transcribe"]:
                try only("POST")
                let body = try json(r)
                let lang = (body["language"] as? String) ?? Locale.current.identifier(.bcp47)
                let name = (body["engine"] as? String) ?? "auto"
                guard let choice = SpeechEngines.Choice(rawValue: name), SpeechEngines.Choice.offered.contains(choice) else {
                    throw APIError.badRequest("engine must be one of \(SpeechEngines.Choice.offered.map(\.rawValue).joined(separator: ", ")).")
                }
                // A paid engine sends the audio to its provider and costs money: only on an explicit yes.
                if choice.paid, body["allowPaid"] as? Bool != true {
                    throw APIError.paidNotAllowed("engine \(name) sends the audio to its provider and is paid for by the user. Pass \"allowPaid\": true to run it.")
                }
                let model = body["model"] as? String
                do { _ = try SpeechEngines.engine(choice, for: Locale(identifier: lang), model: model) } catch let e as SpeechEngines.Unavailable {
                    throw APIError.unprocessable(e.reason, e.message)
                }
                let job = JobRegistry.shared.startTranscription(session, locale: Locale(identifier: lang),
                                                                replace: body["replace"] as? Bool ?? false, engine: choice, model: model)
                return .json(["job": job.json], status: 202)
            case ["transcript"]:
                try only("GET")
                return try transcript(session, r)
            case ["history"]:
                try only("GET")
                guard let h = session.history else { throw APIError.notAvailable("This document has no history yet.") }
                let active = Set(h.activePath)
                return .json(["current": h.current.uuidString, "pruned": h.pruned, "limit": h.limit,
                              "nodes": h.nodes.map { n -> [String: Any] in
                                  ["id": n.id.uuidString, "parent": n.parent?.uuidString ?? NSNull(), "action": n.action,
                                   "time": ISO8601DateFormatter().string(from: n.time), "branch": !active.contains(n.id)]
                              }])
            case let t where t.count == 2 && t[0] == "history":
                try only("POST")
                guard let id = UUID(uuidString: t[1]), session.history?.node(id) != nil else { throw APIError.notFound("No step \(t[1]) in the history.") }
                try session.jump(to: id)
                return .json(["current": id.uuidString, "document": detail(session)])
            case ["separate"]:
                try only("POST")
                let body = try json(r)
                let model = (body["model"] as? String) ?? "music4"
                guard ["music4", "dialog"].contains(model) else { throw APIError.badRequest("model must be \"music4\" or \"dialog\".") }
                var ids: [UUID]? = nil
                if let list = body["tracks"] as? [String] {
                    ids = try list.map { s in
                        guard let id = UUID(uuidString: s), session.project.tracks.contains(where: { $0.id == id }) else { throw APIError.badRequest("No track with id \(s).") }
                        return id
                    }
                }
                guard Stems.isInstalled(model) else { throw APIError.unprocessable("model_missing", StemError.modelMissing.localizedDescription) }
                if let t = session.project.tracks.first(where: { (ids?.contains($0.id) ?? true) && !$0.inserts.isEmpty && !$0.clips.isEmpty }) {
                    throw APIError.unprocessable("has_inserts", StemError.hasInserts(t.name).localizedDescription)
                }
                return .json(["job": JobRegistry.shared.startSeparation(session, tracks: ids, model: model).json], status: 202)
            case ["diarize"]:
                try only("POST")
                return try diarize(session, r)
            case ["speakers"]:
                try only("GET")
                return try speakers(session, r)
            case ["tracks"]:
                try only("GET", "POST")
                if r.method == "GET" { return .json(["tracks": session.project.tracks.map { trackJSON(session, $0) }]) }
                return try await addTrack(session, r)
            case let t where t.count == 4 && t[0] == "tracks" && t[2] == "inserts":
                try only("GET")
                return try await insertDetail(session, track: t[1], insert: t[3])
            case let t where t.count == 3 && t[0] == "tracks" && t[2] == "drift":
                try only("GET")
                guard let id = UUID(uuidString: t[1]), session.project.tracks.contains(where: { $0.id == id }) else {
                    throw APIError.notFound("No track with id \(t[1]).")
                }
                guard let against = r.query["against"].flatMap(UUID.init(uuidString:)) ?? session.project.tracks.first(where: { $0.id != id })?.id else {
                    throw APIError.badRequest("Pass ?against=<track id>.")
                }
                let p = session.project, pool = session.pool
                guard let d = await Task.detached(operation: { p.drift(of: id, against: against, pool: pool) }).value else {
                    throw APIError.unprocessable("too_short", "The tracks overlap too little to measure drift (at least 90 s).")
                }
                return .json(["drift": ["ppm": (d.partsPerMillion * 10).rounded() / 10, "msPerHour": (d.partsPerMillion * 3.6 * 10).rounded() / 10,
                                        "confidence": min(d.start.confidence, d.end.confidence)]])
            case ["chapters"]:
                try only("GET")
                let range = try queryRange(r, session)
                return Response(status: 200, contentType: "application/json+chapters",
                                body: try ChapterFormats.podcastingJSON(session.project.chapters(in: range)))
            case ["restore"]:
                try only("POST")
                return try restore(session, r)
            case ["restore", "preview"]:
                try only("POST")
                return try await restorePreview(session, r)
            case ["analysis", "restoration"]:
                try only("GET")
                return try await restorationAnalysis(session, r)
            case ["analysis", "acx"]:
                try only("GET")
                let m = await session.acxMeasured()
                let rows = ACX.requirements(m)
                // A measurement against published requirements, with their source and date: never an approval.
                return .json(["acx": ["statement": ACX.wording, "source": ACX.source, "articleDate": ACX.articleDate, "readOn": ACX.readOn,
                                      "requirements": rows.map(\.json), "failed": rows.filter { $0.pass == false }.map(\.name),
                                      "measuredOn": m.encoded != nil ? "mp3" : "mix"] as [String: Any]])
            case ["export"]:
                try only("POST")
                return try await export(session, r)
            case ["play"]:
                try only("POST")
                guard let w = session.window, w.isVisible, !w.isMiniaturized, w.occlusionState.contains(.visible) else {
                    throw APIError.notAvailable("The document's window isn't visible, so Jämmer won't play. Ask the user to bring it forward.")
                }
                let obj = try json(r)
                session.play(from: (obj["at"] as? Double).map { session.project.frames($0) })
                return .json(["playing": true, "playhead": seconds(session, session.playhead)])
            case ["stop"]:
                try only("POST")
                session.stop()
                return .json(["playing": false, "playhead": seconds(session, session.playhead)])
            default:
                throw APIError.notFound("No such path: \(r.path). See \(AgentAPI.guidePath).")
            }
        default:
            throw APIError.notFound("No such path: \(r.path). See \(AgentAPI.guidePath).")
        }
    }

    // MARK: Documents

    static func seconds(_ s: EditorSession, _ f: Frame) -> Double { (s.project.seconds(f) * 1_000_000).rounded() / 1_000_000 }

    static func summary(_ s: EditorSession) -> [String: Any] {
        s.checkLink()
        return ["id": s.agentID, "name": s.name, "duration": seconds(s, s.project.length), "frames": s.project.length,
         "sampleRate": s.project.sampleRate, "channels": s.project.channels, "tracks": s.project.tracks.count,
         "edited": s.document?.isDocumentEdited ?? false, "playing": s.isPlaying,
         "linkedFile": s.linkedFile.map { ["name": $0.fileName, "format": $0.format.rawValue, "requester": $0.requester, "available": true] as [String: Any] } as Any?
             ?? s.lostLink.map { ["name": $0.name, "requester": $0.requester, "available": false, "reason": $0.why] as [String: Any] } as Any? ?? NSNull(),
         // The document the user is looking at (restored windows can be many; SIBLINGS.md §1).
         "frontmost": s.window != nil && s.window === NSApp.orderedWindows.first { $0.isVisible && $0.windowController is EditorWindowController }]
    }

    static func detail(_ s: EditorSession) -> [String: Any] {
        var d = summary(s)
        let p = s.project
        d["tracks"] = p.tracks.map { trackJSON(s, $0) }
        d["markers"] = p.markers.map { m -> [String: Any] in
            var e: [String: Any] = ["name": m.name, "at": seconds(s, m.position), "frame": m.position]
            if m.length > 0 { e["duration"] = seconds(s, m.length) }
            if let k = m.kind { e["kind"] = k.rawValue }
            return e
        }
        d["tempo"] = ["changes": p.tempo.changes.map { c -> [String: Any] in
            ["at": seconds(s, c.position), "frame": c.position, "bpm": c.bpm, "meter": c.meter.description]
        }]
        d["selection"] = s.selection.map { ["start": seconds(s, $0.lowerBound), "end": seconds(s, $0.upperBound)] } ?? NSNull()
        d["playhead"] = seconds(s, s.playhead)
        d["sources"] = p.sources.map { src -> [String: Any] in
            ["name": src.name, "format": "\(src.info.container.rawValue) \(src.info.sampleFormat.rawValue)",
             "missing": s.pool.missing.contains(src.id)]
        }
        return d
    }

    static func trackJSON(_ s: EditorSession, _ t: Track) -> [String: Any] {
        let p = s.project
        return ["id": t.id.uuidString, "name": t.name, "gainDB": t.gainDB, "muted": t.isMuted, "group": t.group?.uuidString ?? NSNull(),
                "inserts": t.inserts.map { i -> [String: Any] in
                    var d: [String: Any] = ["id": i.id.uuidString, "plugin": i.plugin.description, "name": i.name, "bypass": i.bypass]
                    if let f = s.inserts.failure(i.id) { d["error"] = ["reason": f.reason, "message": f.localizedDescription] }
                    return d
                },
                "clips": t.clips.map { c -> [String: Any] in
                    ["start": seconds(s, c.start), "end": seconds(s, c.end), "startFrame": c.start, "endFrame": c.end,
                     "source": p.source(c.sourceID)?.name ?? "?", "sourceStart": seconds(s, c.sourceStart),
                     "gainDB": (c.gainDB * 100).rounded() / 100, "fadeIn": seconds(s, c.fadeIn), "fadeOut": seconds(s, c.fadeOut)]
                }]
    }

    /// One insert with its parameters, read from the playing unit (or a unit of its own
    /// while that one is still starting).
    private static func insertDetail(_ session: EditorSession, track: String, insert: String) async throws -> Response {
        guard let t = session.project.tracks.first(where: { $0.id.uuidString == track.uppercased() }) else {
            throw APIError.notFound("No track with id \(track).")
        }
        guard let i = t.inserts.first(where: { $0.id.uuidString == insert.uppercased() }) else {
            throw APIError.notFound("The track has no insert with id \(insert).")
        }
        let unit: any InsertUnit
        if let live = session.inserts.instance(i.id) {
            unit = live
        } else {
            if let failure = session.inserts.failure(i.id), case .withheld = failure { throw APIError.unprocessable(failure.reason, failure.localizedDescription) }
            do {
                unit = try await InsertUnits.make(i.plugin, channels: session.project.channels, sampleRate: session.project.sampleRate,
                                                     state: i.state, outOfProcess: EditorSession.pluginSafeMode)
            } catch let e as PluginError {
                throw APIError.unprocessable(e.reason, e.localizedDescription)
            }
        }
        return .json(["insert": ["id": i.id.uuidString, "plugin": i.plugin.description, "format": i.plugin.format.rawValue, "name": i.name, "bypass": i.bypass,
                                 "latencyMs": (Double(unit.latency) / session.project.sampleRate * 100_000).rounded() / 100,
                                 "factoryPresets": unit.factoryPresets,
                                 "params": unit.parameters.map { p -> [String: Any] in
                                     ["identifier": p.identifier, "name": p.name, "unit": p.unit ?? NSNull(), "min": p.min, "max": p.max, "value": p.value]
                                 }] as [String: Any]])
    }

    /// What the last scan for VST 3 and CLAP plugins found and what it couldn't use.
    static func scanJSON(_ c: PluginCatalogue) -> [String: Any] {
        ["state": HostedPluginsController.scanning ? "running" : "idle", "found": c.plugins.count,
         "failed": c.failed.map { ["name": $0.name, "format": $0.format.rawValue, "reason": $0.reason] as [String: Any] }]
    }

    private static func json(_ r: AgentAPI.Request) throws -> [String: Any] {
        if r.body.isEmpty { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any] else {
            throw APIError.badRequest("The body isn't a JSON object.")
        }
        return obj
    }

    private static func queryRange(_ r: AgentAPI.Request, _ s: EditorSession) throws -> Range<Frame>? {
        guard let a = r.query["start"], let b = r.query["end"] else {
            if r.query["start"] != nil || r.query["end"] != nil { throw APIError.badRequest("Give both start and end, or neither.") }
            return nil
        }
        guard let start = Double(a), let end = Double(b), start >= 0, end > start else {
            throw APIError.badRequest("start and end must be seconds with end after start.")
        }
        return s.project.frames(start)..<min(s.project.length, s.project.frames(end))
    }

    /// Guesses the file type from its first bytes.
    static func fileExtension(for data: Data, contentType: String) -> String {
        let b = [UInt8](data.prefix(12))
        func tag(_ s: String, at o: Int = 0) -> Bool { b.count >= o + 4 && Array(b[o..<(o + 4)]) == Array(s.utf8) }
        if tag("RIFF") || tag("RF64") || tag("BW64") { return "wav" }
        if tag("FORM") { return "aif" }
        if tag("fLaC") { return "flac" }
        if tag("caff") { return "caf" }
        if tag("OggS") { return "ogg" }
        if tag("ftyp", at: 4) { return "m4a" }
        if tag("ID3") || (b.count >= 2 && b[0] == 0xFF && (b[1] & 0xE0) == 0xE0) { return "mp3" }
        return [("audio/wav", "wav"), ("audio/x-wav", "wav"), ("audio/aiff", "aif"), ("audio/mpeg", "mp3"),
                ("audio/mp4", "m4a"), ("audio/flac", "flac")].first { contentType.hasPrefix($0.0) }?.1 ?? "audio"
    }

    private static func createDocument(_ r: AgentAPI.Request) async throws -> Response {
        let (source, warning) = try await importedSource(r)
        guard let controller = NSDocumentController.shared as? JammerDocumentController else {
            throw APIError.internalError("The document controller isn't Jämmer's.")
        }
        let doc = controller.open(Project(source: source), name: source.name)
        guard let session = doc.session else { throw APIError.internalError("The document window didn't open.") }
        if let warning { session.status = warning }
        // A sibling that makes a document is shown too, not only one that changes it.
        if let sib = r.headers["x-sibling"]?.lowercased() { session.status = "Requested by \(siblingNames[sib] ?? sib)" }
        var answer: [String: Any] = ["document": detail(session)]
        if let warning { answer["warning"] = warning }
        return .json(answer, status: 201)
    }

    /// Audio from a request (raw bytes, base64 JSON or an upload), imported as a source.
    /// Also what the user (and the agent) should know about it, e.g. that the file was cut short.
    /// With `sampleRate` (adding to a document), audio at another rate is converted to it; without, the file's own rate is kept.
    private static func importedSource(_ r: AgentAPI.Request, sampleRate: Double? = nil) async throws -> (source: SourceRef, warning: String?) {
        let type = (r.headers["content-type"] ?? "").lowercased()
        var name = r.query["name"]
        let fileURL: URL
        if type.hasPrefix("audio/") || type == "application/octet-stream" {
            guard !r.body.isEmpty else { throw APIError.badRequest("The audio body is empty.") }
            try UploadStore.checkSpace(for: Int64(r.body.count), at: MediaStore.folder)
            fileURL = MediaStore.folder.appending(path: "\(UUID().uuidString.prefix(8)).\(fileExtension(for: r.body, contentType: type))")
            try r.body.write(to: fileURL)
        } else {
            let obj = try json(r)
            name = obj["name"] as? String ?? name
            if let b64 = obj["audio"] as? String {
                guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters), !data.isEmpty else {
                    throw APIError.badRequest("\"audio\" isn't valid base64.")
                }
                try UploadStore.checkSpace(for: Int64(data.count), at: MediaStore.folder)
                fileURL = MediaStore.folder.appending(path: "\(UUID().uuidString.prefix(8)).\(fileExtension(for: data, contentType: ""))")
                try data.write(to: fileURL)
            } else if let id = obj["upload"] as? String {
                guard let u = UploadStore.shared.get(id) else { throw APIError.notFound("No upload with id \(id).") }
                let head = (try? FileHandle(forReadingFrom: u.url).read(upToCount: 12)) ?? Data()
                fileURL = MediaStore.folder.appending(path: "\(UUID().uuidString.prefix(8)).\(fileExtension(for: head, contentType: ""))")
                try FileManager.default.moveItem(at: u.url, to: fileURL)
                UploadStore.shared.remove(id)
            } else {
                throw APIError.badRequest("Send audio bytes (Content-Type: audio/…), {\"audio\": \"<base64>\"} or {\"upload\": \"<id>\"}.")
            }
        }
        let result: AudioImporter.Result
        do {
            let url = fileURL
            result = try await Task.detached(priority: .userInitiated) {
                try AudioImporter.importFile(url, sampleRate: sampleRate, mediaFolder: MediaStore.folder)
            }.value
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            // In the caller's words: the file's name here is one Jämmer made up for the bytes it was sent.
            var why = error.localizedDescription
            for lead in ["Jämmer can't open \(fileURL.lastPathComponent). ", "Jämmer can't read \(fileURL.lastPathComponent): ", "Jämmer can't read \(fileURL.lastPathComponent). "] where why.hasPrefix(lead) {
                why = String(why.dropFirst(lead.count))
            }
            why = why.replacingOccurrences(of: fileURL.lastPathComponent, with: "The audio")
            why = why.prefix(1).uppercased() + why.dropFirst()
            throw APIError.badRequest("Jämmer couldn't open the audio. \(why) Jämmer takes WAV, AIFF, MP3, AAC/M4A, FLAC, ALAC and CAF.")
        }
        if result.decoded { try? FileManager.default.removeItem(at: fileURL) }
        var source = result.source
        source.name = name ?? "Agent audio"
        // The warning names the temporary file; say the document's name instead.
        let warning = result.warning.map { w in w.replacingOccurrences(of: fileURL.lastPathComponent, with: "The audio") }
        return (source, warning)
    }

    /// A header-safe file name.
    static func asciiName(_ s: String) -> String {
        let folded = s.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false) ?? s
        let cleaned = String(folded.unicodeScalars.map { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || " -_".unicodeScalars.contains($0)) ? Character($0) : "_" })
        return cleaned.isEmpty ? "export" : cleaned
    }

    // MARK: Editing

    private static func steps(_ session: EditorSession, _ r: AgentAPI.Request) async throws -> Response {
        let (steps, _) = try AgentAPI.parseSteps(r.body)
        let results = await session.run(steps, action: steps.count == 1 ? (Operations.named(steps[0].op)?.title ?? "Agent Edit") : "Agent Edits")
        let list: [[String: Any]] = results.enumerated().map { i, res in
            var d: [String: Any] = ["index": i, "op": res.op, "status": res.status.rawValue]
            if let e = res.error { d["error"] = e }
            if !res.info.isEmpty || !res.ids.isEmpty {
                var info: [String: Any] = res.info
                for (k, v) in res.ids { info[k] = v }
                d["info"] = info
            }
            return d
        }
        if let failed = results.firstIndex(where: { $0.status == .failed }) {
            var err: [String: Any] = ["code": "step_failed", "step": failed,
                                      "message": "Step \(failed) (\(results[failed].op)) failed: \((results[failed].error ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))). Nothing was changed."]
            if let reason = results[failed].reason { err["reason"] = reason }
            for (k, v) in results[failed].details { err[k] = v == v.rounded() ? Int(v) as Any : v as Any }
            return .json(["error": err,
                          "results": list, "document": detail(session)], status: 422)
        }
        await settle()
        return .json(["results": list, "document": detail(session)])
    }

    /// Adds a track from audio sent like POST /documents (bytes, base64 JSON or upload).
    private static func addTrack(_ session: EditorSession, _ r: AgentAPI.Request) async throws -> Response {
        // Where and how loud, in the same undo step (checked before the audio is taken in): ?at= seconds on the timeline, ?gainDB= the track's gain.
        var at: Frame = 0, gain = 0.0
        if let raw = r.query["at"] {
            guard let v = Double(raw), v.isFinite, v >= 0, v <= 86_400 * 7 else { throw APIError.badRequest("at must be seconds from the start, 0 or more.") }
            at = session.project.frames(v)
        }
        if let raw = r.query["gainDB"] {
            guard let v = Double(raw), v.isFinite, (-96...24).contains(v) else { throw APIError.badRequest("gainDB must be between -96 and 24.") }
            gain = v
        }
        // A track plays at the document's sample rate, so audio at another rate is converted on the way in.
        let (source, warning) = try await importedSource(r, sampleRate: session.project.sampleRate)
        var p = session.project
        let track = p.addTrack(source: source, name: r.query["name"] ?? source.name)
        if let t = p.tracks.firstIndex(where: { $0.id == track.id }) {
            p.tracks[t].gainDB = gain
            for c in p.tracks[t].clips.indices { p.tracks[t].clips[c].start += at }
        }
        session.commit(p, action: "Add Track")
        var answer: [String: Any] = ["track": ["id": track.id.uuidString, "name": track.name, "gainDB": gain, "at": seconds(session, at)] as [String: Any],
                                     "document": detail(session)]
        if let warning {
            answer["warning"] = warning
            session.status = warning
        }
        return .json(answer, status: 201)
    }

    private static func transcript(_ session: EditorSession, _ r: AgentAPI.Request) throws -> Response {
        let range = try queryRange(r, session)
        let placed = session.project.placedWords(in: range)
        let words = placed.map { AgentAPI.wordJSON($0) { seconds(session, $0) } }
        let langs = Set(session.project.transcripts.map(\.language)).sorted()
        // True when a transcript here has the text but no word times: its words' start and end are
        // spread evenly, and delete_words and remove_fillers answer 422 text_only.
        let textOnly = placed.contains { $0.word.untimed == true }
        return .json(["words": words, "text": placed.map(\.word.text).joined(separator: " "), "languages": langs, "textOnly": textOnly,
                      "speakers": session.project.speakers.enumerated().map { ["id": $0.offset, "name": $0.element] as [String: Any] }])
    }

    private static func speakers(_ session: EditorSession, _ r: AgentAPI.Request) throws -> Response {
        let range = try queryRange(r, session)
        let p = session.project
        let secs = p.speakerSeconds(in: range)
        return .json(["speakers": p.speakers.enumerated().map { i, n -> [String: Any] in ["id": i, "name": n, "seconds": ((secs[i] ?? 0) * 10).rounded() / 10] },
                      "turns": p.placedTurns(in: range).map { t -> [String: Any] in
                          ["speaker": t.speaker, "track": p.tracks[t.track].id.uuidString, "start": seconds(session, t.start), "end": seconds(session, t.end)]
                      }])
    }

    private static func diarize(_ session: EditorSession, _ r: AgentAPI.Request) throws -> Response {
        let body = try json(r)
        let p = session.project
        let mode = body["mode"] as? String
        if let mode, !["by_track", "ml"].contains(mode) { throw APIError.badRequest("mode must be \"by_track\" or \"ml\".") }
        var tracks = p.tracks.filter { !$0.clips.isEmpty }.map(\.id)
        if let list = body["tracks"] as? [String] {
            tracks = try list.map { s in
                guard let id = UUID(uuidString: s), p.tracks.contains(where: { $0.id == id }) else {
                    throw APIError.badRequest("No track with id \(s). GET /api/v1/documents/{id}/tracks lists them.")
                }
                return id
            }
        }
        guard !tracks.isEmpty else { throw APIError.unprocessable("nothing_to_diarize", "There's no audio to look for speakers in.") }
        func count(_ key: String) throws -> Int? {
            guard let v = body[key] else { return nil }
            guard let n = (v as? NSNumber)?.intValue, (1...20).contains(n) else { throw APIError.badRequest("\(key) must be a whole number from 1 to 20.") }
            return n
        }
        var lo = try count("minSpeakers"), hi = try count("maxSpeakers")
        if let n = try count("speakers") { lo = n; hi = n }
        if let lo, let hi, lo > hi { throw APIError.badRequest("minSpeakers can't be above maxSpeakers.") }
        let byTrack = mode == "by_track" || (mode == nil && p.hasOverlappingTracks)
        if byTrack, lo != nil || hi != nil {
            throw APIError.badRequest("Speaker counts are for mode \"ml\"; by_track gives each track one speaker.")
        }
        if !byTrack, Diarization.engine == nil {
            throw APIError.unprocessable("model_unavailable", "This copy of Jämmer has no diarisation model; mode \"by_track\" works without one.")
        }
        let job = JobRegistry.shared.startDiarization(session, byTrack: byTrack, tracks: tracks, minSpeakers: lo, maxSpeakers: hi)
        return .json(["job": job.json], status: 202)
    }

    // MARK: Restoration

    static let restoreTitles: [Restoration.Kind: String] = [.dehum: "Remove Hum", .declip: "Repair Clipping", .declick: "Remove Clicks", .denoise: "Reduce Noise", .dereverb: "Reduce Reverb"]

    /// The range (explicit, else the selection, else everything) and the tracks (nil = all).
    private static func restoreScope(_ session: EditorSession, start: Double?, end: Double?, tracks: [UUID]?) throws -> (Range<Frame>, Set<UUID>?) {
        let p = session.project
        var range = 0..<p.length
        if let start, let end { range = p.frames(start)..<min(p.length, p.frames(end)) }
        else if let sel = session.selection { range = sel }
        if let tracks {
            for id in tracks where !p.tracks.contains(where: { $0.id == id }) {
                throw APIError.badRequest("No track with id \(id.uuidString). GET /api/v1/documents/{id} lists the tracks.")
            }
        }
        let set = tracks.map(Set.init)
        let hasAudio = !range.isEmpty && p.tracks.contains { t in (set?.contains(t.id) ?? true) && t.clips.contains { $0.start < range.upperBound && $0.end > range.lowerBound } }
        guard hasAudio else { throw APIError.unprocessable("nothing_in_range", "There's no audio in that range on those tracks.") }
        return (range, set)
    }

    /// Cheap checks before a job starts; finds the hum frequency once so the job doesn't have to.
    private static func precheck(_ session: EditorSession, _ settings: inout Restoration.Settings, _ range: Range<Frame>, _ tracks: Set<UUID>?) throws {
        guard settings.kind == .dehum, settings.humFrequency == nil else { return }
        let probe = range.lowerBound..<min(range.upperBound, range.lowerBound + session.project.frames(20))
        let mix = Restoration.mix(session.project, range: probe, tracks: tracks, pool: session.pool)
        guard let hum = Restoration.detectHum(mix, sampleRate: session.project.sampleRate) else {
            throw APIError.unprocessable("no_hum", "No mains hum found (50 or 60 Hz). Pass humFrequency to remove a hum anyway.")
        }
        settings.humFrequency = hum.frequency
    }

    private static func restore(_ session: EditorSession, _ r: AgentAPI.Request) throws -> Response {
        let req = try RestoreRequest.parse(try json(r))
        let (range, tracks) = try restoreScope(session, start: req.start, end: req.end, tracks: req.tracks)
        var settings = req.settings
        try precheck(session, &settings, range, tracks)
        let job = JobRegistry.shared.startRestoration(session, settings: settings, range: range, tracks: tracks,
                                                      action: restoreTitles[settings.kind] ?? "Restore")
        return .json(["job": job.json], status: 202)
    }

    static func analysisJSON(_ a: Restoration.Analysis) -> [String: Any] {
        ["hum": a.hum.map { ["frequency": $0.frequency, "prominenceDB": ($0.prominence * 10).rounded() / 10] as [String: Any] } ?? NSNull(),
         "clipping": ["runs": a.clippedRuns, "samples": a.clippedSamples, "level": (Double(a.clipLevel) * 10_000).rounded() / 10_000],
         "clicks": ["count": a.clicks],
         "reverb": (a.reverbUnknown.map { ["rt60": NSNull(), "present": NSNull(), "unknown": $0] as [String: Any] }
                    ?? ["rt60": a.rt60.map { ($0 * 100).rounded() / 100 as Any } ?? NSNull(), "present": a.reverberant] as [String: Any]),
         "noiseFloor": a.noiseFloor.map { ["dBFS": ($0.level * 10).rounded() / 10, "pauseSeconds": ($0.seconds * 100).rounded() / 100] as [String: Any] } ?? NSNull(),
         "examinedSeconds": (a.examined * 100).rounded() / 100, "sampled": a.sampled]
    }

    private static func restorationAnalysis(_ session: EditorSession, _ r: AgentAPI.Request) async throws -> Response {
        let q = try RestoreRequest.parseQuery(r.query)
        let (range, tracks) = try restoreScope(session, start: q.start, end: q.end, tracks: q.tracks)
        let project = session.project, pool = session.pool
        let a = await Task.detached(priority: .userInitiated) { Restoration.analyze(project, range: range, tracks: tracks, pool: pool) }.value
        var body = analysisJSON(a)
        body["start"] = seconds(session, range.lowerBound)
        body["end"] = seconds(session, range.upperBound)
        return .json(["restoration": body])
    }

    private static func restorePreview(_ session: EditorSession, _ r: AgentAPI.Request) async throws -> Response {
        let req = try RestoreRequest.parse(try json(r))
        let (range, tracks) = try restoreScope(session, start: req.start, end: req.end, tracks: req.tracks)
        guard session.project.seconds(Frame(range.count)) <= 30.0001 else {
            throw APIError.badRequest("A preview is at most 30 seconds. Pass start and end.")
        }
        var settings = req.settings
        try precheck(session, &settings, range, tracks)
        let project = session.project, pool = session.pool, s = settings
        let wantsJSON = (r.headers["accept"] ?? "").contains("application/json")
        let result = await Task.detached(priority: .userInitiated) { () -> Result<(Project, [Float]), Error> in
            Result { try Restoration.preview(s, project: project, range: range, tracks: tracks, pool: pool) }
        }.value
        let (repaired, audio) = try result.get()
        if wantsJSON {
            let measured = await Task.detached(priority: .userInitiated) { () -> [(Restoration.Analysis, LoudnessResult)] in
                [project, repaired].map { p in
                    (Restoration.analyze(p, range: range, tracks: tracks, pool: pool), LoudnessMeter.measure(PlanCompiler.compile(p, pool: pool), range))
                }
            }.value
            let (before, after) = (measured[0], measured[1]).self
            func json(_ m: (Restoration.Analysis, LoudnessResult)) -> [String: Any] {
                var d = analysisJSON(m.0)
                d["integratedLUFS"] = m.1.integrated.map { ($0 * 100).rounded() / 100 } ?? NSNull()
                d["truePeakDBTP"] = m.1.truePeak.isFinite ? (m.1.truePeak * 100).rounded() / 100 : NSNull()
                return d
            }
            return .json(["before": json(before), "after": json(after), "start": seconds(session, range.lowerBound), "end": seconds(session, range.upperBound)])
        }
        let tmp = FileManager.default.temporaryDirectory.appending(path: "jammer-preview-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let w = try WAVWriter(url: tmp, options: .init(encoding: .int24, channels: project.channels, sampleRate: project.sampleRate))
        try w.write(audio)
        try w.finish()
        return Response(status: 200, contentType: "audio/wav", body: try Data(contentsOf: tmp),
                        extraHeaders: ["Content-Disposition": "attachment; filename=\"preview.wav\""])
    }

    /// AppKit marks a document edited a turn of the run loop after the undo step that changed it.
    /// A reply built before that says "edited": false about a document that was just changed.
    private static func settle() async { try? await Task.sleep(nanoseconds: 2_000_000) }

    private static func undoRedo(_ session: EditorSession, redo: Bool) async throws -> Response {
        guard let undo = session.undoManager else { throw APIError.notAvailable("The document has no undo history yet.") }
        // The reply names what was undone or redone, so an agent needn't compare histories to know.
        let name: String
        if redo {
            guard undo.canRedo else { throw APIError.notAvailable("Nothing to redo.") }
            name = undo.redoActionName
            undo.redo()
        } else {
            guard undo.canUndo else { throw APIError.notAvailable("Nothing to undo.") }
            name = undo.undoActionName
            undo.undo()
        }
        await settle()
        return .json([redo ? "redone" : "undone": name, "document": detail(session)])
    }

    private static func waveform(_ session: EditorSession, _ r: AgentAPI.Request) throws -> Response {
        let width = Int(r.query["width"] ?? "200") ?? 200
        guard (1...4_000).contains(width) else { throw APIError.badRequest("width must be 1…4000.") }
        let range = try queryRange(r, session) ?? 0..<session.project.length
        guard !range.isEmpty else { throw APIError.notAvailable("The document is empty.") }
        let fpc = Double(range.count) / Double(width)
        let tracks = session.project.tracks.indices.map { t -> [String: Any] in
            let cols = Waveform.columns(session.project, track: t, start: Double(range.lowerBound), framesPerColumn: fpc,
                                        count: width, peaks: session.peaks, pool: session.pool)
            return ["name": session.project.tracks[t].name,
                    "channels": cols.map { ch in ch.map { [Double(($0.min * 1_000).rounded()) / 1_000, Double(($0.max * 1_000).rounded()) / 1_000] } }]
        }
        return .json(["waveform": ["start": seconds(session, range.lowerBound), "end": seconds(session, range.upperBound),
                                   "columnSeconds": fpc / session.project.sampleRate, "width": width,
                                   "note": "Each column is [min, max] of the samples (−1…1) it covers.", "tracks": tracks]])
    }

    /// The tracks a request names: nil when it names none, 404 for an id that isn't a track of the document.
    private static func namedTracks(_ session: EditorSession, _ ids: [String]?) throws -> Set<UUID>? {
        guard let ids else { return nil }
        guard !ids.isEmpty else { throw APIError.badRequest("tracks must name at least one track.") }
        var out = Set<UUID>()
        for raw in ids {
            guard let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespaces)), session.project.tracks.contains(where: { $0.id == id }) else {
                throw APIError.notFound("No track with id \(raw).")
            }
            out.insert(id)
        }
        return out
    }

    private static func export(_ session: EditorSession, _ r: AgentAPI.Request) async throws -> Response {
        let obj = try json(r)
        if let t = obj["tracks"], !(t is [String]) { throw APIError.badRequest("tracks must be a list of track ids.") }
        let only = try namedTracks(session, obj["tracks"] as? [String])
        let formatName = (obj["format"] as? String ?? "wav").lowercased()
        guard let format = ExportFormat(rawValue: formatName), ExportFormat.available.contains(format) else {
            throw APIError.badRequest("format must be one of \(ExportFormat.available.map(\.rawValue).joined(separator: ", ")).")
        }
        let bits = obj["bitDepth"] as? Int ?? 24
        var encoding: WAVWriter.Encoding = .int24
        var encoded: EncodedExportOptions?
        switch format {
        case .wav:
            switch bits {
            case 16: encoding = .int16
            case 24: encoding = .int24
            case 32: encoding = .float32
            default: throw APIError.badRequest("bitDepth must be 16, 24 or 32 for wav.")
            }
        case .aac:
            if obj["bitDepth"] != nil { throw APIError.badRequest("aac has no bitDepth; use bitRate.") }
            let rate = obj["bitRate"] as? Int ?? 192_000
            guard (64_000...320_000).contains(rate) else { throw APIError.badRequest("bitRate must be 64000–320000.") }
            encoded = EncodedExportOptions(format: .aac, bitRate: rate)
        case .mp3:
            if obj["bitDepth"] != nil { throw APIError.badRequest("mp3 has no bitDepth; use bitRate.") }
            guard session.project.channels <= 2 else { throw APIError.badRequest("mp3 export takes mono or stereo documents.") }
            let rate = obj["bitRate"] as? Int ?? 160_000
            guard [64_000, 96_000, 128_000, 160_000, 192_000, 256_000, 320_000].contains(rate) else {
                throw APIError.badRequest("bitRate for mp3 must be 64000, 96000, 128000, 160000, 192000, 256000 or 320000.")
            }
            encoded = EncodedExportOptions(format: .mp3, bitRate: rate)
        case .opus:
            if obj["bitDepth"] != nil { throw APIError.badRequest("opus has no bitDepth; use bitRate.") }
            guard session.project.channels <= 2 else { throw APIError.badRequest("opus export takes mono or stereo documents.") }
            let rate = obj["bitRate"] as? Int ?? 96_000
            guard (16_000...256_000).contains(rate) else { throw APIError.badRequest("bitRate must be 16000–256000 for opus.") }
            encoded = EncodedExportOptions(format: .opus, bitRate: rate)
        default:
            guard format.bitDepths.contains(bits) else {
                throw APIError.badRequest("bitDepth must be \(format.bitDepths.map(String.init).joined(separator: " or ")) for \(format.rawValue).")
            }
            encoded = EncodedExportOptions(format: format, bitDepth: bits)
        }
        if format.isLossless, obj["bitRate"] != nil { throw APIError.badRequest("bitRate is for aac, mp3 and opus only.") }
        var range: Range<Frame>? = nil
        if let a = obj["start"] as? Double, let b = obj["end"] as? Double {
            guard a >= 0, b > a else { throw APIError.badRequest("start and end must be seconds with end after start.") }
            range = session.project.frames(a)..<min(session.project.length, session.project.frames(b))
        }
        // A loudness target for the delivered file: given here, or the preset the document was just brought to.
        var target: LoudnessDelivery.Target?
        if let t = obj["targetLUFS"] {
            guard let n = t as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), (-40.0 ... -5.0).contains(n.doubleValue) else {
                throw APIError.badRequest("targetLUFS must be a number between -40 and -5.")
            }
            guard !format.isLossless else {
                throw APIError.badRequest("targetLUFS is for mp3, aac and opus, where the encoder changes the loudness. Set the level of a \(format.rawValue) with loudness_preset or normalize.")
            }
            target = .init(integrated: n.doubleValue)
        } else if !format.isLossless, only == nil {
            // The preset was for the whole mix, not for some of its tracks.
            target = session.deliveryTarget
        }
        if let c = obj["compensate"] {
            guard let on = c as? Bool else { throw APIError.badRequest("compensate must be true or false.") }
            if !on { target = nil }
        }
        let frames = Int64((range ?? 0..<session.project.length).count)
        guard frames > 0 else { throw APIError.notAvailable("Nothing to export.") }
        let bytes = frames * Int64(session.project.channels) * Int64(bits / 8)
        guard bytes <= AgentAPI.maxExport else {
            throw APIError.tooLarge(String(format: "That export would be %.1f GB; the limit is 2 GB per response. Export a range (start, end).", Double(bytes) / 1_073_741_824))
        }
        let tmp = FileManager.default.temporaryDirectory.appending(path: "jammer-export-\(UUID().uuidString).\(format.fileExtension)")
        try UploadStore.checkSpace(for: bytes, at: tmp.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Another sample rate for the file than the document's: only the rates the converter is offered at.
        var sampleRate: Double?
        if let v = obj["sampleRate"] {
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), Resampler.rates.contains(n.doubleValue) else {
                throw APIError.badRequest("sampleRate must be one of \(Resampler.rates.map { String(Int($0)) }.joined(separator: ", ")).")
            }
            if format == .opus, n.doubleValue != 48_000 { throw APIError.badRequest("opus is always written at 48000 Hz; leave sampleRate out or give 48000.") }
            sampleRate = n.doubleValue
        }
        let delivery = try await session.export(to: tmp, options: .init(encoding: encoding, range: range, dither: obj["dither"] as? Bool ?? false, encoded: encoded,
                                                                        chapters: obj["chapters"] as? Bool ?? true, loudness: target, tracks: only, sampleRate: sampleRate))
        var headers = ["Content-Disposition": "attachment; filename=\"\(asciiName(session.name)).\(format.fileExtension)\""]
        if let d = delivery, let target {
            // What the file measures when decoded again, and what was added before the encoder to get there.
            headers["X-Jammer-Target-LUFS"] = String(format: "%.1f", target.integrated)
            headers["X-Jammer-Compensated-DB"] = String(format: "%.2f", d.compensatedDB)
            headers["X-Jammer-Limited-By-Peak"] = d.limitedByPeak ? "1" : "0"
            if let l = d.loudness {
                headers["X-Jammer-Loudness"] = String(format: "%.2f", l)
                headers["X-Jammer-Loudness-From"] = "file"
            } else {
                headers["X-Jammer-Loudness-From"] = "mix"
            }
            if let tp = d.truePeak { headers["X-Jammer-True-Peak"] = String(format: "%.2f", tp) }
        }
        if format == .wav { headers["X-Jammer-Dither"] = session.lastExportDither }
        headers["X-Jammer-Sample-Rate"] = String(Int(session.lastExportSampleRate))
        let data = try Data(contentsOf: tmp, options: .mappedIfSafe)
        let types: [ExportFormat: String] = [.wav: "audio/wav", .aiff: "audio/aiff", .flac: "audio/flac", .alac: "audio/mp4", .aac: "audio/mp4", .opus: "audio/ogg", .mp3: "audio/mpeg"]
        return Response(status: 200, contentType: types[format] ?? "application/octet-stream", body: data, extraHeaders: headers)
    }
}
