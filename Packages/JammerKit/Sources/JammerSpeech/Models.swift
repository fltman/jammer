import CryptoKit
import Foundation
import JammerCore

/// A downloadable model file: where it lives upstream and what it must hash to.
public struct ModelSpec: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    /// Repository path on the source, e.g. "KBLab/kb-whisper-small".
    public var repo: String
    public var file: String
    public var size: Int64
    /// SHA-256 of the file, lower-case hex (the LFS object id on Hugging Face).
    public var sha256: String
    public var licence: String

    /// The catalogue. Sizes and hashes read from the Hugging Face tree API, 2026-11-15.
    public static let kbWhisperSmallQ5 = ModelSpec(
        id: "kb-whisper-small-q5", title: "KB-Whisper small (Swedish, 175 MB)", repo: "KBLab/kb-whisper-small",
        file: "ggml-model-q5_0.bin", size: 175_209_680,
        sha256: "6768836a51abc902e420c613153e6d418c90ea2774e913274d02ab23170225b7", licence: "Apache-2.0")
    public static let kbWhisperMediumQ5 = ModelSpec(
        id: "kb-whisper-medium-q5", title: "KB-Whisper medium (Swedish, 539 MB)", repo: "KBLab/kb-whisper-medium",
        file: "ggml-model-q5_0.bin", size: 539_212_484,
        sha256: "7f8762e0ade9e0073674c0d5acae942a0b1ea98add9baa008ee89c94eaba43d0", licence: "Apache-2.0")
    public static let catalogue = [kbWhisperSmallQ5, kbWhisperMediumQ5]
}

public enum ModelError: Error, LocalizedError, Equatable {
    case http(Int)
    case wrongSize(expected: Int64, got: Int64)
    case wrongChecksum
    case notEnoughSpace(needed: Int64)

    public var errorDescription: String? {
        switch self {
        case .http(let c): "The model source answered \(c)."
        case .wrongSize(let e, let g): "The download has the wrong size (\(g) bytes, expected \(e))."
        case .wrongChecksum: "The download doesn't match its checksum, so it wasn't used."
        case .notEnoughSpace(let n): "Not enough free disk space (\(n / 1_000_000) MB needed)."
        }
    }
    /// The same message by its key in the app's string catalogue (see `KeyedMessage`).
    public var keyed: KeyedMessage? {
        switch self {
        case .http(let c): KeyedMessage("error.model.http", ["\(c)"])
        case .wrongSize(let e, let g): KeyedMessage("error.model.wrongSize", ["\(g)", "\(e)"])
        case .wrongChecksum: KeyedMessage("error.model.wrongChecksum")
        case .notEnoughSpace(let n): KeyedMessage("error.model.notEnoughSpace", ["\(n / 1_000_000)"])
        }
    }
}

/// Where models come from and where they're kept. The source is user configuration
/// (Jämmer runs no server); it defaults to Hugging Face. Files are verified before use.
public struct ModelStore: Sendable {
    public static let defaultSource = URL(string: "https://huggingface.co")!

    public var source: URL
    public var folder: URL

    public init(source: URL = ModelStore.defaultSource, folder: URL) {
        self.source = source
        self.folder = folder
    }

    /// Settings, then `JAMMER_MODELS_DIR` (development), then Application Support.
    public static func standard(defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment) -> ModelStore {
        let source = defaults.string(forKey: "models.source").flatMap(URL.init(string:)) ?? defaultSource
        let folder = environment["JAMMER_MODELS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Jammer/Models")
        return ModelStore(source: source, folder: folder)
    }

    /// `<source>/<repo>/resolve/main/<file>`, the Hugging Face layout (mirrors use the same).
    public func url(for spec: ModelSpec) -> URL {
        source.appending(path: spec.repo).appending(path: "resolve/main").appending(path: spec.file)
    }

    public func path(for spec: ModelSpec) -> URL { folder.appending(path: spec.id).appending(path: spec.file) }

    public func isInstalled(_ spec: ModelSpec) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: path(for: spec).path)[.size] as? NSNumber)?.int64Value
        return size == spec.size
    }

    public func remove(_ spec: ModelSpec) throws {
        try? FileManager.default.removeItem(at: folder.appending(path: spec.id))
    }

    /// Downloads, checks size and SHA-256, and only then moves the file into place.
    /// `progress` gets 0…1. Already installed: returns at once.
    @discardableResult
    public func install(_ spec: ModelSpec, session: URLSession = .shared,
                        progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let dest = path(for: spec)
        if isInstalled(spec) { return dest }
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? .max
        guard free > spec.size + 200_000_000 else { throw ModelError.notEnoughSpace(needed: spec.size) }
        let part = dest.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: part)
        let request = URLRequest(url: url(for: spec))
        let observer = Box<NSKeyValueObservation>()
        let tmp: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
                let task = session.downloadTask(with: request) { file, response, error in
                    if let error { c.resume(throwing: error); return }
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        c.resume(throwing: ModelError.http(http.statusCode)); return
                    }
                    guard let file else { c.resume(throwing: ModelError.http(0)); return }
                    // The system deletes `file` when this returns: move it now.
                    do {
                        try FileManager.default.moveItem(at: file, to: part)
                        c.resume(returning: part)
                    } catch { c.resume(throwing: error) }
                }
                observer.value = task.progress.observe(\.fractionCompleted) { p, _ in progress(min(0.99, p.fractionCompleted)) }
                observer.task = task
                task.resume()
            }
        } onCancel: { observer.task?.cancel() }
        observer.value = nil
        let written = (try FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard written == spec.size else {
            try? FileManager.default.removeItem(at: tmp)
            throw ModelError.wrongSize(expected: spec.size, got: written)
        }
        guard try Self.sha256(of: tmp) == spec.sha256 else {
            try? FileManager.default.removeItem(at: tmp)
            throw ModelError.wrongChecksum
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: part, to: dest)
        progress(1)
        return dest
    }

    /// SHA-256 of a file, read in 1 MB pieces.
    public static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty {
            autoreleasepool { hasher.update(data: chunk) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Lets the download's progress observation and task outlive the closure that made them.
final class Box<T>: @unchecked Sendable {
    var value: T?
    var task: URLSessionTask?
}

extension ModelError: KeyedFailure {}
