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

    public struct Failure: Error, LocalizedError, Equatable, KeyedFailure {
        public var code: String
        public var reason: String?
        public var message: String
        public var keyed: KeyedMessage?
        public init(_ code: String, _ message: String, reason: String? = nil) {
            self.code = code
            self.reason = reason
            self.message = message
        }
        public init(_ code: String, _ said: Said, reason: String? = nil) {
            self.init(code, said.text, reason: reason)
            keyed = said.keyed
        }
        public var errorDescription: String? { message }
    }

    /// One file that goes to Flimmer and its line in the plan.
    public struct Item: Sendable, Equatable {
        public enum Kind: String, Sendable { case take, new, mix }
        /// The key it is remembered by after a send (`ImportRecord.sentClips`): the Flimmer clip it is a take of,
        /// or "clip:<Jämmer clip id>" for a new clip; nil for the mix.
        public var sentKey: String? { kind == .take ? clipId : (kind == .new ? localClip.map { "clip:\($0.uuidString)" } : nil) }
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
        /// The Jämmer clip a new item is (nil for takes and the mix).
        public var localClip: UUID? = nil
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
                            monoSource: clip.flatMap { project.source($0.sourceID) }?.info.channels == 1, localClip: n.clip))
        }
        return out
    }

    /// The names the plan may carry, as agreed with Flimmer (SEND-TO-FLIMMER-API.md). Flimmer refuses a
    /// name it doesn't know (SIBLINGS.md §3), so Jämmer treats this as a closed list and checks its own
    /// plan against it before anything is uploaded or sent: a new field is added here, on purpose.
    public static let planFields: Set<String> = ["projectId", "storyId", "exportVersion", "mode", "dryRun", "items", "trackSettings", "listed"]
    public static let itemFields: Set<String> = ["kind", "clipId", "uploadId", "position", "name", "trackId"]
    public static let positionFields: Set<String> = ["clipRelativeOffset", "timelineOffset"]
    public static let trackSettingFields: Set<String> = ["trackId", "volume", "muted"]
    public static let listedFields: Set<String> = ["kind", "clipId", "shotClipId", "note"]

    /// Every name in `body` that isn't one of the agreed ones, with where it stands ("items[1].gain").
    public static func strangers(in body: [String: J]) -> [String] {
        var found = body.keys.filter { !planFields.contains($0) }
        func rows(_ key: String, _ allowed: Set<String>) {
            guard case .array(let list)? = body[key] else { return }
            for (i, row) in list.enumerated() {
                guard case .object(let d) = row else { continue }
                found += d.keys.filter { !allowed.contains($0) }.map { "\(key)[\(i)].\($0)" }
                if key == "items", case .object(let p)? = d["position"] {
                    found += p.keys.filter { !positionFields.contains($0) }.map { "items[\(i)].position.\($0)" }
                }
            }
        }
        rows("items", itemFields); rows("trackSettings", trackSettingFields); rows("listed", listedFields)
        return found.sorted()
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
            return Failure("not_from_flimmer", Said("error.flimmer.document_didn_t_come", "This document didn't come from Flimmer, so there is nothing to send back to."))
        }
        guard let p = record.projectId, !p.isEmpty, let s = record.storyId, !s.isEmpty else {
            return Failure("needs_new_export", Said("error.flimmer.film_was_exported_from", "This film was exported from an older Flimmer, and the file doesn't say which project it belongs to. Export it again from Flimmer and import that file; then it can be sent back."))
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
    /// Flimmer's answer in lines: warnings first (as many as `warnings(answer:)` counts), then what it made or
    /// would make, then notes. Take groups (SEND-TO-FLIMMER-API.md, "Take groups", 2026-11-19): the muted list
    /// holds the originals first and then every other heard member of their groups; each of those is said by
    /// itself ("Also mutes"), never counted as an original. An earlier take of the same line in this send
    /// (`active: false`) and an overlap with an older take of the same line (`sameTakeGroup`) are notes, not faults.
    /// `sentBefore`: takes this document sent before (`ImportRecord.sentClips`), by their Flimmer id, with the clip's name.
    public static func lines(answer: [String: Any], items: [Item], sentBefore: [String: String] = [:]) -> [String] {
        var out: [String] = [], notes: [String] = []
        func name(ofClip id: String) -> String {
            if let n = items.first(where: { $0.clipId == id })?.name { return n }
            if let n = sentBefore[id] { return "the take of \(n) sent before" }
            return "a take in Flimmer (\(id.prefix(8)))"
        }
        for o in (answer["overlaps"] as? [[String: Any]]) ?? [] {
            let i = (o["item"] as? NSNumber)?.intValue ?? -1
            let clip = items.indices.contains(i) ? items[i].name : "A clip"
            let seconds = (o["seconds"] as? NSNumber)?.doubleValue ?? 0
            if o["sameTakeGroup"] as? Bool == true {
                notes.append(String(format: "Note: an older take of %@ stays on its track, muted; the new one overlaps it by %.2f s.", clip, seconds))
            } else {
                out.append(String(format: "Warning: %@ would overlap the next clip on its track by %.2f s.", clip, seconds))
            }
        }
        let createdList = ((answer["wouldCreate"] ?? answer["created"]) as? [[String: Any]]) ?? []
        let mutedIds = ((answer["wouldMute"] ?? answer["muted"]) as? [Any])?.compactMap { $0 as? String } ?? []
        let done = answer["created"] != nil
        // The originals are the clips the takes are of; whatever else is muted is another member of a take group.
        let originals = Set(createdList.compactMap { $0["takeOf"] as? String } + items.filter { $0.kind == .take }.compactMap(\.clipId))
        let mutedOriginals = mutedIds.filter { originals.contains($0) }.count
        let alsoMuted = mutedIds.filter { !originals.contains($0) }
        let created = createdList.count
        if created > 0 || !mutedIds.isEmpty {
            out.append("Flimmer \(done ? "made" : "would make") \(created) new clip\(created == 1 ? "" : "s")"
                       + (mutedOriginals > 0 ? " and mute\(done ? "d" : "") \(mutedOriginals) original\(mutedOriginals == 1 ? "" : "s") (kept, not changed)." : "."))
        }
        for id in alsoMuted { out.append("Also mute\(done ? "d" : "s"): \(name(ofClip: id)) (kept, not changed).") }
        for c in createdList where c["active"] as? Bool == false {
            let i = (c["item"] as? NSNumber)?.intValue ?? -1
            notes.append("Note: \(items.indices.contains(i) ? items[i].name : "a take") is an earlier take of the same line in this send; it is kept, muted, and the later one is heard.")
        }
        out += notes
        out += ((answer["warnings"] as? [String]) ?? []).map { "Flimmer: \($0)" }
        // After an undo or redo in Flimmer that met someone else's change (result.history): Flimmer's own words.
        if let h = answer["history"] as? [String: Any], let state = h["state"] as? String, state.hasSuffix("Failed") {
            out.append("Flimmer: \(h["message"] as? String ?? (state == "undoFailed" ? "the undo couldn't be done" : "the redo couldn't be done")) (\(h["reason"] as? String ?? state)).")
        }
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

        /// `uncut`: the request runs in a task of its own, so a cancel can't cut it off halfway (the plan and
        /// its polls: a cut request would leave Flimmer's job running with nobody to cancel it, as the live
        /// test J2 found on 2026-11-19). The caller looks at `Task.isCancelled` once the answer is in.
        func call(_ method: String, _ path: String, body: Data? = nil, contentType: String? = nil, items: [Item] = [], uncut: Bool = false) async throws -> (Int, [String: Any]) {
            var r = URLRequest(url: URL(string: base.absoluteString + path)!)
            r.httpMethod = method
            r.httpBody = body
            if method != "GET" {
                r.setValue("1", forHTTPHeaderField: "X-Flimmer-Agent")
                r.setValue("jammer", forHTTPHeaderField: "X-Sibling")
            }
            if let contentType { r.setValue(contentType, forHTTPHeaderField: "Content-Type") }
            let (data, response): (Data, HTTPURLResponse)
            do {
                let send = transport, request = r
                (data, response) = uncut ? try await Task.detached { try await send(request) }.value : try await transport(r)
            } catch { throw Failure("unreachable", Said("error.flimmer.flimmer_stopped_answering", "Flimmer stopped answering.")) }
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
                guard let id = (answer["upload"] as? [String: Any])?["id"] as? String else { throw Failure("bad_answer", Said("error.flimmer.flimmer_s_answer_upload", "Flimmer's answer to an upload couldn't be read.")) }
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
            // Nothing is sent that Flimmer hasn't agreed to take: it would refuse the whole plan.
            let strange = FlimmerSend.strangers(in: body)
            guard strange.isEmpty else { throw Failure("bad_request", Said("error.flimmer.j_mmer_s_plan", "Jämmer's plan has names Flimmer doesn't take (%@); nothing was sent.", "\(strange.joined(separator: ", "))")) }
            let data = try JSONSerialization.data(withJSONObject: J.object(body).any, options: [.sortedKeys])
            // A cancel can come at any moment, also while the plan or a poll is on its way. Those requests are
            // never cut off: once Flimmer has a job, a cancel reaches it (DELETE), and a job that was already
            // done is taken as done, so that what Flimmer made is said and remembered rather than lost (J2,
            // 2026-11-19: the plan was done 0.35 s after Send, before the DELETE came, and Flimmer said 409).
            let (status, answer) = try await call("POST", "/api/v1/audio/sibling-plan", body: data, contentType: "application/json", items: items, uncut: true)
            guard status == 202, let id = (answer["job"] as? [String: Any])?["id"] as? String else { return answer }
            while true {
                if Task.isCancelled { return try await canceled(job: id, items: items) }
                let (_, j) = try await call("GET", "/api/v1/jobs/\(id)", items: items, uncut: true)
                let job = j["job"] as? [String: Any] ?? [:]
                switch FlimmerSend.jobState(job["status"] as? String) {
                case .done: return job["result"] as? [String: Any] ?? [:]
                case .failed: throw FlimmerSend.explain(status: 422, error: job["error"] as? [String: Any] ?? [:], items: items)
                case .canceled: throw Failure("canceled", Said("error.flimmer.job_was_canceled_flimmer", "The job was canceled in Flimmer; nothing was changed there."))
                case .unknown(let word):
                    throw Failure("unknown_status", Said("error.flimmer.flimmer_s_job_has", "Flimmer's job has the status \"%@\", which Jämmer doesn't know, so it has stopped waiting for it. Look in Flimmer for whether the change was made.", "\(word)"))
                case .waiting:
                    // Canceled here (the sheet closed while sending): Flimmer's job is canceled too, as its API asks
                    // (DELETE /api/v1/jobs/{id}); it then removes what it had made and mutes nothing.
                    do { try await Task.sleep(for: .seconds(pollInterval)) } catch { return try await canceled(job: id, items: items) }
                }
            }
        }

        /// Cancels Flimmer's job (DELETE, from a task of its own: a request made inside the canceled one would end
        /// before it left) and throws CancellationError. When Flimmer refuses because the job had already finished
        /// (409), the job is read once more, and a done job's result is returned: the change is made there, and
        /// Jämmer says so and remembers its clips instead of acting as if nothing had happened.
        func canceled(job id: String, items: [Item]) async throws -> [String: Any] {
            let client = self
            let accepted = await Task.detached { (try? await client.call("DELETE", "/api/v1/jobs/\(id)")) != nil }.value
            if !accepted {
                let polled = try? await call("GET", "/api/v1/jobs/\(id)", items: items, uncut: true)
                if let job = polled?.1["job"] as? [String: Any], FlimmerSend.jobState(job["status"] as? String) == .done {
                    return job["result"] as? [String: Any] ?? [:]
                }
            }
            throw CancellationError()
        }
    }

    /// What a sibling's job status means to the one waiting for it (the-apps/SIBLINGS.md §2): the statuses
    /// are queued, running, done, failed and canceled; "cancelled" is taken as canceled (it was written so
    /// until 2026-11-17); and anything else ends the wait with an error, because a status nobody knows
    /// must not be waited on for ever.
    public enum JobState: Equatable { case waiting, done, failed, canceled, unknown(String) }
    public static func jobState(_ status: String?) -> JobState {
        switch status {
        case "queued", "running": .waiting
        case "done": .done
        case "failed": .failed
        case "canceled", "cancelled": .canceled   // not a shown text: a sibling's job word, in both spellings
        default: .unknown(status ?? "")
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
            // A guest copy (…debug.guest) is a debug build too; a release Jämmer never pairs with either.
            if AgentAPI.isDebugBundle(bundle) == debug { return URL(string: "http://127.0.0.1:\(port)") }
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
        /// How many of `flimmerLines`, from the first, are warnings. (Said as a number: a window must not
        /// tell a warning by its words, which are another language's tomorrow.)
        public var flimmerWarnings = 0
        public var body: [String: J]
        /// Each item's transcript, by item, sent after the plan (`sendAll`).
        public var transcripts: [Int: [String: J]] = [:]
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
            throw Failure("nothing_to_change", Said("error.flimmer.there_nothing_send_clip", "There is nothing to send: no clip or track has changed since the film came in."))
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
            let transcripts = transcriptBodies(project, items: items)
            let said = transcripts.isEmpty ? [] : ["Transcripts of \(transcripts.count) clip\(transcripts.count == 1 ? "" : "s") go after the sound, each on its own (when that box is ticked)."]
            return Prepared(mode: mode, plan: plan, items: items, uploads: uploads,
                            lines: lines(project, plan: plan, mode: mode, items: items, resampledTo: rate == project.sampleRate ? nil : rate) + notes + said,
                            flimmerLines: lines(answer: answer, items: items, sentBefore: sentBefore(project, items: items)),
                            flimmerWarnings: warnings(answer: answer),
                            body: body(project, plan: plan, mode: mode, items: items, uploads: uploads, dryRun: false),
                            transcripts: transcripts)
        } catch {
            for id in uploads { await client.remove(upload: id) }
            throw error
        }
    }

    /// For real, after the user has seen the dry run. One undo step in Flimmer.
    public static func send(_ prepared: Prepared, client: Client) async throws -> [String] {
        try await sendCounting(prepared, client: client).lines
    }
    /// The same, with how many of the lines (from the first) are warnings.
    public static func sendCounting(_ prepared: Prepared, client: Client) async throws -> (lines: [String], warnings: Int) {
        let answer = try await client.plan(prepared.body, items: prepared.items)
        return (lines(answer: answer, items: prepared.items), warnings(answer: answer))
    }
    /// For real, and then the transcripts, each in a PUT of its own: only when the plan succeeded (a failed plan
    /// throws before any is sent), and each answered for itself.
    /// `canceledLate`: canceled after Flimmer had already done the plan. What it made is returned (to be said
    /// and remembered), and no transcript is sent after the cancel.
    public static func sendAll(_ prepared: Prepared, client: Client, transcripts: Bool, replaceEdited: Bool) async throws
        -> (lines: [String], warnings: Int, transcripts: [TranscriptOutcome], created: [Int: String], canceledLate: Bool) {
        let answer = try await client.plan(prepared.body, items: prepared.items)
        let created = createdClips(answer)
        let canceledLate = Task.isCancelled
        var outcomes: [TranscriptOutcome] = []
        if transcripts, !canceledLate, !prepared.transcripts.isEmpty {
            outcomes = await sendTranscripts(prepared.transcripts, created: created, items: prepared.items, replaceEdited: replaceEdited, client: client)
        }
        return (lines(answer: answer, items: prepared.items), warnings(answer: answer), outcomes, created, canceledLate)
    }

    /// The id of the project Flimmer has open, when its status says it (`project.id`, or `projectId`).
    public static func openProject(_ client: Client) async -> String? {
        guard let (_, status) = try? await client.call("GET", "/api/v1/status") else { return nil }
        if let p = status["project"] as? [String: Any], let id = (p["id"] ?? p["projectId"]) as? String { return id }
        return status["projectId"] as? String
    }
    /// The takes this document sent before for the items now going, by their Flimmer id, with the clip's name.
    static func sentBefore(_ project: Project, items: [Item]) -> [String: String] {
        let sent = project.imported?.sentClips ?? [:]
        var out: [String: String] = [:]
        for item in items { if let k = item.sentKey, let take = sent[k] { out[take] = item.name } }
        return out
    }

    /// The warnings in Flimmer's answer: its overlaps, which `lines(answer:items:)` puts first.
    public static func warnings(answer: [String: Any]) -> Int { ((answer["overlaps"] as? [[String: Any]]) ?? []).filter { $0["sameTakeGroup"] as? Bool != true }.count }

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

// MARK: Transcripts to Flimmer (Flimmer's TRANSCRIPT-API, block/c, 2026-11-18; the coordinator's three conditions)

extension FlimmerSend {
    /// What `source` says of a transcript's engine (Jämmer's names: "openai <model>", "whisper-<model>",
    /// "parakeet-…", "apple-<kind>", "overdub"): engine and model, whether the sound stayed on this Mac, and
    /// where it went when it didn't. Overdub's words are the text that was spoken at ElevenLabs.
    public static func transcriptSource(engine: String) -> [String: J] {
        var name = engine, model = ""
        if let space = engine.firstIndex(of: " ") { name = String(engine[..<space]); model = String(engine[engine.index(after: space)...]) }
        else if let dash = engine.firstIndex(of: "-") { name = String(engine[..<dash]); model = String(engine[engine.index(after: dash)...]) }
        var s: [String: J] = ["app": .string("jammer"), "engine": .string(name)]
        if !model.isEmpty { s["model"] = .string(model) }
        let provider: String? = switch name {
        case "openai": "openai"
        case "elevenlabs", "scribe", "overdub": "elevenlabs"
        default: nil
        }
        s["local"] = .bool(provider == nil)
        if let provider { s["provider"] = .string(provider) }
        return s
    }

    /// The transcript of each item that has words in what it renders, as Flimmer's PUT body (without
    /// `replaceEdited`): times in seconds in the file Jämmer sends (the item's range starts at 0), the file's
    /// length, the language, speakers by name. Words nobody knows the time of (a text-only transcript) are not
    /// sent as words; the text goes alone.
    public static func transcriptBodies(_ project: Project, items: [Item]) -> [Int: [String: J]] {
        var out: [Int: [String: J]] = [:]
        let projectId = project.imported?.projectId
        for (i, item) in items.enumerated() {
            let p = item.render
            let placed = p.placedWords(in: item.range).sorted { $0.start < $1.start }
            guard !placed.isEmpty else { continue }
            let rate = p.sampleRate, length = Double(item.range.count) / rate
            let bySource = Dictionary(p.transcripts.map { ($0.sourceID, $0) }, uniquingKeysWith: { a, _ in a })
            let clipSource = Dictionary(p.tracks.flatMap(\.clips).map { ($0.id, $0.sourceID) }, uniquingKeysWith: { a, _ in a })
            let transcripts = placed.compactMap { clipSource[$0.clipID].flatMap { bySource[$0] } }
            guard let first = transcripts.first else { continue }
            var words: [J] = [], names: [String] = []
            let timed = placed.filter { $0.word.untimed != true }
            for w in timed {
                let s = max(0, min(length, Double(w.start - item.range.lowerBound) / rate))
                let e = max(s, min(length, Double(w.end - item.range.lowerBound) / rate))
                var o: [String: J] = ["text": .string(w.word.text), "start": .number((s * 1_000).rounded() / 1_000), "end": .number((e * 1_000).rounded() / 1_000)]
                if let c = w.word.confidence { o["confidence"] = .number(c) }
                if let k = w.word.speaker, let t = clipSource[w.clipID].flatMap({ bySource[$0] }), t.speakers.indices.contains(k) {
                    o["speaker"] = .string(t.speakers[k])
                    if !names.contains(t.speakers[k]) { names.append(t.speakers[k]) }
                }
                words.append(.object(o))
            }
            var body: [String: J] = ["timeBase": .string("file"), "language": .string(first.language), "words": .array(words),
                                     "text": .string(placed.map(\.word.text).joined(separator: " ")),
                                     "source": .object(transcriptSource(engine: first.engine)),
                                     "media": .object(["duration": .number((length * 1_000).rounded() / 1_000)])]
            if let projectId, !projectId.isEmpty { body["projectId"] = .string(projectId) }
            if !names.isEmpty { body["speakers"] = .array(names.map { .string($0) }) }
            out[i] = body
        }
        return out
    }

    /// How one transcript went: the clip by its name, and Flimmer's own words when it refused.
    public struct TranscriptOutcome: Sendable, Equatable {
        public var item: Int
        public var name: String
        public var clipId: String?
        public var ok: Bool
        public var replacedEdited: Bool
        /// Flimmer's error code, reason and message, as it said them.
        public var reason: String?
        public var message: String?
    }

    /// The new clips' ids from the finished plan's result, by item.
    public static func createdClips(_ answer: [String: Any]) -> [Int: String] {
        var out: [Int: String] = [:]
        for c in (answer["created"] as? [[String: Any]]) ?? [] {
            guard let i = (c["item"] as? NSNumber)?.intValue, let id = (c["clipId"] ?? c["id"]) as? String else { continue }
            out[i] = id
        }
        return out
    }

    /// One PUT per transcript, after the plan succeeded: each answered for itself, never all or nothing.
    public static func sendTranscripts(_ bodies: [Int: [String: J]], created: [Int: String], items: [Item], replaceEdited: Bool, client: Client) async -> [TranscriptOutcome] {
        var out: [TranscriptOutcome] = []
        for i in bodies.keys.sorted() {
            guard var body = bodies[i] else { continue }
            let name = items.indices.contains(i) ? items[i].name : "Clip"
            guard let clip = created[i] else {
                out.append(TranscriptOutcome(item: i, name: name, clipId: nil, ok: false, replacedEdited: false, reason: "no_clip", message: "Flimmer's answer named no new clip for it."))
                continue
            }
            if replaceEdited { body["replaceEdited"] = .bool(true) }
            let data = (try? JSONSerialization.data(withJSONObject: J.object(body).any, options: [.sortedKeys])) ?? Data()
            var r = URLRequest(url: URL(string: client.base.absoluteString + "/api/v1/audio/\(clip)/transcript")!)
            r.httpMethod = "PUT"
            r.httpBody = data
            r.setValue("1", forHTTPHeaderField: "X-Flimmer-Agent")
            r.setValue("jammer", forHTTPHeaderField: "X-Sibling")
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                let (answer, response) = try await client.transport(r)
                let object = ((try? JSONSerialization.jsonObject(with: answer)) as? [String: Any]) ?? [:]
                if (200..<300).contains(response.statusCode) {
                    let t = object["transcript"] as? [String: Any] ?? [:]
                    out.append(TranscriptOutcome(item: i, name: name, clipId: clip, ok: true, replacedEdited: (t["replacedEdited"] as? Bool) ?? false))
                } else {
                    let e = object["error"] as? [String: Any] ?? [:]
                    out.append(TranscriptOutcome(item: i, name: name, clipId: clip, ok: false, replacedEdited: false,
                                                 reason: (e["reason"] as? String) ?? (e["code"] as? String) ?? "HTTP \(response.statusCode)",
                                                 message: (e["message"] as? String) ?? String(decoding: answer.prefix(300), as: UTF8.self)))
                }
            } catch {
                out.append(TranscriptOutcome(item: i, name: name, clipId: clip, ok: false, replacedEdited: false, reason: "unreachable", message: "Flimmer stopped answering."))
            }
        }
        return out
    }

    /// The outcomes as lines for the API's answer and the window: every clip by name, which got its
    /// transcript and which didn't, with Flimmer's words for the refusals.
    public static func transcriptLines(_ outcomes: [TranscriptOutcome]) -> [String] {
        guard !outcomes.isEmpty else { return [] }
        let good = outcomes.filter(\.ok), bad = outcomes.filter { !$0.ok }
        var out: [String] = []
        if bad.isEmpty { out.append("Every transcript went to Flimmer (\(good.count)).") }
        else if good.isEmpty { out.append("No transcript went to Flimmer (\(bad.count) refused); the sound did.") }
        else { out.append("\(good.count) of \(outcomes.count) transcripts went to Flimmer; \(bad.count) didn't.") }
        for o in good { out.append("Transcript sent: \(o.name)" + (o.replacedEdited ? " (it replaced one corrected by hand in Flimmer)" : "")) }
        for o in bad {
            out.append("Transcript not sent: \(o.name). Flimmer said: \(o.message ?? "") [\(o.reason ?? "")]"
                       + (clipGone(o) ? " Flimmer no longer has that clip: send the sound again to make a new take." : ""))
        }
        return out
    }
}


// MARK: Transcripts only, to the clips a send made (the coordinator's conditions, 2026-11-18)

extension FlimmerSend {
    /// After a send that succeeded: the document remembers what each item became in Flimmer, and in which project.
    public static func remembering(_ project: Project, items: [Item], created: [Int: String], projectId: String?) -> Project {
        guard var record = project.imported else { return project }
        var map = record.sentClips ?? [:]
        for (i, id) in created { if items.indices.contains(i), let key = items[i].sentKey { map[key] = id } }
        guard !map.isEmpty else { return project }
        var p = project
        record.sentClips = map
        record.sentProjectId = projectId ?? record.projectId
        p.imported = record
        return p
    }

    /// The clips whose transcripts can go again: one item per remembered clip that is still in the document, with
    /// the Flimmer clip it became, in the order of the timeline.
    public static func sentItems(_ project: Project) -> [(item: Item, flimmerClip: String)] {
        guard let map = project.imported?.sentClips, !map.isEmpty else { return [] }
        var out: [(Item, String, Frame)] = []
        let clips = project.tracks.flatMap(\.clips)
        for (key, flimmer) in map {
            if key.hasPrefix("clip:"), let id = UUID(uuidString: String(key.dropFirst(5))), let c = clips.first(where: { $0.id == id }) {
                let name = project.source(c.sourceID)?.name ?? "Clip"
                out.append((Item(kind: .new, name: name, clipId: nil, range: c.start..<c.end, render: FlimmerReturn.soloProject(project, clip: id), fields: [:], localClip: id), flimmer, c.start))
            } else {
                let mine = clips.filter { $0.origin?.clipId == key }
                guard let first = mine.min(by: { $0.start < $1.start }), let end = mine.map(\.end).max() else { continue }
                let original = (first.origin?.snapshot?.sourceID).flatMap { project.source($0) } ?? project.source(first.sourceID)
                out.append((Item(kind: .take, name: original?.name ?? "Clip", clipId: key, range: first.start..<end, render: FlimmerReturn.soloProject(project, clipId: key), fields: [:]), flimmer, first.start))
            }
        }
        return out.sorted { $0.2 < $1.2 }.map { ($0.0, $0.1) }
    }

    /// Why transcripts can't go on their own now; nil when they can: the document remembers clips from a send, and
    /// Flimmer has that project open (`openProject`: the id Flimmer's status names, when it does). The window says it in a sentence.
    public enum TranscriptsOnlyRefusal: Equatable { case noneSent, noTranscript, otherProject }
    public static func transcriptsOnlyRefusal(_ project: Project, openProject: String?) -> TranscriptsOnlyRefusal? {
        let items = sentItems(project)
        if items.isEmpty { return .noneSent }
        if transcriptBodies(project, items: items.map(\.item)).isEmpty { return .noTranscript }
        if let open = openProject, let mine = project.imported?.sentProjectId, open != mine { return .otherProject }
        return nil
    }

    /// The transcripts of the remembered clips, each in a PUT of its own to the clip it became; a clip Flimmer no
    /// longer has is said by itself, in Flimmer's words, and nothing goes to another clip in its place.
    public static func sendTranscriptsOnly(_ project: Project, replaceEdited: Bool, client: Client) async -> [TranscriptOutcome] {
        let sent = sentItems(project)
        let items = sent.map(\.item)
        let bodies = transcriptBodies(project, items: items)
        let created = Dictionary(uniqueKeysWithValues: sent.enumerated().map { ($0.offset, $0.element.flimmerClip) })
        return await sendTranscripts(bodies, created: created, items: items, replaceEdited: replaceEdited, client: client)
    }

    /// Whether a refusal means the clip is gone in Flimmer (send the sound again to make a new one).
    public static func clipGone(_ o: TranscriptOutcome) -> Bool {
        !o.ok && ["unknown_clip", "clip_deleted", "not_found", "HTTP 404"].contains(o.reason ?? "")
    }
}
