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
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await manager.prepareModels(directory: folder)
        } catch {
            throw DiarizationError.model("The diarisation model couldn't be loaded from \(source.host() ?? source.absoluteString): \(error.localizedDescription)")
        }
        let result = try await manager.process(audio: mono16k) { done, total in
            progress(total > 0 ? Double(done) / Double(total) : 0)
        }
        return result.segments.map { DiarizedSegment(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
    }
}
