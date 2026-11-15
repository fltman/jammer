import Foundation
import JammerCore

/// "Send to Flimmer": the sound of a film that came in through FCPXML goes back as new takes
/// (or as one mix). Everything Jämmer says to Flimmer is in this file, after Flimmer's API
/// sketch (SEND-TO-FLIMMER-API.md, v1): uploads, then one plan, dry run first.
/// Nothing is overwritten in Flimmer, and the whole plan is one undo step there.
public enum FlimmerSend {
    public enum Mode: String, Sendable { case takes, mix }

    /// JSON for the plan (objects too, which the step values don't have).
    public indirect enum J: Sendable, Equatable {
        case number(Double), string(String), bool(Bool), array([J]), object([String: J])
        public var any: Any {
            switch self {
            case .number(let v): v
            case .string(let v): v
            case .bool(let v): v
            case .array(let v): v.map(\.any)
            case .object(let v): v.mapValues(\.any)
            }
        }
    }

    /// One HTTP exchange. The app uses URLSession; the tests a pretend Flimmer.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public struct Failure: Error, LocalizedError, Equatable {
        public var code: String
        public var reason: String?
        public var message: String
        public init(_ code: String, _ message: String, reason: String? = nil) {
            self.code = code
            self.reason = reason
            self.message = message
        }
        public var errorDescription: String? { message }
    }

    /// One file that goes to Flimmer and its line in the plan.
    public struct Item: Sendable, Equatable {
        public enum Kind: String, Sendable { case take, new, mix }
        public var kind: Kind
        /// What the user sees: the clip's source name.
        public var name: String
        public var clipId: String?
        public var range: Range<Frame>
        /// The document reduced to what this file is rendered from.
        public var render: Project
        /// Body fields besides kind and uploadId.
        public var fields: [String: J]
        /// The original clip's file is mono: the take goes back mono unless the work here made it stereo.
        public var monoSource = false
    }

    // MARK: From the document to the plan

    /// The items of a plan, in the order they are sent. Throws when there is nowhere to send to.
    public static func items(_ project: Project, plan: FlimmerReturn.Plan, mode: Mode) -> [Item] {
        func name(_ clip: Clip?) -> String { clip.flatMap { project.source($0.sourceID)?.name } ?? "Clip" }
        func r6(_ v: Double) -> Double { (v * 1_000_000).rounded() / 1_000_000 }
        if mode == .mix {
            let p = FlimmerReturn.mixProject(project)
            return [Item(kind: .mix, name: "Jämmer mix", clipId: nil, range: 0..<p.length, render: p, fields: ["name": .string("Jämmer mix")])]
        }
        var out: [Item] = []
        for t in plan.takes {
            let first = project.tracks.flatMap(\.clips).filter { $0.origin?.clipId == t.clipId }.min { $0.start < $1.start }
            var fields: [String: J] = ["clipId": .string(t.clipId)]
            // The take starts where the clip is seen to start; a position only when that has moved.
            if t.movedBy != 0 {
                let moved = project.seconds(t.movedBy)
                if t.linkedShotId != nil, let rel = first?.origin?.clipRelativeOffset {
                    fields["position"] = .object(["clipRelativeOffset": .number(r6(rel + moved))])
                } else {
                    fields["position"] = .object(["timelineOffset": .number(r6(project.seconds(t.range.lowerBound)))])
                }
            }
            // The name and "mono" are about the file the clip came in with, whatever it plays from now
            // (a repaired clip plays from a new file with a name of its own).
            let original = (first?.origin?.snapshot?.sourceID).flatMap { project.source($0) } ?? first.flatMap { project.source($0.sourceID) }
            let title = original?.name ?? name(first)
            fields["name"] = .string(title)
            out.append(Item(kind: .take, name: title, clipId: t.clipId, range: t.range,
                            render: FlimmerReturn.soloProject(project, clipId: t.clipId), fields: fields, monoSource: original?.info.channels == 1))
        }
        for n in plan.new {
            let clip = project.tracks.flatMap(\.clips).first { $0.id == n.clip }
            var fields: [String: J] = ["name": .string(name(clip)), "position": .object(["timelineOffset": .number(r6(project.seconds(n.range.lowerBound)))])]
            if let id = n.trackId { fields["trackId"] = .string(id) }
            out.append(Item(kind: .new, name: name(clip), clipId: nil, range: n.range, render: FlimmerReturn.soloProject(project, clip: n.clip), fields: fields,
                            monoSource: clip.flatMap { project.source($0.sourceID) }?.info.channels == 1))
        }
        return out
    }

    /// The body of `POST /api/v1/audio/sibling-plan`.
    public static func body(_ project: Project, plan: FlimmerReturn.Plan, mode: Mode, items: [Item], uploads: [String], dryRun: Bool) -> [String: J] {
        let record = project.imported
        var body: [String: J] = ["projectId": .string(record?.projectId ?? ""), "storyId": .string(record?.storyId ?? ""),
                                         "exportVersion": .number(Double(record?.exportVersion ?? "") ?? 0), "mode": .string(mode.rawValue), "dryRun": .bool(dryRun)]
        body["items"] = .array(zip(items, uploads).map { item, upload in
            var d = item.fields
            d["kind"] = .string(item.kind.rawValue)
            d["uploadId"] = .string(upload)
            return .object(d)
        })
        if mode == .takes {
            // Flimmer's volume is 0…1: what a track has above 0 dB is in its files instead.
            body["trackSettings"] = .array(plan.tracks.map {
                .object(["trackId": .string($0.trackId), "volume": .number((min(1, pow(10, $0.gainDB / 20)) * 10_000).rounded() / 10_000), "muted": .bool($0.muted)])
            })
            var listed: [J] = []
            for t in plan.takes where t.changedTrack {
                let names = project.tracks.filter { t.tracks.contains($0.id) }.map(\.name).joined(separator: ", ")
                listed.append(.object(["kind": .string("trackChange"), "clipId": .string(t.clipId), "note": .string("moved to track \(names) in Jämmer")]))
            }
            listed += plan.missing.map { .object(["kind": .string("deleted"), "clipId": .string($0)]) }
            listed += plan.videoChanged.map { .object(["kind": .string("videoAudio"), "shotClipId": .string($0), "note": .string("changed in Jämmer, not sent in this version")]) }
            body["listed"] = .array(listed)
        }
        return body
    }

    /// Why the document can't be sent at all, before anything is rendered. Nil: it can.
    public static func refusal(_ project: Project) -> Failure? {
        guard let record = project.imported, record.app == "flimmer" else {
            return Failure("not_from_flimmer", "This document didn't come from Flimmer, so there is nothing to send back to.")
        }
        guard let p = record.projectId, !p.isEmpty, let s = record.storyId, !s.isEmpty else {
            return Failure("needs_new_export", "This film was exported from an older Flimmer, and the file doesn't say which project it belongs to. Export it again from Flimmer and import that file; then it can be sent back.")
        }
        return nil
    }

    // MARK: What the user reads

    /// Jämmer's own list of what would be sent, for the sheet shown before anything goes.
    public static func lines(_ project: Project, plan: FlimmerReturn.Plan, mode: Mode, items: [Item], resampledTo: Double? = nil) -> [String] {
        func t(_ f: Frame) -> String { String(format: "%.2f s", project.seconds(f)) }
        var out: [String] = []
        if mode == .mix {
            out.append("The whole mix (\(t(project.length))) as one new clip on a new track, \"Jämmer mix\". The video clips' own sound is left out: Flimmer plays it itself.")
        } else {
            for (item, take) in zip(items, plan.takes) {
                var s = "New take of \(item.name), \(t(Frame(item.range.count)))"
                if take.pieces > 1 { s += ", from \(take.pieces) pieces" }
                if take.movedBy != 0 { s += String(format: ", moved %+.2f s", project.seconds(take.movedBy)) }
                if take.changedTrack { s += " (stays on its track in Flimmer)" }
                out.append(s + ".")
            }
            for n in plan.new { out.append("New clip on \(n.trackId == nil ? "a new track, \"\(n.trackName)\"" : n.trackName) at \(t(n.range.lowerBound)), \(t(Frame(n.range.count))).") }
            for c in plan.tracks { out.append(String(format: "Track %@: %@%@.", c.name, c.gainDB > 0 ? "level 0 dB (the rest is in its files)" : String(format: "level %.1f dB", c.gainDB), c.muted ? ", muted" : ", not muted")) }
            if !plan.unchanged.isEmpty { out.append("\(plan.unchanged.count) clip\(plan.unchanged.count == 1 ? " is" : "s are") unchanged and not sent.") }
            for _ in plan.missing { out.append("A clip that came from Flimmer is no longer in this document. Nothing happens to it in Flimmer.") }
            for _ in plan.videoChanged { out.append("A video clip's own sound was changed here. That is not sent in this version.") }
        }
        if plan.lengthChangedBy != 0 {
            out.append(String(format: "The document is %.2f s %@ than the film it came from: sound after a cut no longer sits under its picture.",
                              abs(project.seconds(plan.lengthChangedBy)), plan.lengthChangedBy < 0 ? "shorter" : "longer"))
        }
        if let r = resampledTo { out.append(String(format: "The document is %.0f Hz; the files are converted to %.0f Hz, which is what Flimmer takes.", project.sampleRate, r)) }
        return out
    }

    /// Flimmer's dry-run answer as lines: what it would create and mute, and above all overlaps.
    public static func lines(answer: [String: Any], items: [Item]) -> [String] {
        var out: [String] = []
        for o in (answer["overlaps"] as? [[String: Any]]) ?? [] {
            let i = (o["item"] as? NSNumber)?.intValue ?? -1
            let name = items.indices.contains(i) ? items[i].name : "A clip"
            out.append(String(format: "Warning: %@ would overlap the next clip on its track by %.2f s.", name, (o["seconds"] as? NSNumber)?.doubleValue ?? 0))
        }
        let created = ((answer["wouldCreate"] ?? answer["created"]) as? [Any])?.count ?? 0
        let muted = ((answer["wouldMute"] ?? answer["muted"]) as? [Any])?.count ?? 0
        let done = answer["created"] != nil
        if created > 0 || muted > 0 {
            out.append("Flimmer \(done ? "made" : "would make") \(created) new clip\(created == 1 ? "" : "s")" + (muted > 0 ? " and mute\(done ? "d" : "") \(muted) original\(muted == 1 ? "" : "s") (kept, not changed)." : "."))
        }
        out += ((answer["warnings"] as? [String]) ?? []).map { "Flimmer: \($0)" }
        return out
    }

    /// An error from Flimmer in words the user can act on, naming the clip when it is about one.
    public static func explain(status: Int, error: [String: Any], items: [Item]) -> Failure {
        let code = error["code"] as? String ?? "error", reason = error["reason"] as? String
        let index = (error["item"] as? NSNumber)?.intValue
        let clip = index.flatMap { items.indices.contains($0) ? "\"\(items[$0].name)\"" : nil } ?? "a clip"
        let message: String
        switch (status, reason ?? code) {
        case (403, _): message = "You're signed in to Flimmer as a viewer of this project. Only an editor or the owner can receive sound from Jämmer."
        case (409, _): message = "Flimmer has nobody signed in or no project open. Open the film's project in Flimmer and send again."
        case (_, "wrong_project"): message = "Another project is open in Flimmer than the one this film came from. Open that project in Flimmer and send again."
        case (_, "wrong_story"): message = "The story this film was exported from isn't in the project that is open in Flimmer."
        case (_, "unknown_clip"): message = "Flimmer has no clip for \(clip) in this project any more. Export the film again from Flimmer."
        case (_, "clip_deleted"): message = "\(clip) was removed in Flimmer after the film was exported, so there is nothing to make a take of."
        case (_, "unknown_track"): message = "The track \(clip) should go on doesn't exist in Flimmer any more."
        case (_, "locked_track"): message = "The track of \(clip) is locked in Flimmer. Unlock it there and send again."
        case (_, "duplicate_clip"): message = "Two files were sent for \(clip). That is a fault in Jämmer; please report it."
        case (_, "wrong_position_kind"): message = "\(clip) has changed between linked to a shot and free in Flimmer since the export. Export the film again from Flimmer."
        case (_, "unknown_upload"), (_, "upload_open"), (_, "upload_used"): message = "Flimmer no longer has the file for \(clip) (uploads are kept for an hour). Send again."
        case (_, "nothing_to_change"): message = "There is nothing to send: no clip has changed since the film came in."
        case (413, _): message = "A file is larger than Flimmer accepts."
        case (415, _): message = "Flimmer didn't accept the file format (it takes WAV, mono or stereo, at 44.1 or 48 kHz)."
        case (507, _): message = "The disk Flimmer writes to is too full."
        case (404, _): message = "This Flimmer can't receive sound from Jämmer yet. Update Flimmer."
        default: message = "Flimmer answered: \(error["message"] as? String ?? "error \(status)")"
        }
        return Failure(code, message, reason: reason)
    }

    // MARK: Talking to Flimmer

    public struct Client: Sendable {
        public var base: URL
        public var transport: Transport
        /// Seconds between job polls (the sketch says 2).
        public var pollInterval: Double

        public init(base: URL, transport: @escaping Transport, pollInterval: Double = 2) {
            self.base = base
            self.transport = transport
            self.pollInterval = pollInterval
        }

        func call(_ method: String, _ path: String, body: Data? = nil, contentType: String? = nil, items: [Item] = []) async throws -> (Int, [String: Any]) {
            var r = URLRequest(url: URL(string: base.absoluteString + path)!)
            r.httpMethod = method
            r.httpBody = body
            if method != "GET" {
                r.setValue("1", forHTTPHeaderField: "X-Flimmer-Agent")
                r.setValue("jammer", forHTTPHeaderField: "X-Sibling")
            }
            if let contentType { r.setValue(contentType, forHTTPHeaderField: "Content-Type") }
            let (data, response): (Data, HTTPURLResponse)
            do { (data, response) = try await transport(r) } catch { throw Failure("unreachable", "Flimmer stopped answering.") }
            let object = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
            guard (200..<300).contains(response.statusCode) else {
                throw FlimmerSend.explain(status: response.statusCode, error: object["error"] as? [String: Any] ?? [:], items: items)
            }
            return (response.statusCode, object)
        }

        public struct Limits: Sendable, Equatable {
            /// 24 bits when Flimmer says it takes them, else 16 (with dither).
            public var bitDepth: Int
            public var maxBytes: Int64
            public var maxChunkBytes: Int
        }

        /// What Flimmer's `GET /api/v1/operations` says about uploads.
        public func limits() async throws -> Limits {
            let (_, ops) = try await call("GET", "/api/v1/operations")
            let u = ops["uploads"] as? [String: Any] ?? [:]
            let depths = (u["wavBitDepths"] as? [NSNumber])?.map(\.intValue) ?? [16]
            return Limits(bitDepth: depths.contains(24) ? 24 : 16, maxBytes: (u["maxBytes"] as? NSNumber)?.int64Value ?? 2 << 30,
                          maxChunkBytes: max(1, (u["maxChunkBytes"] as? NSNumber)?.intValue ?? 8 << 20))
        }

        /// Sends a file from disk: in one call when it fits in a chunk, else opened, appended a
        /// chunk at a time (never the whole file in memory) and completed. A cancelled or failed
        /// upload is removed from Flimmer before the error goes on.
        public func upload(file: URL, name: String, limits: Limits) async throws -> String {
            let q = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._"))) ?? "clip.wav"
            let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? 0
            func id(_ answer: [String: Any]) throws -> String {
                guard let id = (answer["upload"] as? [String: Any])?["id"] as? String else { throw Failure("bad_answer", "Flimmer's answer to an upload couldn't be read.") }
                return id
            }
            if size <= Int64(limits.maxChunkBytes) {
                return try id(try await call("POST", "/api/v1/uploads?name=\(q)", body: try Data(contentsOf: file), contentType: "audio/wav").1)
            }
            let upload = try id(try await call("POST", "/api/v1/uploads?name=\(q)&bytes=\(size)").1)
            do {
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                var offset: Int64 = 0
                while offset < size {
                    try Task.checkCancellation()
                    guard let chunk = try handle.read(upToCount: limits.maxChunkBytes), !chunk.isEmpty else { break }
                    _ = try await call("PUT", "/api/v1/uploads/\(upload)?offset=\(offset)", body: chunk, contentType: "application/octet-stream")
                    offset += Int64(chunk.count)
                }
                _ = try await call("POST", "/api/v1/uploads/\(upload)/complete")
                return upload
            } catch {
                await remove(upload: upload)
                throw error
            }
        }

        public func remove(upload id: String) async { _ = try? await call("DELETE", "/api/v1/uploads/\(id)") }

        /// Dry run: Flimmer's answer at once. For real: the finished job's result.
        public func plan(_ body: [String: J], items: [Item]) async throws -> [String: Any] {
            let data = try JSONSerialization.data(withJSONObject: J.object(body).any, options: [.sortedKeys])
            let (status, answer) = try await call("POST", "/api/v1/audio/sibling-plan", body: data, contentType: "application/json", items: items)
            guard status == 202, let id = (answer["job"] as? [String: Any])?["id"] as? String else { return answer }
            while true {
                let (_, j) = try await call("GET", "/api/v1/jobs/\(id)", items: items)
                let job = j["job"] as? [String: Any] ?? [:]
                switch job["status"] as? String {
                case "done": return job["result"] as? [String: Any] ?? [:]
                case "failed":
                    throw FlimmerSend.explain(status: 422, error: job["error"] as? [String: Any] ?? [:], items: items)
                case "cancelled": throw Failure("cancelled", "The job was cancelled in Flimmer; nothing was changed there.")
                default: try await Task.sleep(for: .seconds(pollInterval))
                }
            }
        }
    }

    /// Finds the running Flimmer: 9002 first, then 9201–9219; `app.name` must be exactly Flimmer,
    /// and a debug Jämmer pairs only with a debug Flimmer (SIBLINGS.md §1–2).
    public static func find(transport: @escaping Transport, debug: Bool) async -> URL? {
        for port in [9002] + Array(9201...9219) {
            var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/status")!)
            r.timeoutInterval = port == 9002 ? 1 : 0.3
            guard let (data, response) = try? await transport(r), response.statusCode == 200,
                  let app = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["app"] as? [String: Any],
                  app["name"] as? String == "Flimmer" else { continue }
            let bundle = app["bundleID"] as? String ?? ""
            if bundle.hasSuffix(".debug") == debug { return URL(string: "http://127.0.0.1:\(port)") }
        }
        return nil
    }

    // MARK: The whole exchange

    /// Uploaded and checked by Flimmer, nothing changed yet: what the sheet shows.
    public struct Prepared: Sendable {
        public var mode: Mode
        public var plan: FlimmerReturn.Plan
        public var items: [Item]
        public var uploads: [String]
        public var lines: [String]
        public var flimmerLines: [String]
        public var body: [String: J]
    }

    /// One item rendered to a WAV file at a bit depth and sample rate Flimmer takes.
    public struct Rendered: Sendable {
        public var file: URL
        public var channels: Int
        public init(file: URL, channels: Int) {
            self.file = file
            self.channels = channels
        }
    }
    public typealias Render = @Sendable (_ item: Item, _ bitDepth: Int, _ sampleRate: Double) async throws -> Rendered

    /// The rate the files go at: the document's when Flimmer takes it, else 48 kHz.
    public static func sendRate(_ project: Project) -> Double { [44_100, 48_000].contains(project.sampleRate) ? project.sampleRate : 48_000 }

    /// Renders and uploads every file, then asks Flimmer for a dry run. Uploads are removed again if anything fails.
    public static func prepare(_ project: Project, mode: Mode, client: Client, render: Render, progress: @Sendable (Double) -> Void = { _ in }) async throws -> Prepared {
        if let no = refusal(project) { throw no }
        let plan = (try? FlimmerReturn.plan(project)) ?? .init()
        let items = self.items(project, plan: plan, mode: mode)
        guard !items.isEmpty || !plan.tracks.isEmpty else {
            throw Failure("nothing_to_change", "There is nothing to send: no clip or track has changed since the film came in.")
        }
        let limits = try await client.limits()
        let rate = sendRate(project)
        var uploads: [String] = [], files: [Rendered] = [], notes: [String] = []
        // Each file sits in a folder of its own (see wavFile); the folder goes with it.
        defer { for f in files { try? FileManager.default.removeItem(at: f.file.deletingLastPathComponent()) } }
        do {
            // Every file first, so that one that is too large is said before anything is uploaded.
            for (i, item) in items.enumerated() {
                try Task.checkCancellation()
                let r = try await render(item, limits.bitDepth, rate)
                files.append(r)
                let size = ((try? FileManager.default.attributesOfItem(atPath: r.file.path))?[.size] as? NSNumber)?.int64Value ?? 0
                if size > limits.maxBytes {
                    throw Failure("too_large", String(format: "%@ would be %.1f GB as a file, and Flimmer takes at most %.1f GB. Send a shorter stretch, or the clips as takes instead of the whole mix.",
                                                      item.kind == .mix ? "The mix" : "\"\(item.name)\"", Double(size) / 1_073_741_824, Double(limits.maxBytes) / 1_073_741_824))
                }
                if item.monoSource, r.channels == 2 {
                    notes.append("\(item.name) was mono and comes back in stereo: what was done to it here made the two sides differ.")
                }
                progress(0.5 * Double(i + 1) / Double(items.count))
            }
            for (i, (item, r)) in zip(items, files).enumerated() {
                try Task.checkCancellation()
                uploads.append(try await client.upload(file: r.file, name: "\(item.name)-jammer.wav", limits: limits))
                progress(0.5 + 0.5 * Double(i + 1) / Double(items.count + 1))
            }
            let dry = body(project, plan: plan, mode: mode, items: items, uploads: uploads, dryRun: true)
            let answer = try await client.plan(dry, items: items)
            progress(1)
            return Prepared(mode: mode, plan: plan, items: items, uploads: uploads,
                            lines: lines(project, plan: plan, mode: mode, items: items, resampledTo: rate == project.sampleRate ? nil : rate) + notes,
                            flimmerLines: lines(answer: answer, items: items),
                            body: body(project, plan: plan, mode: mode, items: items, uploads: uploads, dryRun: false))
        } catch {
            for id in uploads { await client.remove(upload: id) }
            throw error
        }
    }

    /// For real, after the user has seen the dry run. One undo step in Flimmer.
    public static func send(_ prepared: Prepared, client: Client) async throws -> [String] {
        lines(answer: try await client.plan(prepared.body, items: prepared.items), items: prepared.items)
    }

    /// The user closed the sheet without sending.
    public static func cancel(_ prepared: Prepared, client: Client) async {
        for id in prepared.uploads { await client.remove(upload: id) }
    }

    /// `range` of a compiled plan as a WAV file: 24 bits, or 16 with dither; converted to
    /// `sampleRate` when the document is at another rate. With `monoIfSame`, a stereo render
    /// whose two sides are the same sample for sample is written as mono.
    public static func wavFile(_ plan: RenderPlan, range: Range<Frame>, bitDepth: Int, sampleRate: Double, monoIfSame: Bool = false, scratch: URL) throws -> Rendered {
        let dir = scratch.appending(path: "flimmer-send-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var mono = plan.channels == 1
        if monoIfSame, plan.channels == 2 {
            mono = true
            plan.render(range) { b in
                guard mono else { return }
                var i = 0
                while i + 1 < b.count { if b[i] != b[i + 1] { mono = false; break }; i += 2 }
            }
        }
        let channels = mono ? 1 : plan.channels
        func write(_ plan: RenderPlan, _ range: Range<Frame>, to url: URL, float: Bool, left: Bool) throws {
            let w = try WAVWriter(url: url, options: .init(encoding: float ? .float32 : (bitDepth == 24 ? .int24 : .int16), channels: left ? 1 : plan.channels,
                                                          sampleRate: plan.sampleRate, dither: !float && bitDepth == 16))
            var one: [Float] = []
            try plan.render(range) { b in
                guard left else { try w.write(b); return }
                one.removeAll(keepingCapacity: true)
                var i = 0
                while i < b.count { one.append(b[i]); i += plan.channels }
                try one.withUnsafeBufferPointer { try w.write($0) }
            }
            try w.finish()
        }
        let out = dir.appending(path: "out.wav")
        let takeLeft = mono && plan.channels > 1
        if plan.sampleRate == sampleRate {
            try write(plan, range, to: out, float: false, left: takeLeft)
        } else {
            // Through a float file, so the conversion works on the full signal and the rounding happens once.
            let full = dir.appending(path: "full.wav")
            try write(plan, range, to: full, float: true, left: takeLeft)
            let converted = try AudioImporter.importFile(full, sampleRate: sampleRate, mediaFolder: dir)
            var p = Project(source: converted.source)
            p.channels = channels
            try write(PlanCompiler.compile(p, pool: SourcePool()), 0..<p.length, to: out, float: false, left: false)
            try? FileManager.default.removeItem(at: full)
        }
        return Rendered(file: out, channels: channels)
    }
}
