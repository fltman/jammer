import CryptoKit
import Foundation
import Testing
import JammerCore
@testable import JammerAgent

@Suite("Batch")
struct BatchTests {
    func tone(_ url: URL, db: Double) throws {
        let n = 48_000 * 4
        let a = pow(10, db / 20)
        let x = (0..<n).flatMap { i -> [Float] in let v = Float(a * sin(2 * .pi * 440 * Double(i) / 48_000)); return [v, v] }
        let w = try WAVWriter(url: url, options: .init(encoding: .int24, channels: 2, sampleRate: 48_000))
        try w.write(x); try w.finish()
    }
    func hash(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }
    func folder() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "jammer-batch-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: d.appending(path: "in"), withIntermediateDirectories: true)
        return d
    }

    @Test("Lossy export at a target: the file as delivered is measured and corrected, and the result says by how much")
    func delivered() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appending(path: "in/a.wav")
        try tone(a, db: -30)
        let policy = FolderPolicy(allowed: [dir])
        func run(_ export: [String: Any], steps: [[String: Any]] = [], out: String) async throws -> BatchResult {
            let body: [String: Any] = ["files": [a.path], "output": dir.appending(path: out).path, "steps": steps, "export": export]
            return await BatchRunner.run(try BatchRequest.parse(body, policy: policy), media: dir.appending(path: "media"))
        }
        func measured(_ path: String) throws -> LoudnessResult {
            try #require(EncodedWriter.measureWritten(URL(fileURLWithPath: path), scratch: dir.appending(path: "media")))
        }
        // An explicit target on a file that is nowhere near it: the gain is found from the encoded file.
        let explicit = try await run(["format": "aac", "bitRate": 96_000, "targetLUFS": -18], out: "explicit")
        #expect(explicit.failed.isEmpty && explicit.loudnessFrom == ["file"], "\(explicit.failed)")
        #expect(abs((explicit.loudness[0] ?? 0) + 18) <= 0.1 && explicit.compensatedDB[0] > 5, "\(explicit.loudness) \(explicit.compensatedDB)")
        #expect(abs((try measured(explicit.outputs[0]).integrated ?? 0) + 18) <= 0.1)
        // A preset as the last step is the target too; the ceiling is the preset's.
        let preset = try await run(["format": "aac", "bitRate": 96_000], steps: [["op": "loudness_preset", "params": ["preset": "apple_podcasts"]]], out: "preset")
        #expect(abs((preset.loudness[0] ?? 0) + 16) <= 0.1 && preset.limitedByPeak == [false], "\(preset.loudness) \(preset.compensatedDB)")
        #expect(try measured(preset.outputs[0]).truePeak <= -1 + 0.05)
        // Switched off: one encode, nothing added.
        let off = try await run(["format": "aac", "targetLUFS": -18, "compensate": false], out: "off")
        #expect(off.compensatedDB == [0] && (off.loudness[0] ?? 0) < -25)
        // A lossless file has nothing to compensate: 0, measured on the file.
        let flac = try await run(["format": "flac"], steps: [["op": "loudness_preset", "params": ["preset": "apple_podcasts"]]], out: "flac")
        #expect(flac.compensatedDB == [0] && flac.loudnessFrom == ["file"] && abs((flac.loudness[0] ?? 0) + 16) <= 0.1)
        // Ogg Opus is read back and corrected like the others (macOS decodes it).
        let opus = try await run(["format": "opus", "targetLUFS": -18], out: "opus")
        #expect(opus.failed.isEmpty && opus.loudnessFrom == ["file"] && abs((opus.loudness[0] ?? 0) + 18) <= 0.1, "\(opus.failed) \(opus.loudness)")
        // Refused before anything runs.
        #expect(throws: BatchError.self) { try BatchRequest.parse(["files": [a.path], "output": dir.path, "export": ["format": "wav", "targetLUFS": -16]], policy: policy) }
        #expect(throws: BatchError.self) { try BatchRequest.parse(["files": [a.path], "output": dir.path, "export": ["format": "mp3", "targetLUFS": 3]], policy: policy) }
        #expect(throws: BatchError.self) { try BatchRequest.parse(["files": [a.path], "output": dir.path, "export": ["format": "aac", "loudness": -16]], policy: policy) }
    }

    @Test("Three files, one broken: two come out at the target loudness, the broken one is reported, the originals are untouched")
    func run() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appending(path: "in/a.wav"), b = dir.appending(path: "in/b.wav"), c = dir.appending(path: "in/c.wav")
        try tone(a, db: -30); try tone(b, db: -12)
        try Data("this is not audio".utf8).write(to: c)
        let before = [try hash(a), try hash(b), try hash(c)]
        let body: [String: Any] = ["folder": dir.appending(path: "in").path, "output": dir.appending(path: "out").path,
                                   "steps": [["op": "normalize", "params": ["target": "loudness", "level": -20]]], "export": ["format": "flac", "bitDepth": 24]]
        let request = try BatchRequest.parse(body, policy: FolderPolicy(allowed: [dir]))
        #expect(request.inputs.count == 3)
        let result = await BatchRunner.run(request, media: dir.appending(path: "media"))
        #expect(result.outputs.count == 2 && result.failed.count == 1 && result.failed[0].file.hasSuffix("c.wav") && result.failed[0].reason == "unreadable")
        for out in result.outputs {
            let url = URL(fileURLWithPath: out)
            #expect(url.lastPathComponent.hasSuffix(" (Jämmer).flac"))
            let r = try AudioImporter.importFile(url, mediaFolder: dir.appending(path: "media"))
            let p = Project(source: r.source)
            let l = LoudnessMeter.measure(PlanCompiler.compile(p, pool: SourcePool()), 0..<p.length).integrated ?? 0
            #expect(abs(l + 20) < 0.2, "\(url.lastPathComponent): \(l) LUFS")
        }
        #expect(result.loudness.count == 2 && result.loudness.allSatisfy { abs(($0 ?? 0) + 20) < 0.2 } && result.limitedByPeak == [false, false])
        // A target the peaks don't allow (a quiet tone with loud clicks): reported, not hidden.
        let peaky = dir.appending(path: "in/peaky.wav")
        let n = 48_000 * 4
        let x = (0..<n).flatMap { i -> [Float] in let v = Float(0.01 * sin(2 * .pi * 440 * Double(i) / 48_000)) + (i % 12_000 == 0 ? 0.9 : 0); return [v, v] }
        let w = try WAVWriter(url: peaky, options: .init(encoding: .int24, channels: 2, sampleRate: 48_000))
        try w.write(x); try w.finish()
        let loud = BatchRequest(inputs: [peaky], steps: [Step(op: "loudness_preset", params: ["preset": .string("spotify")])], output: dir.appending(path: "out"))
        let limited = await BatchRunner.run(loud, media: dir.appending(path: "media"))
        #expect(limited.limitedByPeak == [true] && ((limited.loudness.first ?? nil) ?? 0) < -15, "\(limited.loudness) \(limited.limitedByPeak)")
        try FileManager.default.removeItem(at: peaky)
        #expect([try hash(a), try hash(b), try hash(c)] == before)
        // Again without overwrite: the two are skipped, nothing rewritten.
        let again = await BatchRunner.run(request, media: dir.appending(path: "media"))
        #expect(again.skipped.count == 2 && again.outputs.isEmpty)
    }

    @Test("A recipe that puts a limiter on the master: the file written is under the ceiling")
    func masterLimiter() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Loud, with clicks between the samples' reach: a true peak well over the ceiling.
        let hot = dir.appending(path: "in/hot.wav")
        let n = 48_000 * 3
        let x = (0..<n).flatMap { i -> [Float] in
            let v = Float(0.7 * sin(2 * .pi * 997 * Double(i) / 48_000) + 0.25 * sin(2 * .pi * 11_025 * Double(i) / 48_000 + 0.7))
            return [v, v * 0.9]
        }
        let w = try WAVWriter(url: hot, options: .init(encoding: .int24, channels: 2, sampleRate: 48_000))
        try w.write(x); try w.finish()
        func peak(_ url: URL) throws -> Double {
            let r = try AudioImporter.importFile(url, mediaFolder: dir.appending(path: "check-\(UUID().uuidString.prefix(6))"))
            let p = Project(source: r.source)
            return LoudnessMeter.measure(PlanCompiler.compile(p, pool: SourcePool()), 0..<p.length).truePeak
        }
        #expect(try peak(hot) > -1)
        // (Another sample rate needs the converter, which this test target doesn't carry; that one is tried in the app.)
        for rate in [Double?.none] {
            var request = BatchRequest(inputs: [hot], steps: [Step(op: "set_master", params: ["ceiling": .number(-6)])], output: dir.appending(path: "out-\(Int(rate ?? 0))"))
            request.sampleRate = rate
            let result = await BatchRunner.run(request, media: dir.appending(path: "media"))
            let out = try #require(result.outputs.first, "\(result)")
            let measured = try peak(URL(fileURLWithPath: out))
            #expect(measured <= -6 && measured > -8, "at \(rate ?? 48_000): \(measured) dBTP")
        }
        // Without the limiter the same file comes out as hot as it went in.
        let plain = await BatchRunner.run(BatchRequest(inputs: [hot], steps: [], output: dir.appending(path: "plain")), media: dir.appending(path: "media"))
        #expect(try peak(URL(fileURLWithPath: try #require(plain.outputs.first))) > -1)
        // What a failure says: the ceiling, the peak that was measured, and what to do.
        let words = MasterCeilingError(ceilingDB: -1, truePeakDB: -0.62).localizedDescription
        #expect(words.contains("-1.0 dBTP") && words.contains("-0.62") && words.contains("Lower the master's level or raise the ceiling"))
    }

    @Test("Paths must lie in an allowed folder, also through symlinks and ..; output never lands on an input")
    func policy() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outside = try folder()
        defer { try? FileManager.default.removeItem(at: outside) }
        try tone(dir.appending(path: "in/a.wav"), db: -20)
        try tone(outside.appending(path: "in/secret.wav"), db: -20)
        try FileManager.default.createSymbolicLink(at: dir.appending(path: "in/link"), withDestinationURL: outside.appending(path: "in"))
        let policy = FolderPolicy(allowed: [dir])
        func reason(_ body: [String: Any], _ p: FolderPolicy? = policy) -> String? {
            do { _ = try BatchRequest.parse(body, policy: p); return nil } catch { return (error as? BatchError)?.reason }
        }
        let out = dir.appending(path: "out").path
        #expect(reason(["files": [dir.appending(path: "in/a.wav").path], "output": out]) == nil)
        #expect(reason(["files": [outside.appending(path: "in/secret.wav").path], "output": out]) == "folder_not_allowed")
        #expect(reason(["files": [dir.appending(path: "in/link/secret.wav").path], "output": out]) == "folder_not_allowed")
        #expect(reason(["files": [dir.path + "/in/../../" + outside.lastPathComponent + "/in/secret.wav"], "output": out]) == "folder_not_allowed")
        #expect(reason(["files": [dir.appending(path: "in/a.wav").path], "output": dir.appending(path: "in/link/out").path]) == "folder_not_allowed")
        #expect(reason(["files": [dir.appending(path: "in/a.wav").path], "output": out], FolderPolicy(allowed: [])) == "folder_not_allowed")
        #expect(reason(["files": ["relative.wav"], "output": out]) == "bad_request")
        // Same folder, no suffix, same format: the output would be the input.
        #expect(reason(["files": [dir.appending(path: "in/a.wav").path], "output": dir.appending(path: "in").path, "suffix": "", "overwrite": true]) == "would_overwrite_source")
        #expect(reason(["files": [dir.appending(path: "in/a.wav").path], "output": dir.appending(path: "in").path, "overwrite": true]) == nil)
        // A suffix never leads out of the output folder: its separators are only characters of the name (FileNames).
        let sneaky = try BatchRequest.parse(["files": [dir.appending(path: "in/a.wav").path], "output": out, "suffix": "/../../" + outside.lastPathComponent + "/x"], policy: policy)
        let dest = sneaky.destination(for: dir.appending(path: "in/a.wav"))
        #expect(dest.deletingLastPathComponent().standardizedFileURL.path == URL(fileURLWithPath: out).standardizedFileURL.path, "\(dest.path)")
        #expect(dest.lastPathComponent == "a-..-..-\(outside.lastPathComponent)-x.wav")
    }

    @Test("Timeline import: the file and the media it names must lie in an allowed folder")
    func timelineImport() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outside = FileManager.default.temporaryDirectory.appending(path: "jammer-outside-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try tone(dir.appending(path: "in/a.wav"), db: -20)
        try tone(outside.appending(path: "secret.wav"), db: -20)
        func fcpxml(_ src: String) -> Data {
            Data("""
            <fcpxml version="1.11"><resources><asset id="a1" name="a.wav" hasAudio="1"><media-rep kind="original-media" src="\(src)"/></asset></resources>
            <library><event><project name="P"><sequence audioRate="48k"><spine><gap offset="0s" start="0s" duration="4s">
            <asset-clip ref="a1" lane="-1" offset="1s" start="0s" duration="2s" audioRole="dialogue"/></gap></spine></sequence></project></event></library></fcpxml>
            """.utf8)
        }
        let policy = FolderPolicy(allowed: [dir])
        func reason(_ body: [String: Any]) -> String? {
            do { _ = try TimelineImport.check(body, policy: policy); return nil } catch { return (error as? BatchError)?.reason }
        }
        let good = dir.appending(path: "good.fcpxml"), leaks = dir.appending(path: "leaks.fcpxml"), dotdot = dir.appending(path: "dotdot.fcpxml")
        try fcpxml("in/a.wav").write(to: good)
        try fcpxml("file://\(outside.path)/secret.wav").write(to: leaks)
        try fcpxml("../\(outside.lastPathComponent)/secret.wav").write(to: dotdot)
        let t = try TimelineImport.check(["path": good.path], policy: policy)
        #expect(t.tracks.count == 1 && t.tracks[0].name == "dialogue" && t.media == [dir.appending(path: "in/a.wav")])
        // The timeline itself outside, media outside by an absolute path, by .., and through a symlink.
        try fcpxml("a.wav").write(to: outside.appending(path: "t.fcpxml"))
        #expect(reason(["path": outside.appending(path: "t.fcpxml").path]) == "folder_not_allowed")
        #expect(reason(["path": leaks.path]) == "folder_not_allowed")
        #expect(reason(["path": dotdot.path]) == "folder_not_allowed")
        try FileManager.default.createSymbolicLink(at: dir.appending(path: "in/link.wav"), withDestinationURL: outside.appending(path: "secret.wav"))
        let linked = dir.appending(path: "linked.fcpxml")
        try fcpxml("in/link.wav").write(to: linked)
        #expect(reason(["path": linked.path]) == "folder_not_allowed")
        #expect(reason(["path": "relative.fcpxml"]) == "bad_request" && reason(["path": good.path, "extra": 1]) == "bad_request")
        #expect(reason(["path": dir.appending(path: "none.fcpxml").path]) == "not_found")
        try Data("nope".utf8).write(to: dir.appending(path: "bad.fcpxml"))
        #expect(reason(["path": dir.appending(path: "bad.fcpxml").path]) == "unreadable")
        // Final Cut's bundle: a folder with Info.fcpxml inside. The rule covers the bundle and each media file.
        func bundle(_ at: URL, _ src: String) throws -> URL {
            try FileManager.default.createDirectory(at: at.appending(path: "media"), withIntermediateDirectories: true)
            try fcpxml(src).write(to: at.appending(path: "Info.fcpxml"))
            return at
        }
        let inside = try bundle(dir.appending(path: "Film.fcpxmld"), "media/b.wav")
        try tone(inside.appending(path: "media/b.wav"), db: -20)
        let b = try TimelineImport.check(["path": inside.path], policy: policy)
        #expect(b.media == [inside.appending(path: "media/b.wav")] && b.tracks[0].clips.count == 1)
        let built = try FCPXMLImport.build(b, mediaFolder: dir.appending(path: "decoded"))
        #expect(built.clips == 1 && built.project.tracks[0].clips[0].start == 48_000 && built.project.tracks[0].clips[0].length == 96_000)
        #expect(reason(["path": try bundle(dir.appending(path: "Leaky.fcpxmld"), "file://\(outside.path)/secret.wav").path]) == "folder_not_allowed")
        #expect(reason(["path": try bundle(outside.appending(path: "Out.fcpxmld"), "media/b.wav").path]) == "folder_not_allowed")
        try FileManager.default.createDirectory(at: dir.appending(path: "Empty.fcpxmld"), withIntermediateDirectories: true)
        #expect(reason(["path": dir.appending(path: "Empty.fcpxmld").path]) == "unreadable")
        // The menu command has no policy: the user chose the file.
        #expect(try TimelineImport.check(["path": leaks.path], policy: nil).media.count == 1)
    }

    @Test("Timeline import of EDL, OTIO and DAWproject: the same folder rule for each media file; rate for an EDL only; import/fcpxml still reads only FCPXML")
    func otherTimelines() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outside = FileManager.default.temporaryDirectory.appending(path: "jammer-outside-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try tone(dir.appending(path: "a.wav"), db: -20)
        try tone(outside.appending(path: "secret.wav"), db: -20)
        let policy = FolderPolicy(allowed: [dir])
        func reason(_ body: [String: Any], formats: [String]? = nil) -> String? {
            do { _ = try TimelineImport.check(body, policy: policy, formats: formats); return nil } catch { return (error as? BatchError)?.reason }
        }
        func edl(_ name: String, _ file: String) throws -> String {
            let u = dir.appending(path: name)
            try "TITLE: T\nFCM: NON-DROP FRAME\n\n001  AX       A     C        00:00:00:00 00:00:02:00 01:00:00:00 01:00:02:00\n* SOURCE FILE: \(file)\n".write(to: u, atomically: true, encoding: .utf8)
            return u.path
        }
        let good = try edl("good.edl", "a.wav"), leak = try edl("leak.edl", outside.appending(path: "secret.wav").path)
        let t = try TimelineImport.check(["path": good, "rate": "24"], policy: policy, formats: nil)
        #expect(t.media == [dir.appending(path: "a.wav")] && t.timecode?.rate == .fps24 && t.tracks[0].clips[0].duration.seconds == 2)
        #expect(reason(["path": leak]) == "folder_not_allowed")
        #expect(reason(["path": good, "rate": "26"]) == "bad_request" && reason(["path": good, "fps": 25]) == "bad_request")
        #expect(reason(["path": good], formats: ["fcpxml", "fcpxmld"]) == "bad_request", "import/fcpxml reads FCPXML only")
        // OTIO naming a file outside by file:// URL, and a DAWproject naming one by its absolute path.
        let otio = dir.appending(path: "t.otio")
        try Data(#"{"OTIO_SCHEMA":"Timeline.1","tracks":{"OTIO_SCHEMA":"Stack.1","children":[{"OTIO_SCHEMA":"Track.1","kind":"Audio","children":[{"OTIO_SCHEMA":"Clip.2","source_range":{"OTIO_SCHEMA":"TimeRange.1","start_time":{"OTIO_SCHEMA":"RationalTime.1","value":0,"rate":24},"duration":{"OTIO_SCHEMA":"RationalTime.1","value":24,"rate":24}},"media_references":{"DEFAULT_MEDIA":{"OTIO_SCHEMA":"ExternalReference.1","target_url":"SRC"}},"active_media_reference_key":"DEFAULT_MEDIA"}]}]}}"#
            .replacingOccurrences(of: "SRC", with: URL(fileURLWithPath: outside.appending(path: "secret.wav").path).absoluteString).utf8).write(to: otio)
        #expect(reason(["path": otio.path]) == "folder_not_allowed")
        #expect(reason(["path": otio.path, "rate": "25"]) == "bad_request", "rate is for an EDL only")
        var p = Project(sampleRate: 48_000, channels: 2)
        let src = SourceRef(name: "secret.wav", path: outside.appending(path: "secret.wav").path, info: try AudioFileReader.info(at: outside.appending(path: "secret.wav")))
        p.sources = [src]
        p.tracks = [Track(name: "T", clips: [Clip(sourceID: src.id, start: 0, length: 48_000)])]
        let daw = dir.appending(path: "t.dawproject")
        try DAWproject.write(ExchangeTimeline(p, name: "T"), appVersion: "1").data.write(to: daw)
        #expect(reason(["path": daw.path]) == "folder_not_allowed")
        #expect(try TimelineImport.check(["path": daw.path], policy: nil, formats: nil).media.count == 1, "the menu command has no policy")
    }

    @Test("Timeline export: closed body, a known format, refused on an empty document; the bytes are the format's")
    func timelineExport() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try tone(dir.appending(path: "a.wav"), db: -20)
        var p = Project(sampleRate: 48_000, channels: 2)
        func reason(_ body: [String: Any], _ p: Project) -> String? {
            do { _ = try TimelineExport.make(p, name: "x", body: body, appVersion: "1"); return nil } catch { return (error as? BatchError)?.reason }
        }
        #expect(reason(["format": "edl"], p) == "empty")
        let src = SourceRef(name: "a.wav", path: dir.appending(path: "a.wav").path, info: try AudioFileReader.info(at: dir.appending(path: "a.wav")))
        p.sources = [src]
        p.tracks = [Track(name: "T", clips: [Clip(sourceID: src.id, start: 0, length: 48_000)])]
        #expect(reason(["format": "aaf"], p) == "bad_request" && reason(["format": "edl", "path": "/x"], p) == "bad_request" && reason([:], p) == "bad_request")
        let edl = try TimelineExport.make(p, name: "x", body: ["format": "EDL"], appVersion: "1")
        #expect(String(decoding: edl.data, as: UTF8.self).hasPrefix("TITLE: x") && edl.fileExtension == "edl")
        let otio = try TimelineExport.make(p, name: "x", body: ["format": "otio"], appVersion: "1")
        #expect((try JSONSerialization.jsonObject(with: otio.data) as? [String: Any])?["OTIO_SCHEMA"] as? String == "Timeline.1")
        let daw = try TimelineExport.make(p, name: "x", body: ["format": "dawproject"], appVersion: "1")
        #expect(daw.data.prefix(2) == Data("PK".utf8) && daw.contentType == "application/zip")
    }
}

final class StopSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    func set() { lock.withLock { on = true } }
    var isSet: Bool { lock.withLock { on } }
}

@Suite("A batch stopped in the middle of a file")
struct BatchStopTests {
    func folder() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "jammer-batchstop-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: d.appending(path: "in"), withIntermediateDirectories: true)
        return d
    }
    func tone(_ url: URL) throws {
        let w = try WAVWriter(url: url, options: .init(encoding: .int24, channels: 1, sampleRate: 48_000))
        try w.write((0..<48_000).map { Float(0.1 * sin(Double($0) * 0.05)) }); try w.finish()
    }

    @Test("Stopped after a paid transcription came back: nothing is written to the output, and the transcript, paid for, is kept beside it as charged")
    func paidKept() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appending(path: "in/chapter.wav")
        try tone(a)
        let body: [String: Any] = ["files": [a.path], "output": dir.appending(path: "out").path, "export": ["format": "wav"],
                                   "jobs": [["op": "transcribe", "params": ["engine": "openai", "language": "sv-SE"]]], "allowPaid": true, "allowUnknownPrice": true]
        let request = try BatchRequest.parse(body, policy: FolderPolicy(allowed: [dir]))
        let stop = StopSwitch()
        // The provider answered, and then the stop came.
        let result = await BatchRunner.run(request, media: dir.appending(path: "media"), job: { _, project, _ in
            var p = project
            p.setTranscript(SourceTranscript(sourceID: p.sources[0].id, language: "sv-SE", engine: "openai", words: [Word(text: "betalt", start: 0, end: 4_800)]))
            stop.set()
            return p
        }, cancelled: { stop.isSet })
        #expect(result.outputs.isEmpty && !FileManager.default.fileExists(atPath: request.destination(for: a).path), "nothing written to the output")
        let kept = try #require(result.stoppedWithPaid.first)
        #expect(kept.file == a.path && kept.kept.contains("(stopped, charged)"))
        #expect(try String(contentsOf: URL(fileURLWithPath: kept.kept), encoding: .utf8).contains("betalt"), "the paid words are in it")
        #expect(result.json["stoppedWithPaid"] != nil)
    }

    @Test("Stopped during free work (a repair): nothing is written and nothing kept; the files after it aren't started")
    func freeDropped() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appending(path: "in/one.wav"), b = dir.appending(path: "in/two.wav")
        try tone(a); try tone(b)
        let body: [String: Any] = ["files": [a.path, b.path], "output": dir.appending(path: "out").path, "export": ["format": "wav"],
                                   "jobs": [["op": "restore", "params": ["kind": "dehum"]]]]
        let request = try BatchRequest.parse(body, policy: FolderPolicy(allowed: [dir]))
        let stop = StopSwitch()
        let calls = StopCount()
        let result = await BatchRunner.run(request, media: dir.appending(path: "media"), job: { _, project, _ in
            calls.add()
            stop.set()
            throw CancellationError()
        }, cancelled: { stop.isSet })
        #expect(result.outputs.isEmpty && result.stoppedWithPaid.isEmpty && result.failed.isEmpty, "\(result.failed)")
        #expect(calls.value == 1, "the second file wasn't started")
        let written = (try? FileManager.default.contentsOfDirectory(atPath: dir.appending(path: "out").path)) ?? []
        #expect(written.isEmpty, "\(written)")
    }
}

final class StopCount: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
