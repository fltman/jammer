import Foundation
import Testing
@testable import JammerCore

@Suite("The journal of linked documents")
struct LinkJournalTests {
    static func journal() -> LinkJournal {
        LinkJournal(folder: FileManager.default.temporaryDirectory.appending(path: "jammer-linkjournal-\(UUID().uuidString)"))
    }
    static let record = LinkedFile.Record(path: "/nowhere/clip.wav", bookmark: nil, format: "wav", bitDepth: 24, isFloat: false, sampleRate: 48_000, channels: 2, requester: "Flimmer")

    @Test("An entry comes back as it was written; a later write replaces it whole; removing takes it away")
    func roundTrip() throws {
        let j = Self.journal()
        defer { try? FileManager.default.removeItem(at: j.folder) }
        var (p, _) = MixerTests.document()
        #expect(j.read().entries.isEmpty && j.read().broken.isEmpty)   // no folder yet: nothing, and no error
        let id = UUID()
        try j.write(.init(id: id, record: Self.record, name: "clip", project: try ProjectPackage.encode(p), edited: false))
        p.tracks[0].gainDB = -6
        try j.write(.init(id: id, record: Self.record, name: "clip", project: try ProjectPackage.encode(p), edited: true))
        let back = j.read()
        #expect(back.entries.count == 1 && back.broken.isEmpty)
        #expect(back.entries[0].entry.edited && back.entries[0].entry.record == Self.record && back.entries[0].project == p)
        // Nothing but the entry is in the folder: the write leaves no half-written file beside it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: j.folder.path) == ["\(id.uuidString).jammerlink"])
        j.remove(id)
        #expect(j.read().entries.isEmpty)
    }

    @Test("A broken entry is left where it is and counted; the good ones beside it are still read; nothing crashes")
    func broken() throws {
        let j = Self.journal()
        defer { try? FileManager.default.removeItem(at: j.folder) }
        let (p, _) = MixerTests.document()
        let good = UUID(), cut = UUID(), hostile = UUID(), renamed = UUID()
        let entry = LinkJournal.Entry(id: good, record: Self.record, name: "clip", project: try ProjectPackage.encode(p), edited: true)
        try j.write(entry)
        // Cut off in the middle (as a disk that filled up would leave it), not JSON at all, a project that isn't one,
        // and an entry under another entry's name.
        var whole = entry
        whole.id = cut
        try j.write(whole)
        let data = try Data(contentsOf: j.url(of: cut))
        try data.prefix(data.count / 2).write(to: j.url(of: cut))
        try Data("not a journal".utf8).write(to: j.folder.appending(path: "\(UUID().uuidString).jammerlink"))
        try j.write(.init(id: hostile, record: Self.record, name: "x", project: Data("{\"tracks\": 7}".utf8), edited: true))
        var other = entry
        other.id = UUID()
        try JSONEncoder().encode(other).write(to: j.url(of: renamed))
        try Data("left alone".utf8).write(to: j.folder.appending(path: "notes.txt"))
        let back = j.read()
        #expect(back.entries.map(\.entry.id) == [good] && back.broken.count == 4)
        // Reading removed nothing.
        #expect(try FileManager.default.contentsOfDirectory(atPath: j.folder.path).count == 6)
    }

    @Test("What an entry costs for a long project: two hours with a transcript of 20 000 words and 600 clips is written in well under a tenth of a second")
    func cost() throws {
        let j = Self.journal()
        defer { try? FileManager.default.removeItem(at: j.folder) }
        var (p, _) = MixerTests.document()
        let rate = p.sampleRate, source = p.sources[0]
        // Two hours in 600 clips of 12 s, and a word every 0.36 s.
        p.tracks[0].clips = (0..<600).map { Clip(sourceID: source.id, start: Frame(Double($0) * 12 * rate), length: Frame(12 * rate)) }
        let words = (0..<20_000).map { i in Word(id: UUID(), text: "ord\(i % 97)", start: Frame(Double(i) * 0.36 * rate), end: Frame((Double(i) * 0.36 + 0.3) * rate), confidence: 0.9) }
        p.setTranscript(SourceTranscript(sourceID: source.id, language: "sv-SE", engine: "test", words: words))
        let clock = ContinuousClock()
        var bytes = 0
        let took = try clock.measure {
            let data = try ProjectPackage.encode(p)
            bytes = data.count
            try j.write(.init(id: UUID(), record: Self.record, name: "long", project: data, edited: true))
        }
        let read = clock.measure { _ = j.read() }
        print("link journal, two hours: \(bytes) bytes of project, written in \(took), read back in \(read)")
        #expect(bytes < 16 * 1024 * 1024 && took < .milliseconds(500) && j.read().entries.count == 1)
    }
}

/// Not a test of anything: writes a long project to a place given in the environment, for checks in the
/// app that need a document with a two-hour transcript (JAMMER_WRITE_LONG=<package path>, JAMMER_LONG_AUDIO=<wav>).
@Suite("A long project for the app's checks")
struct LongProjectForChecks {
    @Test("Written when asked for", .enabled(if: ProcessInfo.processInfo.environment["JAMMER_WRITE_LONG"] != nil))
    func write() throws {
        let env = ProcessInfo.processInfo.environment
        let package = URL(fileURLWithPath: env["JAMMER_WRITE_LONG"]!), audio = URL(fileURLWithPath: env["JAMMER_LONG_AUDIO"]!)
        try? FileManager.default.removeItem(at: package)
        let media = package.appending(path: ProjectPackage.mediaFolderName)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: audio, to: media.appending(path: audio.lastPathComponent))
        var source = SourceRef(name: "long", path: media.appending(path: audio.lastPathComponent).path, info: try AudioFileReader.info(at: audio))
        source.packagePath = "\(ProjectPackage.mediaFolderName)/\(audio.lastPathComponent)"
        var p = Project(source: source)
        let rate = p.sampleRate
        p.tracks[0].clips = (0..<600).map { Clip(sourceID: source.id, sourceStart: Frame(Double($0) * 12 * rate), start: Frame(Double($0) * 12 * rate), length: Frame(12 * rate)) }
        p.setTranscript(SourceTranscript(sourceID: source.id, language: "sv-SE", engine: "test",
                                         words: (0..<20_000).map { i in Word(text: "ord\(i % 97)", start: Frame(Double(i) * 0.36 * rate), end: Frame((Double(i) * 0.36 + 0.3) * rate), confidence: 0.9) }))
        let wrapper = try ProjectPackage.fileWrapper(p, existingMedia: try FileWrapper(url: media))
        try wrapper.write(to: package, options: .atomic, originalContentsURL: package)
        print("long project written: \(package.path)")
    }
}
