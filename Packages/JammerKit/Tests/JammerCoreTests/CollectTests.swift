import Foundation
import Testing
@testable import JammerCore

@Suite("Collect and save")
struct CollectTests {
    private func source(_ url: URL) throws -> SourceRef {
        SourceRef(name: url.deletingPathExtension().lastPathComponent, path: url.path, info: try AudioFileReader.info(at: url))
    }

    @Test("Used sources are copied into Media with unique names; the package opens from its own copies")
    func collect() throws {
        let dir = TempDir()
        let a = dir.file("take.wav"), b = dir.file("sub/take.wav"), unused = dir.file("unused.wav")
        try FileManager.default.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sa = noise(count: 4_000, seed: 1), sb = noise(count: 4_000, seed: 2)
        try writeWAV(sa, to: a)
        try writeWAV(sb, to: b)
        try writeWAV(sb, to: unused)
        let ra = try source(a), rb = try source(b), ru = try source(unused)
        var missing = ra
        missing.id = UUID()
        missing.path = dir.file("gone.wav").path
        var project = Project(source: ra)
        project.sources += [rb, ru, missing]
        project.tracks.append(Track(name: "B", clips: [Clip(sourceID: rb.id, start: 0, length: 2_000), Clip(sourceID: missing.id, start: 0, length: 10)]))

        let (planned, copies) = ProjectPackage.planCollection(project, existingMedia: ["Take.wav"])
        #expect(copies.map(\.name) == ["take 2.wav", "take 3.wav"])
        #expect(planned.sources.map(\.packagePath) == ["Media/take 2.wav", "Media/take 3.wav", nil, nil])
        // Collecting again finds nothing more to do.
        #expect(ProjectPackage.planCollection(planned, existingMedia: []).copies.isEmpty)

        let package = dir.file("Show.jammer")
        try ProjectPackage.fileWrapper(planned, existingMedia: nil).write(to: package, originalContentsURL: nil)
        try ProjectPackage.copyMedia(copies, intoPackage: package)
        // Move the package somewhere else and remove the originals: it still plays from its copies.
        let moved = dir.file("elsewhere/Show.jammer")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: package, to: moved)
        try FileManager.default.removeItem(at: a)
        try FileManager.default.removeItem(at: b)
        let opened = try ProjectPackage.read(FileWrapper(url: moved), packageURL: moved)
        #expect(opened == ProjectPackage.resolvedInPackage(planned, package: moved))
        let pool = SourcePool()
        #expect(pool.read(opened.sources[0], from: 0, count: 2_000) == sa)
        #expect(pool.read(opened.sources[1], from: 0, count: 2_000) == sb)
        #expect(opened.sources[2].path == unused.path)
    }

    @Test("Names stay portable and unique, ignoring case")
    func names() {
        var taken: Set<String> = ["a.wav"]
        #expect(ProjectPackage.uniqueName(for: "A.WAV", taken: &taken) == "A 2.WAV")
        #expect(ProjectPackage.uniqueName(for: "a/b:c.wav", taken: &taken) == "a-b-c.wav")
        #expect(ProjectPackage.uniqueName(for: ".hidden", taken: &taken) == "hidden")
        #expect(ProjectPackage.uniqueName(for: "", taken: &taken) == "audio")
        #expect(ProjectPackage.uniqueName(for: "noext", taken: &taken) == "noext")
        #expect(ProjectPackage.uniqueName(for: "noext", taken: &taken) == "noext 2")
    }
}
