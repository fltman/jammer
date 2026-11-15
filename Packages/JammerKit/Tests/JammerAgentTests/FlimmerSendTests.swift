import Foundation
import Testing
import JammerCore
@testable import JammerAgent

/// A pretend Flimmer that follows SEND-TO-FLIMMER-API.md (v1) to the letter: uploads checked
/// by content, the whole plan validated first, dry run, job, one undo step.
final class PretendFlimmer: @unchecked Sendable {
    struct Clip { var id: String; var trackId: String; var timelineOffset: Double; var duration: Double; var linked: Bool; var relativeOffset = 0.5; var deleted = false; var muted = false }
    struct Track { var id: String; var name: String; var volume = 1.0; var muted = false; var locked = false }
    struct Upload { var name: String; var data: Data; var used = false; var open = false; var seconds: Double }

    let lock = NSLock()
    var projectId = "P1", stories = ["S1"]
    var clips: [Clip] = []
    var tracks: [Track] = []
    var uploads: [String: Upload] = [:]
    var jobs: [String: [String: Any]] = [:]
    var bitDepths = [16]
    var signedIn = true, viewer = false, hasEndpoint = true
    var undoSteps: [String] = []
    var seenHeaders: [[String: String]] = []
    var polls = 0
    var n = 0

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
        case ("GET", "/api/v1/operations"): return answer(200, ["operations": [], "uploads": ["wavBitDepths": bitDepths, "maxBytes": 1 << 30]], r)
        case ("POST", "/api/v1/uploads"):
            guard let body = r.httpBody, let seconds = wavSeconds(body) else { return fail(415, "unsupported_media", r) }
            n += 1
            let id = "up_\(n)"
            let name = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "name" }?.value ?? ""
            uploads[id] = Upload(name: name, data: body, seconds: seconds)
            return answer(201, ["upload": ["id": id, "name": name, "bytes": body.count]], r)
        case ("DELETE", let p) where p.hasPrefix("/api/v1/uploads/"):
            uploads[String(p.dropFirst("/api/v1/uploads/".count))] = nil
            return answer(200, [:], r)
        case ("GET", let p) where p.hasPrefix("/api/v1/jobs/"):
            polls += 1
            guard let job = jobs[String(p.dropFirst("/api/v1/jobs/".count))] else { return fail(404, "not_found", r) }
            return answer(200, ["job": job], r)
        case ("POST", "/api/v1/audio/sibling-plan"):
            guard hasEndpoint else { return fail(404, "not_found", r) }
            guard signedIn else { return fail(409, "not_available", r) }
            guard !viewer else { return fail(403, "forbidden", r) }
            return plan(try! JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any], r)
        default: return fail(404, "not_found", r)
        }
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
        for c in create where c["takeOf"] != nil {
            clips.append(Clip(id: "take-\(clips.count)", trackId: c["trackId"] as! String, timelineOffset: c["timelineOffset"] as! Double, duration: c["duration"] as! Double, linked: false))
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
            try FlimmerSend.wav(PlanCompiler.compile(item.render, pool: pool), range: item.range, bitDepth: depth, sampleRate: rate, scratch: FileManager.default.temporaryDirectory)
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
        #expect(info.sampleFormat == .int16 && info.sampleRate == 48_000 && info.channels == 2)
        let back = Project(source: try AudioImporter.importFile(scratch.appending(path: "t.wav"), mediaFolder: scratch).source)
        let x = PlanCompiler.compile(back, pool: SourcePool()).render(from: 0, frames: Int(4 * sr))
        func peak(_ a: Double, _ b: Double) -> Float { x[(Int(a * sr) * 2)..<(Int(b * sr) * 2)].map(abs).max() ?? 0 }
        #expect(abs(peak(0.1, 0.9) - 0.2) < 0.002 && abs(peak(1.1, 1.9) - 0.1002) < 0.002 && abs(peak(2.1, 3.9) - 0.2) < 0.002, "the −6 dB stretch is in the file, the track's −3 dB isn't")
        // The plan as sent: a position only for the moved clip, the right kind; headers as the protocol says.
        let items = prepared.body["items"]!.any as! [[String: Any]]
        #expect(items[0]["position"] == nil && (items[1]["position"] as? [String: Double]) == ["timelineOffset": 8.5])
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

    @Test("Finding Flimmer: the name must match, and a debug copy pairs only with a debug copy")
    func find() async {
        let f = flimmer()
        #expect(await FlimmerSend.find(transport: f.transport, debug: true) == URL(string: "http://127.0.0.1:9002"))
        #expect(await FlimmerSend.find(transport: f.transport, debug: false) == nil)
        let other: FlimmerSend.Transport = { r in
            (try! JSONSerialization.data(withJSONObject: ["app": ["name": "Glimmer", "bundleID": "com.brattoo.glimmer"]]), HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(await FlimmerSend.find(transport: other, debug: false) == nil)
    }
}
