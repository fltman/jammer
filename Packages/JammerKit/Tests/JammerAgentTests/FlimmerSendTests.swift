import Foundation
import Testing
import JammerCore
@testable import JammerAgent

/// A pretend Flimmer that follows SEND-TO-FLIMMER-API.md (v1) to the letter: uploads checked
/// by content, the whole plan validated first, dry run, job, one undo step.
final class PretendFlimmer: @unchecked Sendable {
    struct Clip { var id: String; var trackId: String; var timelineOffset: Double; var duration: Double; var linked: Bool; var relativeOffset = 0.5; var deleted = false; var muted = false }
    struct Track { var id: String; var name: String; var volume = 1.0; var muted = false; var locked = false }
    struct Upload { var name: String; var data: Data; var used = false; var open = false; var seconds: Double; var total = 0 }

    let lock = NSLock()
    var projectId = "P1", stories = ["S1"]
    var clips: [Clip] = []
    var tracks: [Track] = []
    var uploads: [String: Upload] = [:]
    var jobs: [String: [String: Any]] = [:]
    var bitDepths = [16]
    var maxBytes = 1 << 30, maxChunkBytes = 8 << 20
    var puts = 0
    /// Fails the n:th PUT, as a connection that drops would.
    var failPut: Int?
    /// Seconds each chunk takes to arrive, for the test that backs out in the middle of an upload.
    var putDelay = 0.0
    var signedIn = true, viewer = false, hasEndpoint = true
    var undoSteps: [String] = []
    var seenHeaders: [[String: String]] = []
    var polls = 0
    var n = 0
    /// Transcripts by clip id, whether a person corrected each in Flimmer, and the PUT bodies as they came.
    var transcripts: [String: [String: Any]] = [:]
    var edited: Set<String> = []
    var transcriptBodies: [[String: Any]] = []
    /// Clip ids whose transcript PUT the pretend Flimmer refuses (as unknown_clip), to test a partial outcome.
    var refuseTranscript: Set<String> = []

    var transport: FlimmerSend.Transport { { [self] r in lock.withLock { self.handle(r) } } }

    func answer(_ status: Int, _ object: [String: Any], _ r: URLRequest) -> (Data, HTTPURLResponse) {
        (try! JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: r.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    func fail(_ status: Int, _ code: String, _ r: URLRequest, reason: String? = nil, item: Int? = nil) -> (Data, HTTPURLResponse) {
        var e: [String: Any] = ["code": code, "message": code]
        if let reason { e["reason"] = reason }
        if let item { e["item"] = item }
        return answer(status, ["error": e], r)
    }

    /// PCM WAV, an allowed bit depth, mono or stereo, 44.1 or 48 kHz; by content. Returns its length in seconds.
    func wavSeconds(_ d: Data) -> Double? {
        guard d.count > 44, String(decoding: d[0..<4], as: UTF8.self) == "RIFF", String(decoding: d[8..<12], as: UTF8.self) == "WAVE" else { return nil }
        func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        var at = 12, format: (channels: Int, rate: Int, bits: Int)?
        while at + 8 <= d.count {
            let id = String(decoding: d[at..<(at + 4)], as: UTF8.self), size = u32(at + 4)
            if id == "fmt " {
                guard u16(at + 8) == 1 || u16(at + 8) == 0xFFFE else { return nil }
                format = (u16(at + 10), u32(at + 12), u16(at + 22))
            } else if id == "data", let f = format {
                guard [1, 2].contains(f.channels), [44_100, 48_000].contains(f.rate), bitDepths.contains(f.bits) else { return nil }
                return Double(size) / Double(f.channels * f.bits / 8) / Double(f.rate)
            }
            at += 8 + size + (size & 1)
        }
        return nil
    }

    func handle(_ r: URLRequest) -> (Data, HTTPURLResponse) {
        let path = r.url!.path, method = r.httpMethod ?? "GET"
        if method != "GET" {
            seenHeaders.append(r.allHTTPHeaderFields ?? [:])
            guard r.value(forHTTPHeaderField: "X-Flimmer-Agent") == "1" else { return fail(403, "forbidden", r) }
        }
        switch (method, path) {
        case ("GET", "/api/v1/status"): return answer(200, ["app": ["name": "Flimmer", "bundleID": "com.brattoo.flimmer.debug"]], r)
        case ("GET", "/api/v1/operations"): return answer(200, ["operations": [], "uploads": ["wavBitDepths": bitDepths, "maxBytes": maxBytes, "maxChunkBytes": maxChunkBytes]], r)
        case ("POST", "/api/v1/uploads"):
            let query = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let name = query.first { $0.name == "name" }?.value ?? ""
            n += 1
            let id = "up_\(n)"
            // No body and a total: an upload opened for chunks.
            if let total = query.first(where: { $0.name == "bytes" })?.value.flatMap(Int.init), (r.httpBody ?? Data()).isEmpty {
                guard total <= maxBytes else { return fail(413, "too_large", r) }
                uploads[id] = Upload(name: name, data: Data(), open: true, seconds: 0, total: total)
                return answer(201, ["upload": ["id": id, "name": name, "status": "open"]], r)
            }
            guard let body = r.httpBody, body.count <= maxChunkBytes, body.count <= maxBytes else { return fail(413, "too_large", r) }
            guard let seconds = wavSeconds(body) else { return fail(415, "unsupported_media", r) }
            uploads[id] = Upload(name: name, data: body, seconds: seconds)
            return answer(201, ["upload": ["id": id, "name": name, "bytes": body.count]], r)
        case ("PUT", let p) where p.hasPrefix("/api/v1/uploads/"):
            if putDelay > 0 { Thread.sleep(forTimeInterval: putDelay) }
            puts += 1
            let id = String(p.dropFirst("/api/v1/uploads/".count))
            guard var u = uploads[id], u.open else { return fail(404, "not_found", r) }
            if puts == failPut { return fail(500, "internal", r) }
            let offset = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "offset" }?.value.flatMap(Int.init)
            guard let chunk = r.httpBody, chunk.count <= maxChunkBytes, offset == u.data.count, u.data.count + chunk.count <= u.total else { return fail(413, "too_large", r) }
            u.data.append(chunk)
            uploads[id] = u
            return answer(200, ["upload": ["id": id, "bytes": u.data.count, "status": "open"]], r)
        case ("POST", let p) where p.hasPrefix("/api/v1/uploads/") && p.hasSuffix("/complete"):
            let id = String(p.dropFirst("/api/v1/uploads/".count).dropLast("/complete".count))
            guard var u = uploads[id], u.open, u.data.count == u.total else { return fail(404, "not_found", r) }
            guard let seconds = wavSeconds(u.data) else { uploads[id] = nil; return fail(415, "unsupported_media", r) }
            u.open = false
            u.seconds = seconds
            uploads[id] = u
            return answer(200, ["upload": ["id": id, "bytes": u.data.count]], r)
        case ("DELETE", let p) where p.hasPrefix("/api/v1/uploads/"):
            uploads[String(p.dropFirst("/api/v1/uploads/".count))] = nil
            return answer(200, [:], r)
        case ("GET", let p) where p.hasPrefix("/api/v1/jobs/"):
            polls += 1
            guard let job = jobs[String(p.dropFirst("/api/v1/jobs/".count))] else { return fail(404, "not_found", r) }
            return answer(200, ["job": job], r)
        case ("PUT", let p) where p.hasPrefix("/api/v1/audio/") && p.hasSuffix("/transcript"):
            return transcript(String(p.dropFirst("/api/v1/audio/".count).dropLast("/transcript".count)), r)
        case ("POST", "/api/v1/audio/sibling-plan"):
            guard hasEndpoint else { return fail(404, "not_found", r) }
            guard signedIn else { return fail(409, "not_available", r) }
            guard !viewer else { return fail(403, "forbidden", r) }
            return plan(try! JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any], r)
        default: return fail(404, "not_found", r)
        }
    }

    /// Flimmer's PUT /api/v1/audio/{clipId}/transcript as its TRANSCRIPT-API says (closed schema, file times,
    /// duration within 0.05 s, provider when not local, 409 edited_exists without replaceEdited).
    func transcript(_ clip: String, _ r: URLRequest) -> (Data, HTTPURLResponse) {
        guard r.value(forHTTPHeaderField: "X-Flimmer-Agent") == "1" else { return fail(403, "forbidden", r) }
        let b = (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data()) as? [String: Any]) ?? [:]
        transcriptBodies.append(b)
        let known: Set<String> = ["projectId", "timeBase", "language", "words", "speakers", "text", "source", "media", "edited", "replaceEdited", "rationale"]
        if let odd = b.keys.first(where: { !known.contains($0) }) { return answer(400, ["error": ["code": "bad_request", "message": "Unknown field \(odd)."]], r) }
        func no(_ reason: String, _ message: String) -> (Data, HTTPURLResponse) { answer(422, ["error": ["code": "unprocessable", "reason": reason, "message": message]], r) }
        if let p = b["projectId"] as? String, p != projectId { return no("wrong_project", "Another project is open.") }
        if refuseTranscript.contains(clip) { return no("unknown_clip", "No audio clip \(clip) in the open project.") }
        guard let c = clips.first(where: { $0.id == clip }) else { return no("unknown_clip", "No audio clip \(clip) in the open project.") }
        guard b["timeBase"] as? String == "file" else { return no("wrong_time_base", "timeBase must be file.") }
        let duration = ((b["media"] as? [String: Any])?["duration"] as? NSNumber)?.doubleValue ?? -1
        guard abs(duration - c.duration) <= 0.05 else { return no("duration_mismatch", "media.duration \(duration) is not the file's \(c.duration).") }
        let source = b["source"] as? [String: Any] ?? [:]
        guard let local = source["local"] as? Bool, local || source["provider"] is String else { return answer(400, ["error": ["code": "bad_request", "message": "source.provider is required when local is false."]], r) }
        let words = b["words"] as? [[String: Any]] ?? []
        var last = -1.0
        for (i, w) in words.enumerated() {
            let s = (w["start"] as? NSNumber)?.doubleValue ?? -1, e = (w["end"] as? NSNumber)?.doubleValue ?? -1
            if s < 0 || e > c.duration + 0.05 { return no("words_out_of_range", "Word \(i) lies outside the file.") }
            if s < last { return no("words_not_ordered", "Word \(i) starts before the one before it.") }
            last = s
        }
        let wasEdited = edited.contains(clip)
        if wasEdited, b["replaceEdited"] as? Bool != true {
            return answer(409, ["error": ["code": "not_available", "reason": "edited_exists", "message": "A person corrected this transcript in Flimmer; send replaceEdited to replace it."]], r)
        }
        let replaced = transcripts[clip] != nil
        transcripts[clip] = b
        edited.remove(clip)
        if wasEdited { undoSteps.append("Jämmer ersatte ett rättat transkript.") }
        return answer(200, ["transcript": ["id": "tr-\(clip)", "language": b["language"] ?? "", "replaced": replaced, "replacedEdited": wasEdited, "words": words.count]], r)
    }

    func plan(_ b: [String: Any], _ r: URLRequest) -> (Data, HTTPURLResponse) {
        func no(_ reason: String, _ item: Int? = nil) -> (Data, HTTPURLResponse) { fail(422, "unprocessable", r, reason: reason, item: item) }
        guard b["projectId"] as? String == projectId else { return no("wrong_project") }
        guard let story = b["storyId"] as? String, stories.contains(story) else { return no("wrong_story") }
        let items = b["items"] as? [[String: Any]] ?? [], settings = b["trackSettings"] as? [[String: Any]] ?? []
        guard !items.isEmpty || !settings.isEmpty else { return no("nothing_to_change") }
        var seen: Set<String> = [], create: [[String: Any]] = [], mute: [String] = [], overlaps: [[String: Any]] = []
        for (i, item) in items.enumerated() {
            guard let up = item["uploadId"] as? String, let upload = uploads[up] else { return no("unknown_upload", i) }
            if upload.open { return no("upload_open", i) }
            if upload.used { return no("upload_used", i) }
            let position = item["position"] as? [String: Any]
            switch item["kind"] as? String {
            case "take":
                guard let id = item["clipId"] as? String, let clip = clips.first(where: { $0.id == id }) else { return no("unknown_clip", i) }
                if clip.deleted { return no("clip_deleted", i) }
                if !seen.insert(id).inserted { return no("duplicate_clip", i) }
                if tracks.first(where: { $0.id == clip.trackId })?.locked == true { return no("locked_track", i) }
                if let position, (position["clipRelativeOffset"] != nil) != clip.linked { return no("wrong_position_kind", i) }
                var at = clip.timelineOffset
                if let t = position?["timelineOffset"] as? Double { at = t }
                // A linked clip sits at its shot's start plus the offset.
                if let rel = position?["clipRelativeOffset"] as? Double { at = clip.timelineOffset - clip.relativeOffset + rel }
                create.append(["item": i, "name": "\(upload.name)", "trackId": clip.trackId, "timelineOffset": at, "duration": upload.seconds, "takeOf": id])
                mute.append(id)
                // A take longer than its original can reach into the next clip on the track.
                if let next = clips.filter({ $0.trackId == clip.trackId && $0.id != id && $0.timelineOffset >= at }).min(by: { $0.timelineOffset < $1.timelineOffset }),
                   at + upload.seconds > next.timelineOffset + 1e-6 {
                    overlaps.append(["item": i, "with": next.id, "seconds": ((at + upload.seconds - next.timelineOffset) * 100).rounded() / 100])
                }
            case "new":
                if let t = item["trackId"] as? String, !tracks.contains(where: { $0.id == t }) { return no("unknown_track", i) }
                create.append(["item": i, "name": item["name"] as? String ?? "", "timelineOffset": position?["timelineOffset"] as? Double ?? 0, "duration": upload.seconds])
            case "mix":
                guard b["mode"] as? String == "mix", items.count == 1 else { return no("nothing_to_change", i) }
                create.append(["item": i, "name": "Jämmer mix", "trackName": "Jämmer mix", "timelineOffset": 0.0, "duration": upload.seconds])
            default: return no("nothing_to_change", i)
            }
        }
        for s in settings { guard tracks.contains(where: { $0.id == s["trackId"] as? String }) else { return no("unknown_track") } }
        let listed = b["listed"] as? [Any] ?? []
        if b["dryRun"] as? Bool == true {
            return answer(200, ["dryRun": true, "wouldCreate": create, "wouldMute": mute, "wouldSetTracks": settings, "overlaps": overlaps, "listed": listed, "warnings": []], r)
        }
        // For real: all at once, one undo step; the uploads are consumed.
        for item in items { uploads[item["uploadId"] as! String]?.used = true }
        for id in mute { clips[clips.firstIndex { $0.id == id }!].muted = true }
        for (k, c) in create.enumerated() where c["takeOf"] != nil {
            let id = "take-\(clips.count)"
            clips.append(Clip(id: id, trackId: c["trackId"] as! String, timelineOffset: c["timelineOffset"] as! Double, duration: c["duration"] as! Double, linked: false))
            create[k]["clipId"] = id
        }
        for s in settings {
            let i = tracks.firstIndex { $0.id == s["trackId"] as? String }!
            tracks[i].volume = s["volume"] as! Double
            tracks[i].muted = s["muted"] as! Bool
        }
        undoSteps.append("Requested by Jämmer")
        n += 1
        let id = "job_\(n)"
        // The first poll finds it running, the next done.
        jobs[id] = ["id": id, "status": "done", "result": ["created": create, "muted": mute, "setTracks": settings, "overlaps": overlaps, "listed": listed, "warnings": []]]
        return answer(202, ["job": ["id": id, "status": "running"]], r)
    }
}

@Suite("Send to Flimmer")
struct FlimmerSendTests {
    let sr = 48_000.0

    /// A film as it comes in from Flimmer: Dialog (C1 linked to a shot, C2 free and right after it), Musik (C3), the video's own sound.
    func film(rate: Double = 48_000, ids: Bool = true) -> (Project, SourcePool) {
        let pool = SourcePool()
        func source(_ name: String, seconds: Double, level: Float) -> SourceRef {
            let n = Int(seconds * rate)
            let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 1, sampleRate: rate,
                                     channelMask: nil, dataOffset: 0, frames: Int64(n), chunks: [], bext: nil, ixml: nil, markers: [])
            let ref = SourceRef(name: name, path: "/dev/null", info: info)
            pool.register(ref.id, memory: (0..<n).map { level * Float(sin(2 * .pi * 440 * Double($0) / rate)) }, channels: 1)
            return ref
        }
        let a = source("berattare", seconds: 10, level: 0.2), b = source("fiskaren", seconds: 10, level: 0.2)
        let m = source("musik", seconds: 20, level: 0.1), v = source("vagor", seconds: 5, level: 0.1)
        func f(_ s: Double) -> Frame { Frame(s * rate) }
        func clip(_ s: SourceRef, at: Double, length: Double, id: String, track: String?, shot: String? = nil, video: Bool = false) -> Clip {
            var c = Clip(sourceID: s.id, start: f(at), length: f(length), fadeShape: .linear)
            var o = Origin(app: "flimmer", clipId: id, trackId: track, linkedShotId: shot, exportVersion: "2")
            var snap = Origin.Snapshot()
            snap.start = c.start; snap.length = c.length; snap.sourceID = c.sourceID
            o.snapshot = snap
            if shot != nil, !video { o.clipRelativeOffset = 0.5 }
            if video { o.videoAudio = true }
            c.origin = o
            return c
        }
        func track(_ name: String, _ id: String?, _ clips: [Clip]) -> Track {
            var t = Track(name: name, clips: clips)
            if let id {
                var o = Origin(app: "flimmer", trackId: id, exportVersion: "2")
                o.snapshot = Origin.Snapshot()
                t.origin = o
            }
            return t
        }
        var p = Project(sampleRate: rate, channels: 2, tracks: [
            track("Dialog", "T1", [clip(a, at: 4.5, length: 4, id: "C1", track: "T1", shot: "SH1"), clip(b, at: 9, length: 3, id: "C2", track: "T1")]),
            track("Musik", "T2", [clip(m, at: 8, length: 7.5, id: "C3", track: "T2")]),
            track("Video", nil, [clip(v, at: 17, length: 3, id: "K4", track: nil, shot: "SH4", video: true)]),
        ], sources: [a, b, m, v])
        p.imported = .init(app: "flimmer", exportVersion: ids ? "2" : "1", clipIds: ["C1", "C2", "C3"], length: p.length,
                           projectId: ids ? "P1" : nil, storyId: ids ? "S1" : nil)
        return (p, pool)
    }

    func flimmer() -> PretendFlimmer {
        let f = PretendFlimmer()
        f.tracks = [.init(id: "T1", name: "Dialog"), .init(id: "T2", name: "Musik")]
        f.clips = [.init(id: "C1", trackId: "T1", timelineOffset: 4.5, duration: 4, linked: true), .init(id: "C2", trackId: "T1", timelineOffset: 9, duration: 3, linked: false),
                   .init(id: "C3", trackId: "T2", timelineOffset: 8, duration: 7.5, linked: false)]
        return f
    }

    func render(_ pool: SourcePool) -> FlimmerSend.Render {
        { item, depth, rate in
            try FlimmerSend.wavFile(PlanCompiler.compile(item.render, pool: pool), range: item.range, bitDepth: depth, sampleRate: rate, monoIfSame: item.monoSource,
                                    scratch: FileManager.default.temporaryDirectory)
        }
    }

    func client(_ f: PretendFlimmer) -> FlimmerSend.Client { .init(base: URL(string: "http://127.0.0.1:9002")!, transport: f.transport, pollInterval: 0.01) }

    func failure(_ body: () async throws -> Void) async -> FlimmerSend.Failure? {
        do { try await body(); return nil } catch { return error as? FlimmerSend.Failure }
    }

    @Test("Takes: changed clips go as files, a dry run first, then one undo step; unchanged clips stay")
    func takes() async throws {
        var (p, pool) = film()
        let f = flimmer(), c = client(f)
        // C1: a level change in the middle (three pieces, in place). C3: half a second later. Dialog down 3 dB.
        try p.changeGain(Frame(5.5 * sr)..<Frame(6.5 * sr), by: -6)
        p.tracks[1].clips[0].start += Frame(0.5 * sr)
        p.tracks[0].gainDB = -3
        let prepared = try await FlimmerSend.prepare(p, mode: .takes, client: c, render: render(pool))
        #expect(prepared.items.map(\.clipId) == ["C1", "C3"] && prepared.uploads.count == 2 && f.undoSteps.isEmpty && f.clips.count == 3, "a dry run changes nothing")
        #expect(prepared.lines.contains("New take of berattare, 4.00 s, from 3 pieces.") && prepared.lines.contains("New take of musik, 7.50 s, moved +0.50 s."), "\(prepared.lines)")
        #expect(prepared.lines.contains("Track Dialog: level -3.0 dB, not muted.") && prepared.lines.contains("1 clip is unchanged and not sent."))
        #expect(prepared.flimmerLines == ["Flimmer would make 2 new clips and mute 2 originals (kept, not changed)."], "\(prepared.flimmerLines)")
        // The files: Flimmer's bit depth, the clip's own length, level and the cut baked in, the track's level not.
        let file = try #require(f.uploads[prepared.uploads[0]])
        #expect(abs(file.seconds - 4) < 0.001 && file.name == "berattare-jammer.wav")
        let scratch = FileManager.default.temporaryDirectory.appending(path: "jammer-fs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try file.data.write(to: scratch.appending(path: "t.wav"))
        let info = try AudioFileReader.info(at: scratch.appending(path: "t.wav"))
        #expect(info.sampleFormat == .int16 && info.sampleRate == 48_000 && info.channels == 1, "a mono original gets a mono take")
        let back = Project(source: try AudioImporter.importFile(scratch.appending(path: "t.wav"), mediaFolder: scratch).source)
        let x = PlanCompiler.compile(back, pool: SourcePool()).render(from: 0, frames: Int(4 * sr))
        func peak(_ a: Double, _ b: Double) -> Float { x[(Int(a * sr) * back.channels)..<(Int(b * sr) * back.channels)].map(abs).max() ?? 0 }
        #expect(abs(peak(0.1, 0.9) - 0.2) < 0.002 && abs(peak(1.1, 1.9) - 0.1002) < 0.002 && abs(peak(2.1, 3.9) - 0.2) < 0.002, "the −6 dB stretch is in the file, the track's −3 dB isn't")
        // The plan as sent: a position only for the moved clip, the right kind; headers as the protocol says.
        let items = prepared.body["items"]!.any as! [[String: Any]]
        #expect(items[0]["position"] == nil && (items[1]["position"] as? [String: Double]) == ["timelineOffset": 8.5])
        #expect(items.map { $0["name"] as? String } == ["berattare", "musik"], "the clip's name in Jämmer goes along")
        #expect((prepared.body["trackSettings"]!.any as! [[String: Any]]).first?["volume"] as? Double == 0.7079)
        #expect(f.seenHeaders.allSatisfy { $0["X-Flimmer-Agent"] == "1" && $0["X-Sibling"] == "jammer" && $0["Origin"] == nil })
        // For real.
        let done = try await FlimmerSend.send(prepared, client: c)
        #expect(done == ["Flimmer made 2 new clips and muted 2 originals (kept, not changed)."])
        #expect(f.undoSteps == ["Requested by Jämmer"] && f.clips.count == 5 && f.clips[0].muted && !f.clips[1].muted && f.clips[2].muted && f.polls >= 1)
        #expect(abs(f.tracks[0].volume - 0.7079) < 1e-9 && f.uploads.values.allSatisfy(\.used))
        // The same uploads can't be used twice.
        #expect(await failure { _ = try await FlimmerSend.send(prepared, client: c) }?.reason == "upload_used")
    }

    @Test("A sibling's job: queued and running are waited on, canceled ends it in either spelling, and a status nobody knows ends the wait with an error")
    func jobStatuses() {
        #expect(FlimmerSend.jobState("queued") == .waiting && FlimmerSend.jobState("running") == .waiting)
        #expect(FlimmerSend.jobState("done") == .done && FlimmerSend.jobState("failed") == .failed)
        #expect(FlimmerSend.jobState("canceled") == .canceled && FlimmerSend.jobState("cancelled") == .canceled)
        #expect(FlimmerSend.jobState("paused") == .unknown("paused") && FlimmerSend.jobState(nil) == .unknown("") && FlimmerSend.jobState("Done") == .unknown("Done"))
        // Jämmer's own word for a stopped job, as the series writes it.
        #expect(Job.Status.cancelled.rawValue == "canceled")
    }

    @Test("A linked clip that moved sends its offset from the shot; a longer take warns about the next clip")
    func linkedAndOverlap() async throws {
        var (p, pool) = film()
        let f = flimmer()
        // C1 a quarter second later and one second longer: it now reaches into C2 at 9 s.
        p.tracks[0].clips[0].start += Frame(0.25 * sr)
        p.tracks[0].clips[0].length += Frame(1 * sr)
        let prepared = try await FlimmerSend.prepare(p, mode: .takes, client: client(f), render: render(pool))
        let items = prepared.body["items"]!.any as! [[String: Any]]
        #expect((items[0]["position"] as? [String: Double]) == ["clipRelativeOffset": 0.75])
        #expect(prepared.flimmerLines.first == "Warning: berattare would overlap the next clip on its track by 0.75 s.", "\(prepared.flimmerLines)")
        #expect(prepared.flimmerWarnings == 1)
    }

    @Test("What v1 doesn't carry out is listed; new sound becomes a new clip; a ripple cut is said")
    func listed() async throws {
        var (p, pool) = film()
        let f = flimmer()
        let moved = p.tracks[0].clips.remove(at: 1)        // C2 to the music track
        p.tracks[1].clips.removeAll()                      // C3 deleted
        p.tracks[1].clips.append(moved)
        p.tracks[2].clips[0].gainDB = -3                   // the video's own sound changed
        p.tracks[0].clips.append(Clip(sourceID: p.sources[0].id, start: Frame(12 * sr), length: Frame(sr)))
        p.tracks.append(Track(name: "Foley", clips: [Clip(sourceID: p.sources[0].id, start: 0, length: Frame(sr))]))
        let prepared = try await FlimmerSend.prepare(p, mode: .takes, client: client(f), render: render(pool))
        let listed = prepared.body["listed"]!.any as! [[String: String]]
        #expect(listed == [["kind": "trackChange", "clipId": "C2", "note": "moved to track Musik in Jämmer"], ["kind": "deleted", "clipId": "C3"],
                           ["kind": "videoAudio", "shotClipId": "K4", "note": "changed in Jämmer, not sent in this version"]])
        let items = prepared.body["items"]!.any as! [[String: Any]]
        #expect(items.map { $0["kind"] as? String } == ["take", "new", "new"] && items[1]["trackId"] as? String == "T1" && items[2]["trackId"] == nil)
        #expect(prepared.lines.contains { $0.contains("stays on its track in Flimmer") } && prepared.lines.contains { $0.contains("no longer in this document") }
                && prepared.lines.contains { $0.contains("not sent in this version") } && prepared.lines.contains("New clip on a new track, \"Foley\" at 0.00 s, 1.00 s."), "\(prepared.lines)")
        // Shorter than it came in.
        var cut = film().0
        cut.tracks[2].clips.removeAll()
        cut.tracks[1].clips[0].length -= Frame(2 * sr)
        let plan = try FlimmerReturn.plan(cut)
        #expect(FlimmerSend.lines(cut, plan: plan, mode: .takes, items: FlimmerSend.items(cut, plan: plan, mode: .takes)).last?.hasPrefix("The document is 6.50 s shorter") == true)
    }

    @Test("Mix: one file of everything but the video's own sound, on a new track")
    func mix() async throws {
        let (p, pool) = film()
        let f = flimmer(), c = client(f)
        f.bitDepths = [16, 24]
        let prepared = try await FlimmerSend.prepare(p, mode: .mix, client: c, render: render(pool))
        let up = try #require(f.uploads[prepared.uploads[0]])
        // Without the Video track the mix ends where the music does, at 15.5 s, not at 20.
        #expect(prepared.items.count == 1 && abs(up.seconds - 15.5) < 0.001 && prepared.body["trackSettings"] == nil && prepared.body["listed"] == nil)
        let scratch = FileManager.default.temporaryDirectory.appending(path: "jammer-fs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try up.data.write(to: scratch.appending(path: "m.wav"))
        #expect(try AudioFileReader.info(at: scratch.appending(path: "m.wav")).sampleFormat == .int24, "24 bits when Flimmer says it takes them")
        _ = try await FlimmerSend.send(prepared, client: c)
        #expect(f.undoSteps.count == 1 && f.clips.allSatisfy { !$0.muted })
    }

    @Test("A document at 96 kHz is sent at 48 kHz, and says so")
    func resampled() async throws {
        var (p, pool) = film(rate: 96_000)
        p.tracks[1].clips[0].gainDB = -2
        let f = flimmer()
        let prepared = try await FlimmerSend.prepare(p, mode: .takes, client: client(f), render: render(pool))
        #expect(abs(f.uploads[prepared.uploads[0]]!.seconds - 7.5) < 0.01)
        #expect(prepared.lines.last == "The document is 96000 Hz; the files are converted to 48000 Hz, which is what Flimmer takes.")
    }

    @Test("Refusals say what to do: an old export, nothing changed, the wrong project, a viewer, a locked track")
    func refusals() async throws {
        let (p, pool) = film()
        var f = flimmer()
        // exportVersion 1 has no ids: refused before anything is rendered, without asking which project.
        let old = film(ids: false).0
        var e = await failure { _ = try await FlimmerSend.prepare(old, mode: .takes, client: client(f), render: render(pool)) }
        #expect(e?.code == "needs_new_export" && e?.message.contains("Export it again from Flimmer") == true && f.uploads.isEmpty)
        #expect(FlimmerSend.refusal(Project(sampleRate: 48_000, channels: 2))?.code == "not_from_flimmer")
        e = await failure { _ = try await FlimmerSend.prepare(p, mode: .takes, client: client(f), render: render(pool)) }
        #expect(e?.code == "nothing_to_change")
        // Each of Flimmer's answers in words, and the uploads are taken away again.
        var changed = p
        changed.tracks[0].clips[1].gainDB = -4
        func attempt(_ setup: (PretendFlimmer) -> Void) async -> (FlimmerSend.Failure?, PretendFlimmer) {
            let f = flimmer()
            setup(f)
            let e = await failure { _ = try await FlimmerSend.prepare(changed, mode: .takes, client: client(f), render: render(pool)) }
            return (e, f)
        }
        (e, f) = await attempt { $0.projectId = "other" }
        #expect(e?.reason == "wrong_project" && e?.message.contains("Another project is open in Flimmer") == true && f.uploads.isEmpty, "uploads removed after a failure")
        (e, f) = await attempt { $0.stories = [] }
        #expect(e?.reason == "wrong_story")
        (e, f) = await attempt { $0.viewer = true }
        #expect(e?.code == "forbidden" && e?.message.contains("viewer") == true)
        (e, f) = await attempt { $0.signedIn = false }
        #expect(e?.code == "not_available" && e?.message.contains("no project open") == true)
        (e, f) = await attempt { $0.tracks[0].locked = true }
        #expect(e?.reason == "locked_track" && e?.message == "The track of \"fiskaren\" is locked in Flimmer. Unlock it there and send again.")
        (e, f) = await attempt { $0.clips[1].deleted = true }
        #expect(e?.reason == "clip_deleted" && e?.message.contains("\"fiskaren\"") == true)
        (e, f) = await attempt { $0.clips.remove(at: 1) }
        #expect(e?.reason == "unknown_clip")
        (e, f) = await attempt { $0.hasEndpoint = false }
        #expect(e?.message == "This Flimmer can't receive sound from Jämmer yet. Update Flimmer.")
        // Closing the sheet after the dry run removes the uploads.
        f = flimmer()
        let prepared = try await FlimmerSend.prepare(changed, mode: .takes, client: client(f), render: render(pool))
        #expect(f.uploads.count == 1)
        await FlimmerSend.cancel(prepared, client: client(f))
        #expect(f.uploads.isEmpty && f.undoSteps.isEmpty)
    }

    @Test("A plan with only track settings is allowed")
    func settingsOnly() async throws {
        var (p, pool) = film()
        let f = flimmer(), c = client(f)
        p.tracks[1].isMuted = true
        let prepared = try await FlimmerSend.prepare(p, mode: .takes, client: c, render: render(pool))
        #expect(prepared.items.isEmpty && prepared.uploads.isEmpty && prepared.lines.first == "Track Musik: level 0.0 dB, muted.")
        _ = try await FlimmerSend.send(prepared, client: c)
        #expect(f.tracks[1].muted && f.undoSteps.count == 1 && f.clips.count == 3)
    }

    @Test("Mono stays mono unless the work here made it stereo, and then the dry run says so")
    func channels() async throws {
        let (p, pool) = film()
        var plan = RenderPlanProbe.stereoised(p, pool: pool)
        let f = flimmer()
        let prepared = try await FlimmerSend.prepare(plan.project, mode: .takes, client: client(f), render: render(plan.pool))
        func channels(_ d: Data) -> Int {
            let at = d.range(of: Data("fmt ".utf8))!.lowerBound
            return Int(d[at + 10]) | Int(d[at + 11]) << 8
        }
        #expect(channels(f.uploads[prepared.uploads[0]]!.data) == 2 && prepared.lines.contains("berattare was mono and comes back in stereo: what was done to it here made the two sides differ."), "\(prepared.lines)")
        plan = RenderPlanProbe.stereoised(p, pool: pool, differ: false)
        let same = try await FlimmerSend.prepare(plan.project, mode: .takes, client: client(f), render: render(plan.pool))
        #expect(channels(f.uploads[same.uploads[0]]!.data) == 1 && !same.lines.contains { $0.contains("stereo") })
    }

    @Test("Large files go in chunks from disk; one over the limit is refused before anything is uploaded; a dropped upload is removed")
    func chunks() async throws {
        let (p, pool) = film()
        let f = flimmer(), c = client(f)
        f.maxChunkBytes = 100_000
        // The mix: 15.5 s stereo at 16 bits is about 3 MB, so some thirty chunks.
        let prepared = try await FlimmerSend.prepare(p, mode: .mix, client: c, render: render(pool))
        let up = try #require(f.uploads[prepared.uploads[0]])
        #expect(f.puts >= 29 && !up.open && abs(up.seconds - 15.5) < 0.001 && up.data.count == up.total)
        #expect(f.seenHeaders.allSatisfy { $0["X-Sibling"] == "jammer" })
        await FlimmerSend.cancel(prepared, client: c)
        // Over Flimmer's limit: said in words before any upload exists.
        f.maxBytes = 1_000_000
        f.puts = 0
        let big = await failure { _ = try await FlimmerSend.prepare(p, mode: .mix, client: c, render: render(pool)) }
        #expect(big?.code == "too_large" && big?.message.hasPrefix("The mix would be") == true && f.uploads.isEmpty && f.puts == 0, "\(big?.message ?? "")")
        // The connection drops at the fifth chunk: the half-sent upload is taken away.
        f.maxBytes = 1 << 30
        f.failPut = 5
        let dropped = await failure { _ = try await FlimmerSend.prepare(p, mode: .mix, client: c, render: render(pool)) }
        #expect(dropped != nil && f.uploads.isEmpty && f.puts == 5 && f.undoSteps.isEmpty)
        // The user backs out in the middle (the task is cancelled): the same.
        // Each chunk takes a moment, so the cancellation lands in the middle however busy the machine is
        // (without it, a loaded test run could see all 29 chunks through before the test got to cancel).
        f.failPut = nil
        f.puts = 0
        f.putDelay = 0.01
        let task = Task { try await FlimmerSend.prepare(p, mode: .mix, client: c, render: render(pool)) }
        while f.lock.withLock({ f.puts }) < 3 { try await Task.sleep(for: .milliseconds(1)) }
        task.cancel()
        _ = await task.result
        #expect(f.lock.withLock { f.uploads.isEmpty } && f.lock.withLock { f.puts } < 29)
    }

    @Test("Finding Flimmer: the name must match, and a debug copy pairs only with a debug copy")
    func find() async {
        let f = flimmer()
        #expect(await FlimmerSend.find(transport: f.transport, debug: true) == URL(string: "http://127.0.0.1:9002"))
        #expect(await FlimmerSend.find(transport: f.transport, debug: false) == nil)
        let other: FlimmerSend.Transport = { r in
            (try! JSONSerialization.data(withJSONObject: ["app": ["name": "Glimmer", "bundleID": "com.brattoo.glimmer"]]), HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(await FlimmerSend.find(transport: other, debug: false) == nil)
        // A visiting test's guest copy of Flimmer is a debug build: a debug Jämmer pairs with it, a release one never.
        let guest: FlimmerSend.Transport = { r in
            (try! JSONSerialization.data(withJSONObject: ["app": ["name": "Flimmer", "bundleID": "com.brattoo.flimmer.debug.guest"]]), HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(await FlimmerSend.find(transport: guest, debug: true) != nil)
        #expect(await FlimmerSend.find(transport: guest, debug: false) == nil)
        #expect(AgentAPI.isDebugBundle("com.brattoo.glimmer.debug") && AgentAPI.isDebugBundle("com.brattoo.glimmer.debug.guest")
                && !AgentAPI.isDebugBundle("com.brattoo.glimmer") && !AgentAPI.isDebugBundle("com.brattoo.glimmer.guest"))
    }
}

/// A film whose first clip plays from a stereo file made here (as a stereo effect would leave it).
enum RenderPlanProbe {
    static func stereoised(_ project: Project, pool: SourcePool, differ: Bool = true) -> (project: Project, pool: SourcePool) {
        var p = project
        let rate = p.sampleRate, n = Int(10 * rate)
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: rate,
                                 channelMask: nil, dataOffset: 0, frames: Int64(n), chunks: [], bext: nil, ixml: nil, markers: [])
        let ref = SourceRef(name: "berattare echo", path: "/dev/null", info: info)
        pool.register(ref.id, memory: (0..<n).flatMap { i -> [Float] in
            let v = Float(0.2 * sin(2 * .pi * 440 * Double(i) / rate))
            return [v, differ ? v * 0.5 : v]
        }, channels: 2)
        p.sources.append(ref)
        // The clip keeps its origin (the mono original) and now plays from the processed file.
        p.tracks[0].clips[0].sourceID = ref.id
        return (p, pool)
    }

}

extension FlimmerSendTests {
    /// A document whose two dialogue clips have transcripts: C1 (berattare) by KB-Whisper with a speaker, C3 (musik) by OpenAI, text and times.
    func filmWithWords() -> (Project, SourcePool) {
        var (p, pool) = film()
        func words(_ list: [(String, Double, Double)]) -> [Word] { list.map { Word(text: $0.0, start: Frame($0.1 * sr), end: Frame($0.2 * sr), speaker: 0) } }
        p.transcripts = [
            SourceTranscript(sourceID: p.tracks[0].clips[0].sourceID, language: "sv-SE", engine: "whisper-kb-whisper-large",
                             words: words([("God", 0.4, 0.6), ("morgon", 0.7, 1.1), ("havet", 2.0, 2.5)]), speakers: ["Berättaren"]),
            SourceTranscript(sourceID: p.tracks[1].clips[0].sourceID, language: "sv-SE", engine: "openai gpt-4o-transcribe",
                             words: [Word(text: "la", start: Frame(1 * sr), end: Frame(1.4 * sr))]),
        ]
        return (p, pool)
    }

    @Test("Transcripts go after the plan, one PUT each, to the new takes: times in the file's own seconds, its length, the speaker by name, local and provider as the engine was; the dry run names them and sends none")
    func transcriptsAfterThePlan() async throws {
        var (p, pool) = filmWithWords()
        let f = flimmer(), c = client(f)
        try p.changeGain(Frame(5.5 * sr)..<Frame(6.5 * sr), by: -6)
        p.tracks[1].clips[0].start += Frame(0.5 * sr)
        let prepared = try await FlimmerSend.prepare(p, mode: .takes, client: c, render: render(pool))
        #expect(prepared.transcripts.count == 2 && f.transcriptBodies.isEmpty, "the dry run sends no transcript")
        #expect(prepared.lines.contains { $0.hasPrefix("Transcripts of 2 clips go after the sound") })
        let r = try await FlimmerSend.sendAll(prepared, client: c, transcripts: true, replaceEdited: false)
        #expect(r.transcripts.count == 2 && r.transcripts.allSatisfy(\.ok), "\(r.transcripts)")
        #expect(f.transcriptBodies.count == 2 && Set(r.transcripts.compactMap(\.clipId)).allSatisfy { $0.hasPrefix("take-") }, "to the new takes, not the originals")
        let first = f.transcriptBodies[0]
        // C1 starts at 4.5 s on the timeline and plays its source from 0: the file's 0.4 s is the word's 0.4 s.
        let w = first["words"] as! [[String: Any]]
        #expect(w.count == 3 && (w[0]["start"] as! Double) == 0.4 && (w[0]["end"] as! Double) == 0.6 && w[0]["speaker"] as? String == "Berättaren")
        #expect((first["media"] as! [String: Any])["duration"] as! Double == 4 && first["timeBase"] as? String == "file" && first["projectId"] as? String == "P1")
        let s1 = first["source"] as! [String: Any], s2 = f.transcriptBodies[1]["source"] as! [String: Any]
        #expect(s1["engine"] as? String == "whisper" && s1["model"] as? String == "kb-whisper-large" && s1["local"] as? Bool == true && s1["provider"] == nil)
        #expect(s2["engine"] as? String == "openai" && s2["local"] as? Bool == false && s2["provider"] as? String == "openai", "a transcript made in the cloud says so")
        #expect(FlimmerSend.transcriptLines(r.transcripts).first == "Every transcript went to Flimmer (2).")
    }

    @Test("A transcript corrected by hand in Flimmer: refused without replaceEdited (409 edited_exists, in Flimmer's words, the others still go), replaced with it; a refused one is named clip by clip, never all or nothing; a failed plan sends none; the box off sends none")
    func transcriptOutcomes() async throws {
        var (p, pool) = filmWithWords()
        let f = flimmer(), c = client(f)
        try p.changeGain(Frame(5.5 * sr)..<Frame(6.5 * sr), by: -6)
        p.tracks[1].clips[0].start += Frame(0.5 * sr)
        // The box off: the sound goes, no transcript.
        let off = try await FlimmerSend.sendAll(try await FlimmerSend.prepare(p, mode: .takes, client: c, render: render(pool)), client: c, transcripts: false, replaceEdited: false)
        #expect(off.transcripts.isEmpty && f.transcriptBodies.isEmpty)
        // One take's transcript corrected in Flimmer, the other refused for another reason.
        let prepared = try await FlimmerSend.prepare(p, mode: .takes, client: c, render: render(pool))
        let before = f.clips.count
        f.edited = ["take-\(before)"]
        f.refuseTranscript = ["take-\(before + 1)"]
        let r = try await FlimmerSend.sendAll(prepared, client: c, transcripts: true, replaceEdited: false)
        #expect(r.transcripts.count == 2 && r.transcripts.allSatisfy { !$0.ok })
        #expect(r.transcripts[0].reason == "edited_exists" && r.transcripts[0].message?.contains("corrected this transcript") == true)
        #expect(r.transcripts[1].reason == "unknown_clip")
        let lines = FlimmerSend.transcriptLines(r.transcripts)
        #expect(lines[0] == "No transcript went to Flimmer (2 refused); the sound did." && lines[1].hasPrefix("Transcript not sent: berattare. Flimmer said: A person corrected"))
        // Partial: one goes, one doesn't, and both are named.
        f.refuseTranscript = []
        f.edited = ["take-\(f.clips.count)"]
        let prepared2 = try await FlimmerSend.prepare(p, mode: .takes, client: c, render: render(pool))
        f.edited = ["take-\(f.clips.count)"]
        f.refuseTranscript = ["take-\(f.clips.count + 1)"]
        let partial = try await FlimmerSend.sendAll(prepared2, client: c, transcripts: true, replaceEdited: true)
        #expect(partial.transcripts.map(\.ok) == [true, false] && partial.transcripts[0].replacedEdited, "\(partial.transcripts)")
        #expect(FlimmerSend.transcriptLines(partial.transcripts) == [
            "1 of 2 transcripts went to Flimmer; 1 didn't.",
            "Transcript sent: berattare (it replaced one corrected by hand in Flimmer)",
            "Transcript not sent: musik. Flimmer said: No audio clip take-\(f.clips.count - 1) in the open project. [unknown_clip]"])
        #expect(f.undoSteps.last == "Jämmer ersatte ett rättat transkript.")
        // A failed plan: nothing of the transcripts is sent.
        let sentBefore = f.transcriptBodies.count
        let prepared3 = try await FlimmerSend.prepare(p, mode: .takes, client: c, render: render(pool))
        f.projectId = "OTHER"
        let failed = await failure { _ = try await FlimmerSend.sendAll(prepared3, client: c, transcripts: true, replaceEdited: false) }
        #expect(failed?.reason == "wrong_project" && f.transcriptBodies.count == sentBefore)
    }

    @Test("The source of a transcript by its engine: on this Mac local, OpenAI and ElevenLabs (Scribe, Overdub's speech) not, with the provider")
    func transcriptSources() {
        #expect(FlimmerSend.transcriptSource(engine: "apple-dictation")["local"] == .bool(true))
        #expect(FlimmerSend.transcriptSource(engine: "parakeet-tdt-0.6b-v3") == ["app": .string("jammer"), "engine": .string("parakeet"), "model": .string("tdt-0.6b-v3"), "local": .bool(true)])
        #expect(FlimmerSend.transcriptSource(engine: "openai gpt-4o-transcribe")["provider"] == .string("openai"))
        #expect(FlimmerSend.transcriptSource(engine: "overdub")["provider"] == .string("elevenlabs") && FlimmerSend.transcriptSource(engine: "overdub")["local"] == .bool(false))
    }
}
