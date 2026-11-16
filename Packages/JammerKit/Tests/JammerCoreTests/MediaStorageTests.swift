import Foundation
import Testing
@testable import JammerCore

@Suite("Storage: what takes room, what can be let go, and what is never touched")
struct MediaStorageTests {
    /// A media folder with files, and a project that plays from some of them.
    static func file(_ name: String, in media: URL, bytes: Int = 1_000) -> URL {
        let url = media.appending(path: name)
        try? Data(count: bytes).write(to: url)
        return url
    }
    static func project(playing urls: [URL]) -> Project {
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: 48_000, chunks: [], bext: nil, ixml: nil, markers: [])
        var p = Project(source: SourceRef(name: urls[0].lastPathComponent, path: urls[0].path, info: info))
        for u in urls.dropFirst() { _ = p.addTrack(source: SourceRef(name: u.lastPathComponent, path: u.path, info: info), name: u.lastPathComponent) }
        return p
    }

    @Test("Only what Jämmer made and registered can ever be freed; in use by a project's present or its history, it isn't; a project out of reach makes its files unknown")
    func groups() throws {
        let dir = TempDir(), media = dir.url.appending(path: "Media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let original = Self.file("voice.wav", in: media, bytes: 5_000)        // imported: no row, ever
        let old = Self.file("1234 echo.wav", in: media, bytes: 2_000)         // made before the register: no row
        let now = Self.file("aaaa duck.wav", in: media, bytes: 3_000)
        let branch = Self.file("bbbb echo.wav", in: media, bytes: 4_000)
        let loose = Self.file("cccc limit.wav", in: media, bytes: 6_000)
        let away = Self.file("dddd frozen.wav", in: media, bytes: 7_000)
        for (url, kind) in [(now, "duck"), (branch, "echo"), (loose, "limit"), (away, "frozen")] { MediaRegister.made(url, kind: kind, in: media) }
        // A file made somewhere else is not registered.
        MediaRegister.made(dir.url.appending(path: "elsewhere duck.wav"), kind: "duck", in: media)
        guard case .read(let register) = MediaRegister.state(media) else { Issue.record("no register"); return }
        #expect(Set(register.files.keys) == ["aaaa duck.wav", "bbbb echo.wav", "cccc limit.wav", "dddd frozen.wav"])

        // One open project: it plays the original and the ducked file now, and an older step on a branch
        // of its history played the echo.
        let present = Self.project(playing: [original, now]), earlier = Self.project(playing: [original, branch])
        let open = MediaStorage.Known(name: "Episode", location: "/projects/Episode.jammer", states: [present, earlier])
        // A project on a disk that isn't here used the frozen file when it was last seen.
        MediaRegister.seen(["dddd frozen.wav"], usedBy: "/Volumes/Away/Film.jammer", in: media)
        MediaRegister.seen(["aaaa duck.wav", "bbbb echo.wav", "voice.wav"], usedBy: open.location, in: media)

        let report = MediaStorage.report(media: media, known: [open])
        func group(_ name: String) -> MediaStorage.Group? { report.files.first { $0.name == name }?.group }
        #expect(report.register == "read" && report.files.count == 6)
        #expect(group("voice.wav") == .unregistered && group("1234 echo.wav") == .unregistered)
        #expect(group("aaaa duck.wav") == .inUse && group("bbbb echo.wav") == .inUse, "a file a branch of the history needs is in use")
        #expect(group("cccc limit.wav") == .canBeFreed)
        #expect(group("dddd frozen.wav") == .unknown && report.files.first { $0.name == "dddd frozen.wav" }?.projects == ["/Volumes/Away/Film.jammer"])
        #expect(report.bytes(.canBeFreed) == 6_000 && report.bytes(.unregistered) == 7_000 && report.bytes(.inUse) == 7_000 && report.bytes(.unknown) == 7_000)

        // Dry run: says what would go, moves nothing. For real: the same files, to the Trash (here a folder).
        let bin = dir.url.appending(path: "Trash")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let trash: (URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: bin.appending(path: $0.lastPathComponent)) }
        let dry = try MediaStorage.moveToTrash(["cccc limit.wav"], media: media, known: [open], dryRun: true, trash: trash)
        #expect(dry == .init(names: ["cccc limit.wav"], bytes: 6_000, dryRun: true) && FileManager.default.fileExists(atPath: loose.path))
        // Anything else in the request: nothing is moved at all.
        for name in ["voice.wav", "1234 echo.wav", "aaaa duck.wav", "bbbb echo.wav", "dddd frozen.wav", "not there.wav", "../outside.wav"] {
            #expect(throws: MediaStorage.Refusal.self) { try MediaStorage.moveToTrash(["cccc limit.wav", name], media: media, known: [open], dryRun: false, trash: trash) }
        }
        let binned = try FileManager.default.contentsOfDirectory(atPath: bin.path)
        #expect(FileManager.default.fileExists(atPath: loose.path) && binned.isEmpty)
        let real = try MediaStorage.moveToTrash(["cccc limit.wav"], media: media, known: [open], dryRun: false, trash: trash)
        #expect(real.names == dry.names && real.bytes == dry.bytes && !real.dryRun)
        #expect(!FileManager.default.fileExists(atPath: loose.path) && FileManager.default.fileExists(atPath: bin.appending(path: "cccc limit.wav").path))
        let after = MediaStorage.report(media: media, known: [open])
        #expect(after.files.count == 5 && after.trashed.map(\.name) == ["cccc limit.wav"] && after.bytes(.canBeFreed) == 0)
        // A project that needs the file later is told where it went.
        #expect(MediaStorage.trashedHint(for: loose.path, media: media)?.contains("moved to the Trash") == true)
        #expect(MediaStorage.trashedHint(for: original.path, media: media) == nil)

        // The project closes: what it used is not "used by nobody". Its file on disk still names it, so
        // while the project can be read its files are in use; were it out of reach, they would be unknown.
        let closedButReadable = MediaStorage.report(media: media, known: [open])
        #expect(closedButReadable.files.first { $0.name == "aaaa duck.wav" }?.group == .inUse)
        let closedAndAway = MediaStorage.report(media: media, known: [])
        #expect(closedAndAway.files.first { $0.name == "aaaa duck.wav" }?.group == .unknown && closedAndAway.bytes(.canBeFreed) == 0)
        // The away project seen again, no longer using the frozen file: now it can be freed.
        let back = MediaStorage.Known(name: "Film", location: "/Volumes/Away/Film.jammer", states: [Self.project(playing: [original])])
        #expect(MediaStorage.report(media: media, known: [open, back]).files.first { $0.name == "dddd frozen.wav" }?.group == .canBeFreed)
        // An untitled document closed without saving is gone for certain: what only it used is free.
        let scratch = Self.file("eeee echo.wav", in: media)
        MediaRegister.made(scratch, kind: "echo", in: media)
        MediaRegister.seen(["eeee echo.wav"], usedBy: "untitled:42", in: media)
        #expect(MediaStorage.report(media: media, known: [open]).files.first { $0.name == "eeee echo.wav" }?.group == .unknown)
        MediaRegister.forget(project: "untitled:42", in: media)
        #expect(MediaStorage.report(media: media, known: [open]).files.first { $0.name == "eeee echo.wav" }?.group == .canBeFreed)
    }

    @Test("No register, or one that can't be read: nothing can be freed, and a broken one is not written over")
    func registerStates() throws {
        let dir = TempDir(), media = dir.url.appending(path: "Media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let made = Self.file("aaaa echo.wav", in: media)
        var report = MediaStorage.report(media: media, known: [])
        #expect(report.register == "none" && report.files.map(\.group) == [.unregistered])
        #expect(throws: MediaStorage.Refusal.self) { try MediaStorage.moveToTrash(["aaaa echo.wav"], media: media, known: [], dryRun: true) }
        // A broken register: read as broken, and left exactly as it is by everything that would write.
        let registerURL = media.appending(path: MediaRegister.fileName)
        try Data("{ not json".utf8).write(to: registerURL)
        MediaRegister.made(made, kind: "echo", in: media)
        MediaRegister.seen(["aaaa echo.wav"], usedBy: "x", in: media)
        #expect(try String(contentsOf: registerURL, encoding: .utf8) == "{ not json")
        report = MediaStorage.report(media: media, known: [])
        #expect(report.register == "broken" && report.files.map(\.group) == [.unregistered] && report.files.map(\.name) == ["aaaa echo.wav"])
        #expect(throws: MediaStorage.Refusal.self) { try MediaStorage.moveToTrash(["aaaa echo.wav"], media: media, known: [], dryRun: false) }
        #expect(FileManager.default.fileExists(atPath: made.path))
        // The register itself is never listed as a file to free.
        try FileManager.default.removeItem(at: registerURL)
        MediaRegister.made(made, kind: "echo", in: media)
        #expect(!MediaStorage.report(media: media, known: []).files.contains { $0.name == MediaRegister.fileName })
    }
}
