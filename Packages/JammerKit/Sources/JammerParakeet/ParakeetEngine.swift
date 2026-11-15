import CoreML
import FluidAudio
import Foundation
import JammerCore
import JammerSpeech

/// NVIDIA Parakeet TDT 0.6B v3 (25 European languages, Swedish among them) through
/// FluidAudio's Core ML conversion (CC-BY-4.0, attributed in Credits). Installed by the
/// user under Settings › Models, never by an agent; pinned to one revision.
public final class ParakeetEngine: TranscriptionEngine, @unchecked Sendable {
    public static let revision = "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe"
    public static let repo = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
    /// The rebuilt int8 encoder: the original 6-bit one corrupts tokens in some contexts (FluidAudio #760).
    static let precision = ParakeetEncoderPrecision.int8V2
    /// Preprocessor, Encoder_v2, Decoder, JointDecisionv3 and the vocabulary at the pinned revision.
    public static let downloadBytes: Int64 = 632_000_000
    public static let title = "Parakeet TDT 0.6B v3 (25 languages)"
    public static let licence = "CC-BY-4.0 (NVIDIA; Core ML conversion by Fluid Inference)"
    public static let languages = Set(Language.allCases.map(\.rawValue))

    public let folder: URL
    public let source: URL
    public var id: String { "parakeet-tdt-0.6b-v3" }

    private let lock = NSLock()
    private var manager: AsrManager?

    /// `folder`: where models live (Settings › Models); the files go in a subfolder.
    public init(folder: URL, source: URL) {
        self.folder = folder
        self.source = source
    }

    var directory: URL { folder.appending(path: "parakeet").appending(path: Repo.parakeetV3.folderName) }

    public var isInstalled: Bool { AsrModels.modelsExist(at: directory, version: .v3, encoderPrecision: Self.precision) }

    public func supports(_ locale: Locale) async -> Bool {
        isInstalled && Self.languages.contains(locale.language.languageCode?.identifier ?? "")
    }

    func configureSource() {
        let base = source.absoluteString
        ModelRegistry.baseURL = base.hasSuffix("/") ? String(base.dropLast()) : base
        ModelRegistry.revisionOverrides[Self.repo] = Self.revision
    }

    /// Downloads the model from the user's model source (Settings › Models).
    public func install(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        configureSource()
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try await AsrModels.download(to: directory, version: .v3, encoderPrecision: Self.precision) { p in
            progress(p.fractionCompleted)
        }
    }

    public func remove() throws {
        lock.withLock { manager = nil }
        try? FileManager.default.removeItem(at: folder.appending(path: "parakeet"))
    }

    private func loadedManager() async throws -> AsrManager {
        if let m = lock.withLock({ manager }) { return m }
        guard isInstalled else { throw TranscriptionError.failed("Parakeet isn't installed (Settings › Models).") }
        configureSource()
        let models = try await AsrModels.load(from: directory, version: .v3, encoderPrecision: Self.precision)
        let m = AsrManager(config: .default)
        try await m.loadModels(models)
        lock.withLock { manager = m }
        return m
    }

    public func transcribe(_ source: SourceRef, pool: SourcePool, locale: Locale,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> SourceTranscript {
        let code = locale.language.languageCode?.identifier ?? ""
        guard Self.languages.contains(code) else { throw TranscriptionError.unsupportedLanguage(locale.identifier(.bcp47)) }
        let samples = try SpeechAudio.mono16k(source, pool: pool)
        progress(0.1)
        let m = try await loadedManager()
        var state = TdtDecoderState.make()
        let result = try await m.transcribe(samples, decoderState: &state, language: Language(rawValue: code))
        progress(1)
        let words = Self.words(result.tokenTimings ?? [], sampleRate: source.info.sampleRate)
        return SourceTranscript(sourceID: source.id, language: locale.identifier(.bcp47), engine: id, words: words)
    }

    /// SentencePiece tokens to words: "▁" starts a word. Times in source frames;
    /// confidence is the mean of the word's tokens.
    static func words(_ tokens: [TokenTiming], sampleRate: Double) -> [Word] {
        var out: [Word] = []
        var text = "", start = 0.0, end = 0.0, confs: [Float] = []
        func flush() {
            let t = text.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty {
                // The mean over the word's tokens, like the Whisper engine: the lowest token
                // alone marked nearly every word as unsure.
                let conf = confs.isEmpty ? 1 : confs.reduce(0, +) / Float(confs.count)
                out.append(Word(text: t, start: Frame((start * sampleRate).rounded()), end: Frame((end * sampleRate).rounded()), confidence: Double(conf)))
            }
            text = ""
            confs = []
        }
        for tok in tokens {
            // A word starts at "▁" (SentencePiece) or a leading space (how FluidAudio hands tokens over).
            let piece = tok.token
            let startsWord = piece.hasPrefix("▁") || piece.hasPrefix(" ")
            if startsWord || text.isEmpty {
                flush()
                start = tok.startTime
            }
            text += piece.replacingOccurrences(of: "▁", with: " ")
            end = tok.endTime
            confs.append(tok.confidence)
        }
        flush()
        return out
    }
}
