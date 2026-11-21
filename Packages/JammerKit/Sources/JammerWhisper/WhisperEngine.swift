import AVFoundation
import Foundation
import JammerCore
import JammerSpeech
import whisper

/// whisper.cpp with a downloaded model (KB-Whisper for Swedish). Runs on the Mac
/// (Metal, Accelerate); words get token-level times, anchored in source frames.
public final class WhisperEngine: TranscriptionEngine, @unchecked Sendable {
    public let model: ModelSpec
    public let modelPath: URL
    /// The model’s fixed language. Multilingual weights use the requested or detected language.
    public let language: String?
    private let lock = NSLock()
    private var context: OpaquePointer?

    public init(model: ModelSpec, path: URL, language: String? = "sv") {
        self.model = model
        modelPath = path
        self.language = language
    }

    deinit { if let context { whisper_free(context) } }

    public var id: String { model.id.hasPrefix("whisper-") ? model.id : "whisper-\(model.id)" }

    public func supports(_ locale: Locale) async -> Bool {
        guard FileManager.default.fileExists(atPath: modelPath.path) else { return false }
        let requested = Self.whisperLanguage(locale)
        return language.map { $0 == requested } ?? (requested == "auto" || requested.withCString { whisper_lang_id($0) >= 0 })
    }

    private static func whisperLanguage(_ locale: Locale) -> String {
        let code = locale.language.languageCode?.identifier ?? "auto"
        if code == "nb" || code == "nn" { return "no" }
        return code == "und" ? "auto" : code
    }

    private static var threads: Int32 { Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))) }

    /// Ask the multilingual checkpoint about the compacted voice audio itself.
    public func detectLanguage(_ source: SourceRef, pool: SourcePool) throws -> String? {
        let samples = try SpeechAudio.mono16k(source, pool: pool, maxFrames: Frame(source.info.sampleRate * 30))
        guard samples.count >= 16_000 else { return nil }
        return try lock.withLock {
            try Task.checkCancellation()
            let ctx = try loadedContext()
            let prepared = samples.withUnsafeBufferPointer { whisper_pcm_to_mel(ctx, $0.baseAddress, Int32($0.count), Self.threads) }
            guard prepared == 0 else { throw TranscriptionError.failed("Whisper could not analyze the audio.") }
            var probabilities = [Float](repeating: 0, count: Int(whisper_lang_max_id()) + 1)
            let best = whisper_lang_auto_detect(ctx, 0, Self.threads, &probabilities)
            guard best >= 0, probabilities.indices.contains(Int(best)),
                  let code = whisper_lang_str(best) else { return nil }
            let score = probabilities[Int(best)]
            probabilities[Int(best)] = 0
            guard score >= 0.5, score - (probabilities.max() ?? 0) >= 0.15 else { return nil }
            return String(cString: code)
        }
    }

    private func loadedContext() throws -> OpaquePointer {
        if let context { return context }
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true
        guard let ctx = whisper_init_from_file_with_params(modelPath.path, params) else {
            throw TranscriptionError.failed("couldn't load \(modelPath.lastPathComponent)")
        }
        context = ctx
        return ctx
    }

    public func transcribe(_ source: SourceRef, pool: SourcePool, locale: Locale,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> SourceTranscript {
        guard await supports(locale) else { throw TranscriptionError.unsupportedLanguage(locale.identifier(.bcp47)) }
        let samples = try Self.mono16k(source, pool: pool)
        let code = Self.whisperLanguage(locale)
        let task = Task.detached(priority: .userInitiated) { [self] () throws -> [RecognisedRun] in
            try lock.withLock { try run(samples, language: code, progress: progress) }
        }
        let runs = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        let words = WordBuilder.words(from: runs, sampleRate: source.info.sampleRate, sourceFrames: source.info.frames)
        return SourceTranscript(sourceID: source.id, language: locale.identifier(.bcp47), engine: id, words: words)
    }

    final class Callbacks: @unchecked Sendable {
        let progress: @Sendable (Double) -> Void
        init(_ p: @escaping @Sendable (Double) -> Void) { progress = p }
    }

    private func run(_ samples: [Float], language: String, progress: @escaping @Sendable (Double) -> Void) throws -> [RecognisedRun] {
        let ctx = try loadedContext()
        var p = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        p.n_threads = Self.threads
        p.translate = false
        p.no_context = true
        p.print_progress = false
        p.print_realtime = false
        p.print_timestamps = false
        p.token_timestamps = true
        p.suppress_blank = true
        let callbacks = Callbacks(progress)
        let box = Unmanaged.passRetained(callbacks)
        defer { box.release() }
        p.progress_callback = { _, _, percent, user in
            guard let user else { return }
            Unmanaged<Callbacks>.fromOpaque(user).takeUnretainedValue().progress(Double(percent) / 100)
        }
        p.progress_callback_user_data = box.toOpaque()
        // Cancelling the Swift task stops whisper between steps.
        p.abort_callback = { _ in Task.isCancelled }
        let status = language.withCString { lang -> Int32 in
            p.language = lang
            return samples.withUnsafeBufferPointer { whisper_full(ctx, p, $0.baseAddress, Int32($0.count)) }
        }
        try Task.checkCancellation()
        guard status == 0 else { throw TranscriptionError.failed("whisper returned \(status)") }
        return Self.runs(ctx)
    }

    /// Tokens joined into words: a token starting with a space begins a new word.
    /// Tokens are raw bytes and may split a UTF-8 character (å, ä, ö), so a word's
    /// bytes are collected and decoded only when it's complete. Times are in 10 ms steps.
    static func runs(_ ctx: OpaquePointer) -> [RecognisedRun] {
        let eot = whisper_token_eot(ctx)
        var out: [RecognisedRun] = []
        var bytes: [UInt8] = [], start = 0.0, end = 0.0, probs: [Double] = []
        func flush() {
            let t = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { out.append(RecognisedRun(text: t, start: start, end: end, confidence: probs.isEmpty ? nil : probs.reduce(0, +) / Double(probs.count))) }
            bytes = []; probs = []
        }
        for s in 0..<whisper_full_n_segments(ctx) {
            for k in 0..<whisper_full_n_tokens(ctx, s) {
                let data = whisper_full_get_token_data(ctx, s, k)
                guard data.id < eot, let cstr = whisper_full_get_token_text(ctx, s, k) else { continue }
                let piece = Array(UnsafeBufferPointer(start: UnsafeRawPointer(cstr).assumingMemoryBound(to: UInt8.self), count: strlen(cstr)))
                if piece.first == 0x20 || bytes.isEmpty {
                    flush()
                    start = Double(data.t0) / 100
                }
                bytes += piece
                end = Double(data.t1) / 100
                probs.append(Double(data.p))
            }
            flush()
        }
        return out
    }

    /// The source as 16 kHz mono float, what Whisper expects.
    static func mono16k(_ source: SourceRef, pool: SourcePool) throws -> [Float] {
        try SpeechAudio.mono16k(source, pool: pool)
    }
}
