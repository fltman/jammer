import AVFoundation
import CoreMedia
import Foundation
import JammerCore
import Speech

/// Something that turns a source's audio into words anchored in source frames.
public protocol TranscriptionEngine: Sendable {
    /// Stable id, stored with the transcript (e.g. "apple-dictation").
    var id: String { get }
    /// Whether it can do this language here, now (assets may still need downloading).
    func supports(_ locale: Locale) async -> Bool
    /// `progress` gets 0…1 of the source read so far.
    func transcribe(_ source: SourceRef, pool: SourcePool, locale: Locale,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> SourceTranscript
}

public enum TranscriptionError: Error, LocalizedError, Equatable {
    case unsupportedLanguage(String)
    case unreadableSource
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let l): "Transcription in \(l) isn't available on this Mac."
        case .unreadableSource: "The audio file can't be read."
        case .failed(let m): "Transcription failed: \(m)"
        }
    }
}

/// A recognised piece of text with its time range, as engines report it.
public struct RecognisedRun: Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    public var confidence: Double?

    public init(text: String, start: Double, end: Double, confidence: Double?) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

public enum WordBuilder {
    /// Turns engine runs (seconds) into words (source frames). Empty runs are dropped;
    /// punctuation without a duration of its own joins the word before it.
    public static func words(from runs: [RecognisedRun], sampleRate: Double, sourceFrames: Frame) -> [Word] {
        var out: [Word] = []
        for r in runs.sorted(by: { $0.start < $1.start }) {
            let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let isPunctuation = text.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
            if isPunctuation, !out.isEmpty {
                out[out.count - 1].text += text
                continue
            }
            let start = min(sourceFrames, max(0, Frame((r.start * sampleRate).rounded())))
            let end = min(sourceFrames, max(start, Frame((r.end * sampleRate).rounded())))
            out.append(Word(text: text, start: start, end: end, confidence: r.confidence))
        }
        return spreadingCollapsed(out, sampleRate: sampleRate)
    }

    /// Recognisers sometimes give the first words after a pause no duration (Whisper's
    /// token times collapse at a segment start). A word without duration can't be shown,
    /// selected or deleted, so each such run gets the stretch just before the next timed
    /// word: about 70 ms per character, shared by length, and never before the previous
    /// word's end.
    static func spreadingCollapsed(_ words: [Word], sampleRate: Double) -> [Word] {
        var out = words
        var i = 0
        while i < out.count {
            guard out[i].end <= out[i].start else { i += 1; continue }
            var j = i
            while j < out.count, out[j].end <= out[j].start { j += 1 }
            let chars = out[i..<j].map { max(1, $0.text.count) }
            let wanted = Frame(Double(chars.reduce(0, +)) * 0.07 * sampleRate)
            let floor = i > 0 ? out[i - 1].end : 0
            let hi: Frame = j < out.count ? max(out[j].start, out[j - 1].start) : out[j - 1].start + wanted
            let lo = max(floor, hi - wanted)
            if hi > lo {
                var at = lo
                let total = Double(chars.reduce(0, +))
                for (k, n) in zip(i..<j, chars) {
                    let len = Frame((Double(hi - lo) * Double(n) / total).rounded(.down))
                    out[k].start = at
                    out[k].end = k == j - 1 ? hi : max(at + 1, at + len)
                    at = out[k].end
                }
            }
            i = j
        }
        return out
    }
}

/// Apple's on-device recognisers: SpeechTranscriber where the language is supported,
/// else DictationTranscriber (which has Swedish on macOS 27). Nothing leaves the Mac.
public struct AppleSpeechEngine: TranscriptionEngine {
    public init() {}

    public var id: String { "apple" }

    enum Kind: String { case speech, dictation }

    static func kind(for locale: Locale) async -> (Kind, Locale)? {
        if let l = await SpeechTranscriber.supportedLocale(equivalentTo: locale) { return (.speech, l) }
        let wanted = locale.identifier(.bcp47)
        let dictation = await DictationTranscriber.supportedLocales
        if let l = dictation.first(where: { $0.identifier(.bcp47) == wanted })
            ?? dictation.first(where: { $0.language.languageCode == locale.language.languageCode }) {
            return (.dictation, l)
        }
        return nil
    }

    public func supports(_ locale: Locale) async -> Bool { await Self.kind(for: locale) != nil }

    public func transcribe(_ source: SourceRef, pool: SourcePool, locale: Locale,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> SourceTranscript {
        guard let (kind, matched) = await Self.kind(for: locale) else {
            throw TranscriptionError.unsupportedLanguage(locale.identifier(.bcp47))
        }
        let module: any SpeechModule
        switch kind {
        case .speech:
            module = SpeechTranscriber(locale: matched, transcriptionOptions: [], reportingOptions: [],
                                       attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        case .dictation:
            module = DictationTranscriber(locale: matched, contentHints: [], transcriptionOptions: [.punctuation],
                                          reportingOptions: [], attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw TranscriptionError.failed("no audio format")
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        let collector = Task { () throws -> [RecognisedRun] in
            var runs: [RecognisedRun] = []
            if let m = module as? DictationTranscriber {
                for try await r in m.results { runs += Self.runs(r.text) }
            } else if let m = module as? SpeechTranscriber {
                for try await r in m.results { runs += Self.runs(r.text) }
            }
            return runs
        }
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)
        do {
            try SourceFeeder(source: source, pool: pool, format: format).feed(into: input, progress: progress)
        } catch {
            input.finish()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        input.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let runs = try await collector.value
        let words = WordBuilder.words(from: runs, sampleRate: source.info.sampleRate, sourceFrames: source.info.frames)
        return SourceTranscript(sourceID: source.id, language: matched.identifier(.bcp47),
                                engine: "apple-\(kind.rawValue)", words: words)
    }

    static func runs(_ s: AttributedString) -> [RecognisedRun] {
        s.runs.compactMap { run in
            guard let r = run.audioTimeRange else { return nil }
            return RecognisedRun(text: String(s[run.range].characters), start: r.start.seconds, end: r.end.seconds,
                                 confidence: run.transcriptionConfidence)
        }
    }
}

/// Reads a source through the pool (any format Jammer opens), mixes it to mono and
/// converts it to what the recogniser wants, in pieces, with sample-exact start times.
struct SourceFeeder {
    let source: SourceRef
    let pool: SourcePool
    let format: AVAudioFormat

    func feed(into input: AsyncStream<AnalyzerInput>.Continuation, progress: (Double) -> Void) throws {
        let rate = source.info.sampleRate
        let channels = source.info.channels
        let total = source.info.frames
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: mono, to: format) else { throw TranscriptionError.unreadableSource }
        let piece = Int(rate * 10)
        var at: Frame = 0
        var outFrames: Int64 = 0
        while at < total {
            let samples = pool.read(source, from: at, count: Int(min(Frame(piece), total - at)))
            let n = samples.count / max(1, channels)
            guard n > 0 else { throw TranscriptionError.unreadableSource }
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(n)) else { throw TranscriptionError.unreadableSource }
            inBuf.frameLength = AVAudioFrameCount(n)
            let dst = inBuf.floatChannelData![0]
            let scale = 1 / Float(channels)
            for i in 0..<n {
                var v: Float = 0
                for c in 0..<channels { v += samples[i * channels + c] }
                dst[i] = v * scale
            }
            let capacity = AVAudioFrameCount(Double(n) * format.sampleRate / rate) + 1024
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw TranscriptionError.unreadableSource }
            var given = false
            var error: NSError?
            let status = converter.convert(to: outBuf, error: &error) { _, state in
                if given { state.pointee = .noDataNow; return nil }
                given = true
                state.pointee = .haveData
                return inBuf
            }
            if status == .error { throw TranscriptionError.failed(error?.localizedDescription ?? "conversion") }
            if outBuf.frameLength > 0 {
                let start = CMTime(value: outFrames, timescale: CMTimeScale(format.sampleRate))
                input.yield(AnalyzerInput(buffer: outBuf, bufferStartTime: start))
                outFrames += Int64(outBuf.frameLength)
            }
            at += Frame(n)
            progress(Double(at) / Double(max(1, total)))
        }
    }
}
