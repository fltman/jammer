import CryptoKit
import Foundation

/// The published sum of every file in a model repository at its pinned commit (`ModelManifests.swift`), and the
/// check a download must pass before it is installed (SIBLINGS, "Det som kan behöva installeras"; the coordinator,
/// 2026-11-19): every file the download left must be listed with its size and sum, or nothing is installed.
public struct ModelManifest: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var size: Int64
        /// An LFS file's sha256 (lower-case hex).
        public var sha256: String?
        /// Any other file's git blob id: sha1 of "blob <size>\0" and the content.
        public var gitBlob: String?
    }

    public let repo: String
    public let commit: String
    public let entries: [String: Entry]

    /// `lines`: "path|size|sha256:<hex>" or "path|size|blob:<hex>".
    public init(repo: String, commit: String, lines: [String]) {
        self.repo = repo
        self.commit = commit
        var e: [String: Entry] = [:]
        for l in lines {
            let p = l.split(separator: "|", omittingEmptySubsequences: false)
            guard p.count == 3, let size = Int64(p[1]) else { continue }
            let sum = String(p[2])
            e[String(p[0])] = sum.hasPrefix("sha256:") ? Entry(size: size, sha256: String(sum.dropFirst(7)))
                : Entry(size: size, gitBlob: String(sum.dropFirst(5)))
        }
        entries = e
    }

    /// Files a download writes itself, not from the repository (FluidAudio's revision marker).
    public static let localFiles: Set<String> = [".fluidaudio-revision", ".DS_Store"]

    public struct Mismatch: Error, Equatable, LocalizedError, KeyedFailure {
        public var file: String
        public var why: String
        public var errorDescription: String? { said.text }
        public var keyed: KeyedMessage? { said.keyed }
        var said: Said {
            Said("error.model.mismatch", "%1$@ didn't match the checksum its source publishes (%2$@), so nothing was installed.", file, why)
        }
    }

    /// Checks every file under `root` against the manifest; throws on the first that isn't listed, has another size
    /// or another sum, and when the download left nothing.
    public func verify(_ root: URL) throws {
        let fm = FileManager.default
        guard let walk = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
            throw Mismatch(file: root.lastPathComponent, why: "missing")
        }
        let base = root.standardizedFileURL.path
        var seen = 0
        for case let url as URL in walk {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let rel = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            if Self.localFiles.contains(url.lastPathComponent) { continue }
            guard let e = entries[rel] else { throw Mismatch(file: rel, why: "not in the repository at \(commit.prefix(8))") }
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
            guard size == e.size else { throw Mismatch(file: rel, why: "\(size) bytes, not \(e.size)") }
            if let s = e.sha256 {
                guard try Self.sha256(of: url) == s else { throw Mismatch(file: rel, why: "sha256") }
            } else if let b = e.gitBlob {
                guard try Self.gitBlobID(of: url, size: size) == b else { throw Mismatch(file: rel, why: "git blob id") }
            }
            seen += 1
        }
        guard seen > 0 else { throw Mismatch(file: root.lastPathComponent, why: "empty") }
    }

    /// Downloads into `staging` (with the same last path component as `target`), checks it, and only then moves it
    /// to `target`. On any failure the staging folder is removed and `target` is left as it was.
    public func installVerified(target: URL, download: (URL) async throws -> Void) async throws {
        let fm = FileManager.default
        let stagingRoot = target.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: ".staging-\(UUID().uuidString)")
        let staging = stagingRoot.appending(path: target.deletingLastPathComponent().lastPathComponent).appending(path: target.lastPathComponent)
        defer { try? fm.removeItem(at: stagingRoot) }
        try fm.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await download(staging)
        try verify(staging)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: staging, to: target)
    }

    static func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    public static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func gitBlobID(of url: URL, size: Int64) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(size)\0".utf8))
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
