import Foundation
import Testing
import JammerCore
@testable import JammerAgent

/// A timeline file is asked its size before it is read: one far larger than its kind can be is refused without being
/// read whole (the coordinator, 2026-11-27). The files are sparse: they say gigabytes and take no room.
@Suite("Hostile files: timeline imports refused by their size, unread")
struct HostileImportTests {
    func sparse(_ name: String, bytes: UInt64) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "jammer-hostile-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: bytes)
        try h.close()
        return url
    }

    @Test("An OTIO of 300 MB and an EDL of 40 MB are refused in words at once, never read", arguments: [("big.otio", UInt64(300 << 20)), ("big.edl", UInt64(40 << 20))])
    func tooLarge(name: String, bytes: UInt64) throws {
        let url = try sparse(name, bytes: bytes)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let t0 = Date()
        #expect(throws: BatchError.self) { _ = try TimelineImport.check(["path": url.path], policy: nil, formats: nil) }
        #expect(Date().timeIntervalSince(t0) < 1, "refused by its size, not after reading \(bytes >> 20) MB")
    }
}
