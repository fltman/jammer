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
    /// The language the model is for (KB-Whisper: Swedish).
    public let language: String
    private let lock = NSLock()
    private var context: OpaquePointer?

    public init(model: ModelSpec, path: URL, language: String = "sv") {
        self.model = model
        modelPath = path
        self.language = language
    }

    deinit { if let context { whisper_free(context) } }

    public var id: String { "whisper-\(model.id)" }

    public func supports(_ locale: Locale) async -> Bool {
        locale.language.languageCode?.identifier == language && FileManager.default.fileExists(atPath: modelPath.path)
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
        let task = Task.detached(priority: .userInitiated) { [self] () throws -> [RecognisedRun] in
            try lock.withLock { try run(samples, progress: progress) }
        }
        let runs = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        let words = WordBuilder.words(from: runs, sampleRate: source.info.sampleRate, sourceFrames: source.info.frames)
        return SourceTranscript(sourceID: source.id, language: locale.identifier(.bcp47), engine: id, words: words)
    }

    final class Callbacks: @unchecked Sendable {
        let progress: @Sendable (Double) -> Void
        init(_ p: @escaping @Sendable (Double) -> Void) { progress = p }
    }

    private func run(_ samples: [Float], progress: @escaping @Sendable (Double) -> Void) throws -> [RecognisedRun] {
        let ctx = try loadedContext()
        var p = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        p.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
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
        let rate = source.info.sampleRate, channels = source.info.channels
        guard let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFmt, to: outFmt) else { throw TranscriptionError.unreadableSource }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        var out: [Float] = []
        out.reserveCapacity(Int(Double(source.info.frames) * 16_000 / rate) + 1)
        let piece = Int(rate * 30)
        var at: Frame = 0
        while at < source.info.frames {
            let raw = pool.read(source, from: at, count: Int(min(Frame(piece), source.info.frames - at)))
            let n = raw.count / max(1, channels)
            guard n > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(n)) else { throw TranscriptionError.unreadableSource }
            inBuf.frameLength = AVAudioFrameCount(n)
            let d = inBuf.floatChannelData![0]
            for i in 0..<n {
                var v: Float = 0
                for c in 0..<channels { v += raw[i * channels + c] }
                d[i] = v / Float(channels)
            }
            let last = at + Frame(n) >= source.info.frames
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: AVAudioFrameCount(Double(n) * 16_000 / rate) + 1024) else { throw TranscriptionError.unreadableSource }
            var given = false
            var error: NSError?
            _ = converter.convert(to: outBuf, error: &error) { _, state in
                if given { state.pointee = last ? .endOfStream : .noDataNow; return nil }
                given = true
                state.pointee = .haveData
                return inBuf
            }
            if let error { throw TranscriptionError.failed(error.localizedDescription) }
            out += UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength))
            at += Frame(n)
        }
        return out
    }
}
