import Foundation
import Testing
@testable import JammerCore

/// A project package is shared between people and opened with a double-click: untrusted input.
/// Nothing in one may make Jämmer read a file as audio that isn't the audio it says, read
/// outside the package through a path or a link, or act on sizes and positions that can't be.
@Suite("Hostile project packages")
struct HostileProjectTests {
    let sr = 48_000.0

    func folder() throws -> URL {
        // The real location, as the sandbox and the checks see it.
        let d = SourcePool.real(FileManager.default.temporaryDirectory).appending(path: "jammer-hostile-project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A package on disk with one second of tone in Media/ and a project that plays it.
    func package(in dir: URL, name: String = "P.jammer") throws -> (URL, Project) {
        let pkg = dir.appending(path: name)
        try FileManager.default.createDirectory(at: pkg.appending(path: "Media"), withIntermediateDirectories: true)
        let tone = pkg.appending(path: "Media/tone.wav")
        try Hostile.wav(frames: 48_000).write(to: tone)
        var source = SourceRef(name: "tone", path: tone.path, info: try AudioFileReader.info(at: tone))
        source.packagePath = "Media/tone.wav"
        let project = Project(source: source)
        try ProjectPackage.encode(project).write(to: pkg.appending(path: "project.json"))
        return (pkg, project)
    }

    func open(_ pkg: URL) throws -> (project: Project, notes: [String]) {
        try ProjectPackage.readChecked(try FileWrapper(url: pkg, options: [.immediate]), packageURL: pkg)
    }

    /// Everything the project would play, as samples.
    func render(_ p: Project, pool: SourcePool = SourcePool()) -> [Float] {
        guard p.length > 0 else { return [] }
        return PlanCompiler.compile(p, pool: pool).render(from: 0, frames: Int(min(p.length, 96_000)))
    }

    func rewrite(_ pkg: URL, _ change: (inout [String: Any]) -> Void) throws {
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: pkg.appending(path: "project.json"))) as! [String: Any]
        change(&json)
        try JSONSerialization.data(withJSONObject: json).write(to: pkg.appending(path: "project.json"))
    }

    @Test("A good package opens and plays; the project file cut off or corrupted is refused in words")
    func manifest() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (pkg, _) = try package(in: dir)
        let good = try open(pkg)
        #expect(good.notes.isEmpty && good.project.length == 48_000 && render(good.project).contains { $0 != 0 })
        let manifest = try Data(contentsOf: pkg.appending(path: "project.json"))
        var random = Hostile.Random(state: 5)
        var refused = 0
        for cut in [0, 1, 10, manifest.count / 3, manifest.count / 2, manifest.count - 2] {
            try manifest.prefix(cut).write(to: pkg.appending(path: "project.json"))
            #expect(throws: AudioFileError.self) { _ = try open(pkg) }
        }
        // Two hundred manifests with bytes changed: refused, or opened as something that passes every check.
        for _ in 0..<200 {
            var d = [UInt8](manifest)
            for _ in 0..<(1 + Int(random.next() % 4)) { d[Int(random.next() % UInt64(d.count))] = UInt8(truncatingIfNeeded: random.next()) }
            try Data(d).write(to: pkg.appending(path: "project.json"))
            do {
                let p = try open(pkg).project
                for c in p.tracks.flatMap(\.clips) { #expect(c.length > 0 && c.start >= 0 && c.sourceStart >= 0 && c.gainDB.isFinite) }
                _ = render(p)
            } catch is AudioFileError { refused += 1 } catch { Issue.record("an error that isn't Jämmer's own: \(error)") }
        }
        #expect(refused > 20)
        try FileManager.default.removeItem(at: pkg.appending(path: "project.json"))
        #expect(throws: AudioFileError.unreadable("The project has no project.json.")) { _ = try open(pkg) }
    }

    @Test("Sizes and positions that can't be: too many tracks, clips outside their audio or the timeline, absurd levels, impossible sample rates")
    func values() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (pkg, base) = try package(in: dir)
        let source = base.sources[0]
        func clip(start: Frame = 0, sourceStart: Frame = 0, length: Frame = 1_000, gain: Double = 0, fade: Frame = 0) -> Clip {
            Clip(sourceID: source.id, sourceStart: sourceStart, start: start, length: length, gainDB: gain, fadeIn: fade, fadeOut: fade)
        }
        var p = base
        p.tracks[0].clips = [clip(), clip(start: -5), clip(sourceStart: -1), clip(length: 0), clip(length: -7), clip(start: Frame.max - 10, length: 100),
                             clip(sourceStart: 47_000, length: 5_000), clip(sourceStart: 48_000), clip(sourceStart: Frame.max), clip(length: Frame.max),
                             clip(gain: 1e300), clip(gain: -1e300), clip(fade: Frame.max), Clip(sourceID: UUID(), start: 0, length: 10)]
        p.tracks[0].gainDB = 1e300
        p.markers = [Marker(position: -1, name: "before"), Marker(position: 10, length: -3, name: "negative"), Marker(position: Frame.max, name: "far"), Marker(position: 5, name: "ok")]
        try ProjectPackage.encode(p).write(to: pkg.appending(path: "project.json"))
        let opened = try open(pkg)
        let clips = opened.project.tracks[0].clips
        // What can be played stays, clamped to its audio; the rest is left out and said.
        #expect(clips.count == 6 && opened.notes.contains("8 clips pointed outside their audio or the timeline and were left out."), "\(clips.count) \(opened.notes)")
        #expect(clips.allSatisfy { $0.sourceStart + $0.length <= 48_000 && $0.fadeIn <= $0.length && (-200...60).contains($0.gainDB) } && opened.project.tracks[0].gainDB == 60)
        #expect(opened.project.markers.map(\.name) == ["ok"] && opened.notes.contains("3 markers outside the timeline were left out."))
        _ = render(opened.project)
        #expect(opened.project.length <= 48_000 + 1_000)
        // Refused outright.
        func refusal(_ change: (inout Project) -> Void, limits: ProjectSafety.Limits = .init()) -> String? {
            var q = base
            change(&q)
            do { _ = try ProjectPackage.decodeChecked(try ProjectPackage.encode(q), limits: limits); return nil } catch { return error.localizedDescription }
        }
        var small = ProjectSafety.Limits()
        small.tracks = 3; small.clips = 5; small.markers = 2; small.sources = 2
        #expect(refusal({ $0.tracks = (0..<4).map { Track(name: "t\($0)") } }, limits: small) == "The project can't be opened: it has 4 tracks, and Jämmer takes at most 3.")
        #expect(refusal({ $0.tracks[0].clips = (0..<6).map { _ in clip() } }, limits: small)?.contains("6 clips") == true)
        #expect(refusal({ $0.markers = (0..<3).map { Marker(position: Frame($0), name: "m") } }, limits: small)?.contains("3 markers") == true)
        #expect(refusal({ $0.sources += [source, source] }, limits: small)?.contains("3 audio files") == true)
        #expect(refusal { $0.sampleRate = 4e9 }?.contains("sample rate") == true && refusal { $0.sampleRate = 0 } != nil && refusal { $0.channels = 0 } != nil && refusal { $0.channels = 70_000 } != nil)
        small.bytes = 100
        #expect(refusal({ _ in }, limits: small)?.contains("larger than any real project") == true)
        // The real limits take a real project.
        #expect(refusal { _ in } == nil && ProjectSafety.Limits().tracks == 1_024 && ProjectSafety.Limits().clips == 500_000)
    }

    @Test("Paths that point out of the package (.., absolute, deeper folders, links) are not followed; nothing outside is read")
    func paths() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (pkg, _) = try package(in: dir)
        // A real audio file outside the package, which a hostile project would like to play.
        let outside = dir.appending(path: "private-recording.wav")
        try Hostile.wav(frames: 48_000).write(to: outside)
        for path in ["../private-recording.wav", "Media/../../private-recording.wav", outside.path, "Media/sub/tone.wav", "Media/", "Media", "", "Media/..", "Media/.", "media/tone.wav", "Media//tone.wav", "Media/tone.wav/"] {
            try rewrite(pkg) { json in
                var sources = json["sources"] as! [[String: Any]]
                sources[0]["packagePath"] = path
                sources[0]["path"] = outside.path
                json["sources"] = sources
            }
            let o = try open(pkg)
            #expect(o.project.sources[0].path == "" && o.notes.count == 1, "\(path): \(o.project.sources[0].path)")
            let pool = SourcePool()
            #expect(render(o.project, pool: pool).allSatisfy { $0 == 0 } && pool.missing.count == 1, "\(path) was played")
        }
        // A link in Media/ to the file outside, and Media itself as a link to a folder outside.
        try rewrite(pkg) { json in
            var sources = json["sources"] as! [[String: Any]]
            sources[0]["packagePath"] = "Media/link.wav"
            json["sources"] = sources
        }
        try FileManager.default.createSymbolicLink(at: pkg.appending(path: "Media/link.wav"), withDestinationURL: outside)
        var o = try open(pkg)
        #expect(o.project.sources[0].path == "" && render(o.project).allSatisfy { $0 == 0 }, "a link in Media/ was followed")
        let elsewhere = dir.appending(path: "elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Hostile.wav(frames: 48_000).write(to: elsewhere.appending(path: "tone.wav"))
        try FileManager.default.removeItem(at: pkg.appending(path: "Media"))
        try FileManager.default.createSymbolicLink(at: pkg.appending(path: "Media"), withDestinationURL: elsewhere)
        try rewrite(pkg) { json in
            var sources = json["sources"] as! [[String: Any]]
            sources[0]["packagePath"] = "Media/tone.wav"
            json["sources"] = sources
        }
        o = try open(pkg)
        #expect(o.project.sources[0].path == "" && render(o.project).allSatisfy { $0 == 0 }, "Media as a link was followed")
    }

    @Test("A project can't make another file be read as audio: the file must itself say it is that audio")
    func notAsDescribed() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (_, base) = try package(in: dir)
        // A secret that isn't audio, described by the project as 16-bit PCM from byte 0.
        let secret = dir.appending(path: "id_rsa")
        let bytes = Data((0..<40_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        try bytes.write(to: secret)
        var info = base.sources[0].info
        info.dataOffset = 0
        info.frames = 10_000
        var p = Project(source: SourceRef(name: "audio", path: secret.path, info: info))
        var pool = SourcePool()
        #expect(render(p, pool: pool).allSatisfy { $0 == 0 }, "a file that isn't audio was played")
        #expect(pool.refused.values.contains(.notAsDescribed(secret)) && pool.read(p.sources[0], from: 0, count: 100).isEmpty)
        // A real WAV, but the project lies about where its sound starts, how much there is, or what kind it is.
        let real = dir.appending(path: "real.wav")
        try Hostile.wav(frames: 48_000).write(to: real)
        let truth = try AudioFileReader.info(at: real)
        for (what, change) in [("offset", { (i: inout AudioFileInfo) in i.dataOffset = 0 }), ("channels", { $0.channels = 1 }), ("rate", { $0.sampleRate = 44_100 }),
                               ("format", { $0.sampleFormat = .float32 }), ("endianness", { $0.bigEndian = true })] as [(String, (inout AudioFileInfo) -> Void)] {
            var lie = truth
            change(&lie)
            p = Project(source: SourceRef(name: "real", path: real.path, info: lie))
            pool = SourcePool()
            #expect(render(p, pool: pool).allSatisfy { $0 == 0 } && pool.refused.count == 1, "\(what)")
        }
        // Claiming more sound than the file has plays what is there and silence after it, never past the file.
        var long = truth
        long.frames = 480_000
        p = Project(source: SourceRef(name: "real", path: real.path, info: long))
        let out = PlanCompiler.compile(p, pool: SourcePool()).render(from: 47_990, frames: 20)
        #expect(out[0..<20].contains { $0 != 0 } && out[20...].allSatisfy { $0 == 0 })
        // And the truth plays.
        p = Project(source: SourceRef(name: "real", path: real.path, info: truth))
        pool = SourcePool()
        #expect(render(p, pool: pool).contains { $0 != 0 } && pool.refused.isEmpty && pool.missing.isEmpty)
    }

    @Test("A document reads only where it may: a file outside is refused by its real location, also through a link")
    func policy() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let allowed = dir.appending(path: "allowed"), other = dir.appending(path: "other")
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Hostile.wav(frames: 4_800).write(to: allowed.appending(path: "in.wav"))
        try Hostile.wav(frames: 4_800).write(to: other.appending(path: "out.wav"))
        try FileManager.default.createSymbolicLink(at: allowed.appending(path: "link.wav"), withDestinationURL: other.appending(path: "out.wav"))
        func played(_ file: URL, restricted: Bool = true) throws -> (Bool, SourcePool) {
            let pool = SourcePool()
            if restricted { pool.restrict { $0.path.hasPrefix(allowed.path + "/") } }
            let p = Project(source: SourceRef(name: "x", path: file.path, info: try AudioFileReader.info(at: file)))
            return (render(p, pool: pool).contains { $0 != 0 }, pool)
        }
        #expect(try played(allowed.appending(path: "in.wav")).0)
        var (heard, pool) = try played(other.appending(path: "out.wav"))
        #expect(!heard && pool.refused.values.contains(.notAllowed(other.appending(path: "out.wav"))))
        (heard, pool) = try played(allowed.appending(path: "link.wav"))
        #expect(!heard && pool.refused.values.contains(.notAllowed(other.appending(path: "out.wav"))), "a link out of the allowed folder was followed")
        (heard, pool) = try played(allowed.appending(path: "../other/out.wav"))
        #expect(!heard)
        // When the user allows it after all, it plays.
        let p = Project(source: SourceRef(name: "x", path: other.appending(path: "out.wav").path, info: try AudioFileReader.info(at: other.appending(path: "out.wav"))))
        pool = SourcePool()
        pool.restrict { _ in false }
        #expect(render(p, pool: pool).allSatisfy { $0 == 0 })
        pool.restrict(nil)
        #expect(render(p, pool: pool).contains { $0 != 0 } && pool.refused.isEmpty)
    }

    @Test("Collecting audio into the package never copies a file the document was refused")
    func collect() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mine = dir.appending(path: "mine.wav"), theirs = dir.appending(path: "private.wav")
        try Hostile.wav(frames: 4_800).write(to: mine)
        try Hostile.wav(frames: 4_800).write(to: theirs)
        let a = SourceRef(name: "mine", path: mine.path, info: try AudioFileReader.info(at: mine))
        let b = SourceRef(name: "private", path: theirs.path, info: try AudioFileReader.info(at: theirs))
        var p = Project(source: a)
        _ = p.addTrack(source: b)
        // Unrestricted, both would be copied; with the second refused, only the first.
        #expect(ProjectPackage.planCollection(p, existingMedia: []).copies.map(\.name) == ["mine.wav", "private.wav"])
        let pool = SourcePool()
        pool.restrict { $0.lastPathComponent == "mine.wav" }
        _ = PlanCompiler.compile(p, pool: pool).render(from: 0, frames: 100)
        let plan = ProjectPackage.planCollection(p, existingMedia: [], skipping: Set(pool.refused.keys).union(pool.missing))
        #expect(plan.copies.map(\.name) == ["mine.wav"] && plan.project.sources[1].packagePath == nil)
    }

    @Test("History in the package: a state that expands without end, a damaged one and an absurd one are refused")
    func history() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (_, base) = try package(in: dir)
        var h = try History(root: base)
        var edited = base
        try edited.changeGain(0..<1_000, by: -3)
        try h.record(edited, action: "Gain")
        // Saved and read back as the package does: both states come out, checked.
        var read = try JSONDecoder().decode(History.self, from: JSONEncoder().encode(h))
        #expect(try read.project(of: read.current) == edited)
        // The decompressor stops at its limit: 8 MB of zeros is a few hundred bytes compressed.
        let bomb = try (Data(count: 8 << 20) as NSData).compressed(using: .lzfse) as Data
        #expect(bomb.count < 16_384)
        #expect(throws: AudioFileError.self) { _ = try ProjectSafety.decompress(bomb, limit: 1 << 20) }
        #expect(try ProjectSafety.decompress(bomb, limit: 16 << 20).count == 8 << 20)
        #expect(throws: AudioFileError.self) { _ = try ProjectSafety.decompress(Data("not lzfse at all, just text".utf8), limit: 1 << 20) }
        #expect(try ProjectSafety.decompress(Data(), limit: 10).isEmpty)
        // A history whose state is a bomb, garbage, or a project with a sample rate of four billion.
        func tampered(_ body: Data) throws -> History {
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(h)) as! [String: Any]
            var nodes = json["nodes"] as! [[String: Any]]
            nodes[nodes.count - 1]["body"] = body.base64EncodedString()
            json["nodes"] = nodes
            return try JSONDecoder().decode(History.self, from: JSONSerialization.data(withJSONObject: json))
        }
        var absurd = base
        absurd.sampleRate = 4e9
        for body in [try (Data(count: 600 << 20) as NSData).compressed(using: .lzfse) as Data, Data("garbage".utf8),
                     try (ProjectPackage.encode(absurd) as NSData).compressed(using: .lzfse) as Data] {
            read = try tampered(body)
            #expect(throws: AudioFileError.self) { _ = try read.project(of: read.current) }
        }
    }

    /// Writes a few packages for trying in the app by hand (JAMMER_WRITE_PACKAGES=<folder>).
    @Test("Packages for trying in the app", .enabled(if: ProcessInfo.processInfo.environment["JAMMER_WRITE_PACKAGES"] != nil))
    func writePackages() async throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JAMMER_WRITE_PACKAGES"]!)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir.appending(path: "elsewhere"), withIntermediateDirectories: true)
        // Honest: its sound is inside it.
        _ = try package(in: dir, name: "Own.jammer")
        // Names a real recording in another folder.
        let outside = dir.appending(path: "elsewhere/private-recording.wav")
        try Hostile.wav(frames: 96_000).write(to: outside)
        func write(_ name: String, _ source: SourceRef) throws {
            let pkg = dir.appending(path: name)
            try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
            try ProjectPackage.encode(Project(source: source)).write(to: pkg.appending(path: "project.json"))
        }
        try write("Outside.jammer", SourceRef(name: "private-recording", path: outside.path, info: try AudioFileReader.info(at: outside)))
        // Describes a file that isn't audio as 16-bit sound.
        let secret = dir.appending(path: "elsewhere/secret.txt")
        try Data(String(repeating: "TOP-SECRET-CONTENT ", count: 4_000).utf8).write(to: secret)
        var lie = try AudioFileReader.info(at: outside)
        lie.dataOffset = 0
        lie.frames = 15_000
        try write("Secret.jammer", SourceRef(name: "audio", path: secret.path, info: lie))
        // Says its sound is in the package, with a path that climbs out.
        var climbing = SourceRef(name: "private-recording", path: outside.path, info: try AudioFileReader.info(at: outside))
        climbing.packagePath = "../elsewhere/private-recording.wav"
        try write("Escape.jammer", climbing)
        // Damaged.
        try FileManager.default.createDirectory(at: dir.appending(path: "Broken.jammer"), withIntermediateDirectories: true)
        try Data("{\"formatVersion\": 1, \"tracks\": [".utf8).write(to: dir.appending(path: "Broken.jammer/project.json"))
        // Honest audio, and settings for a plugin (Apple's low-pass, turned down to 60 Hz) that weren't made in the app that opens it.
        let (pkg, plain) = try package(in: dir, name: "Settings.jammer")
        let unit = try await PluginInstance.make(PluginID("aufx/lpas/appl")!, channels: plain.channels, sampleRate: plain.sampleRate)
        try unit.set("global.0", to: 60)
        var withPlugin = plain
        withPlugin.tracks[0].inserts = [Insert(plugin: PluginID("aufx/lpas/appl")!, name: "AULowpass", state: unit.captureState())]
        try ProjectPackage.encode(withPlugin).write(to: pkg.appending(path: "project.json"))
    }
}
