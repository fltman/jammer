import FluidAudio
import Foundation
import JammerCore

/// Speaker diarisation with FluidAudio's offline pipeline: pyannote Community-1
/// segmentation and embeddings (Core ML conversions, CC-BY-4.0) with VBx clustering.
/// Only that pipeline is used; the repository's older models are outside its licence
/// scope (docs/LICENSES.md). Models come from the user's model source on first use and
/// stay in `folder`.
public final class FluidDiarizer: SpeakerDiarizer, @unchecked Sendable {
    public let folder: URL
    public let source: URL
    public var engineName: String { "pyannote-community-1" }

    private let lock = NSLock()
    private var managers: [String: OfflineDiarizerManager] = [:]

    static var notInstalled: Said {
        Said("error.diarization.notInstalled", "The diarisation model isn't installed. Download it in Settings › Models; Jämmer checks every file before it is installed.")
    }

    public init(folder: URL, source: URL) {
        self.folder = folder
        self.source = source
    }

    /// True when the five model files are already on disk (no download needed).
    public var isInstalled: Bool {
        let repo = folder.appending(path: "speaker-diarization")
        return ["Segmentation.mlmodelc", "FBank.mlmodelc", "Embedding.mlmodelc", "PldaRho.mlmodelc", "plda-parameters.json"]
            .allSatisfy { FileManager.default.fileExists(atPath: repo.appending(path: $0).path) }
    }

    /// Fetches the five model files now (Settings › Models) instead of on first use.
    public func install(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        ModelRegistry.baseURL = source.absoluteString.hasSuffix("/") ? String(source.absoluteString.dropLast()) : source.absoluteString
        // Staged and checked file by file against the sums published at the pinned commit (ModelManifest): a file
        // that doesn't match installs nothing.
        try await ModelManifest.diarisation.installVerified(target: folder.appending(path: "speaker-diarization")) { staging in
            _ = try await OfflineDiarizerModels.load(from: staging.deletingLastPathComponent()) { p in progress(p.fractionCompleted * 0.95) }
        }
        progress(1)
    }

    public func remove() throws {
        lock.withLock { managers = [:] }
        try? FileManager.default.removeItem(at: folder.appending(path: "speaker-diarization"))
    }

    /// The Community-1 embedding model (WeSpeaker) on each speaker's spans, without segmenting or clustering
    /// again (FluidAudio's `embedSpans`). Spans shorter than 0.5 s are left out: too little voice to say much.
    public func voiceprints(mono16k: [Float], spans: [String: [Range<Double>]]) async throws -> [String: [Float]]? {
        let manager: OfflineDiarizerManager = lock.withLock {
            if let m = managers["voiceprints"] { return m }
            let m = OfflineDiarizerManager(config: .default)
            managers["voiceprints"] = m
            return m
        }
        ModelRegistry.baseURL = source.absoluteString.hasSuffix("/") ? String(source.absoluteString.dropLast()) : source.absoluteString
        // Only a model installed through `install` (checked file by file) is used; prepareModels would fetch one unchecked.
        guard isInstalled else { throw DiarizationError.model(Self.notInstalled) }
        try await manager.prepareModels(directory: folder)
        let length = Double(mono16k.count) / 16_000
        var out: [String: [Float]] = [:]
        for (speaker, ranges) in spans {
            let usable = ranges.map { max(0, $0.lowerBound)..<min(length, $0.upperBound) }.filter { $0.upperBound - $0.lowerBound >= 0.5 }
            guard !usable.isEmpty else { continue }
            let embeddings = try await manager.embedSpans(audioSource: ArrayAudioSampleSource(samples: mono16k), spans: usable)
            if let v = VoicePrint.mean(embeddings) { out[speaker] = v }
        }
        return out
    }

    public func diarize(mono16k: [Float], minSpeakers: Int?, maxSpeakers: Int?,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> [DiarizedSegment] {
        let key = "\(minSpeakers ?? 0)-\(maxSpeakers ?? 0)"
        let manager: OfflineDiarizerManager = lock.withLock {
            if let m = managers[key] { return m }
            var config = OfflineDiarizerConfig.default
            if let minSpeakers, let maxSpeakers, minSpeakers == maxSpeakers {
                config.clustering.numSpeakers = minSpeakers
            } else {
                config.clustering.minSpeakers = minSpeakers
                config.clustering.maxSpeakers = maxSpeakers
            }
            let m = OfflineDiarizerManager(config: config)
            managers[key] = m
            return m
        }
        ModelRegistry.baseURL = source.absoluteString.hasSuffix("/") ? String(source.absoluteString.dropLast()) : source.absoluteString
        guard isInstalled else { throw DiarizationError.model(Self.notInstalled) }
        do {
            try await manager.prepareModels(directory: folder)
        } catch {
            throw DiarizationError.model(Said("error.diarization.diarisation_model_couldn_t", "The diarisation model couldn't be loaded from %1$@: %2$@", "\(source.host() ?? source.absoluteString)", "\(error.localizedDescription)"))
        }
        let result: DiarizationResult
        do {
            result = try await manager.process(audio: mono16k) { done, total in
                progress(total > 0 ? Double(done) / Double(total) : 0)
            }
        } catch OfflineDiarizationError.noSpeechDetected {
            // No speech is an answer (no speakers), not a failure: music, an empty room.
            progress(1)
            return []
        }
        return result.segments.map { DiarizedSegment(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
    }
}
