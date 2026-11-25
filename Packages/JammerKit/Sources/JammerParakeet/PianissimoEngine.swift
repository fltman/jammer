import FluidAudio
import Foundation
import JammerCore
import JammerSpeech

/// Klang Pianissimo runs through the same local Core ML decoder as Parakeet.
public actor PianissimoEngine: TranscriptionEngine {
    public nonisolated let model: PianissimoModel
    private nonisolated let root: URL
    private nonisolated let directory: URL
    private let source: URL
    private var manager: AsrManager?
    public nonisolated var id: String { model.id }

    public init(model: PianissimoModel, store: ModelStore) {
        self.model = model
        source = store.source
        root = store.folder.appending(path: model.id)
        directory = root.appending(path: model.manifest.commit)
    }

    public nonisolated var isInstalled: Bool {
        model.manifest.entries.allSatisfy { path, entry in
            let file = directory.appending(path: path)
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            return values?.isRegularFile == true && values?.fileSize.map(Int64.init) == entry.size
        }
    }

    public func supports(_ locale: Locale) async -> Bool {
        locale.language.languageCode?.identifier == model.rawValue && isInstalled
    }

    public func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !isInstalled else { progress(1); return }
        let manifest = model.manifest
        var remote = source.appending(path: manifest.repo).appending(path: "resolve").appending(path: manifest.commit)
        if !model.sourceDirectory.isEmpty { remote = remote.appending(path: model.sourceDirectory) }
        let bytes = Double(model.downloadBytes)
        try await manifest.installVerified(target: directory) { staging in
            var downloaded: Int64 = 0
            let files = manifest.entries.sorted { $0.key < $1.key }
            for (path, entry) in files {
                try Task.checkCancellation()
                let dest = staging.appending(path: path)
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                let base = downloaded
                try await ModelStore.downloadFile(at: remote.appending(path: path), to: dest) { part in
                    progress(0.95 * (Double(base) + part * Double(entry.size)) / bytes)
                }
                downloaded += entry.size
            }
            try Task.checkCancellation()
        }
        manager = nil
        progress(1)
    }

    public func remove() throws {
        manager = nil
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    public func transcribe(_ source: SourceRef, pool: SourcePool, locale: Locale,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> SourceTranscript {
        guard let language = Language(rawValue: model.rawValue), locale.language.languageCode?.identifier == model.rawValue else {
            throw TranscriptionError.unsupportedLanguage(locale.identifier(.bcp47))
        }
        try Task.checkCancellation()
        let decoder = try await loaded()
        return try await ParakeetEngine.transcribe(source, pool: pool, locale: locale, language: language,
                                                   id: id, manager: decoder, progress: progress)
    }

    /// Whether the model is loaded (its first load takes seconds, while Core ML prepares it).
    public var isLoaded: Bool { manager != nil }
    /// Loads the model ahead of the first turn.
    public func warm() async throws { _ = try await loaded() }

    private func loaded() async throws -> AsrManager {
        if let manager { return manager }
        guard isInstalled else { throw TranscriptionError.failed("Install Klang Pianissimo in Settings › Models.") }
        let models = try AsrModels.loadLocal(from: directory, version: .v3)
        let decoder = AsrManager(config: .default)
        try await decoder.loadModels(models)
        manager = decoder
        return decoder
    }

    /// One short turn already in memory, 16 kHz mono (POST /api/v1/transcribe): nothing is written, and the model
    /// stays loaded for the next turn. Times in seconds from the turn's start.
    public func transcribeTurn(_ samples: [Float], locale: Locale) async throws -> [RecognisedRun] {
        guard let language = Language(rawValue: model.rawValue), locale.language.languageCode?.identifier == model.rawValue else {
            throw TranscriptionError.unsupportedLanguage(locale.identifier(.bcp47))
        }
        let decoder = try await loaded()
        var state = TdtDecoderState.make()
        let result = try await decoder.transcribe(samples, decoderState: &state, language: language)
        try Task.checkCancellation()
        return ParakeetEngine.words(result.tokenTimings ?? [], sampleRate: Double(16_000)).map {
            RecognisedRun(text: $0.text, start: Double($0.start) / 16_000, end: Double($0.end) / 16_000, confidence: $0.confidence)
        }
    }
}
