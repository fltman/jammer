import AudioToolbox
import Foundation

/// Export formats beyond WAV, through Apple's encoders (ExtAudioFile). WAV and RF64 stay
/// with `WAVWriter`, which keeps bext, iXML and markers.
public enum ExportFormat: String, Sendable, Codable, CaseIterable {
    case wav, aiff, flac, alac, aac, opus, mp3
    /// Apple Positional Audio Codec in MP4: documents in 5.1, 7.1 and 7.1.4 (macOS 26 and later).
    case apac

    /// The formats this build can write (MP3 needs the LAME framework).
    public static var available: [ExportFormat] { allCases.filter { $0 != .mp3 || EncodedWriter.mp3Factory != nil } }

    public var fileExtension: String {
        switch self {
        case .wav: "wav"
        case .aiff: "aiff"
        case .flac: "flac"
        case .alac, .aac: "m4a"
        case .opus: "opus"
        case .mp3: "mp3"
        case .apac: "mp4"
        }
    }

    public var isLossless: Bool { self != .aac && self != .opus && self != .mp3 && self != .apac }
    /// Bit depths a format can store (AAC has none).
    public var bitDepths: [Int] {
        switch self {
        case .wav: [16, 24, 32]
        case .aiff: [16, 24]
        case .flac: [16, 24]
        case .alac: [16, 24]
        case .aac, .opus, .mp3, .apac: []
        }
    }
}

public struct EncodedExportOptions: Sendable {
    public var format: ExportFormat
    public var bitDepth: Int
    /// AAC only, bits per second (e.g. 128 000 for speech at 48 kHz stereo).
    public var bitRate: Int
    /// MP3: an ID3v2 tag to put before the audio (chapters, title).
    public var id3: Data?
    /// Opus (CHAPTERxxx comments) and AAC/ALAC (a chapter track); seconds from the range's start.
    public var chapters: [Chapter]
    /// BCP 47 language of the speech, e.g. "sv-SE": labels the M4A tracks so players pick the chapters.
    public var language: String?

    public init(format: ExportFormat, bitDepth: Int = 24, bitRate: Int = 160_000, id3: Data? = nil, chapters: [Chapter] = [], language: String? = nil) {
        self.format = format
        self.bitDepth = bitDepth
        self.bitRate = bitRate
        self.id3 = id3
        self.chapters = chapters
        self.language = language
    }
}

public enum ExportError: Error, LocalizedError, Equatable {
    case unsupported(String)
    case encoder(String, OSStatus)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let m): m
        case .encoder(let what, let status): "The encoder couldn't \(what) (error \(status))."
        }
    }
    /// The same message by its key in the app's string catalogue (see `KeyedMessage`).
    public var keyed: KeyedMessage? {
        switch self {
        case .unsupported: nil
        case .encoder(let what, let status): KeyedMessage("error.export.encoder", ["\(what)", "\(status)"])
        }
    }
}

/// A file writer fed interleaved float blocks (MP3 plugs in through this).
public protocol StreamingAudioWriter: AnyObject {
    func write(_ samples: UnsafeBufferPointer<Float>) throws
    func finish() throws
}

/// Writes a rendered plan to AIFF, FLAC, ALAC or AAC.
public final class EncodedWriter {
    /// MP3 comes from LAME (LGPL, a separate dynamic framework); the app registers it.
    nonisolated(unsafe) public static var mp3Factory: ((_ url: URL, _ channels: Int, _ sampleRate: Double, _ bitRate: Int, _ id3: Data?) throws -> StreamingAudioWriter)?

    private var file: ExtAudioFileRef?
    let channels: Int

    public init(url: URL, options: EncodedExportOptions, channels: Int, sampleRate: Double) throws {
        self.channels = channels
        guard options.format != .wav, options.format != .opus, options.format != .mp3, options.format != .apac else {
            throw ExportError.unsupported("Use WAVWriter for WAV, OggOpusWriter for Opus, mp3Factory for MP3 and APACWriter for APAC.")
        }
        if options.format.isLossless, !options.format.bitDepths.contains(options.bitDepth) {
            throw ExportError.unsupported("\(options.format.rawValue.uppercased()) takes \(options.format.bitDepths.map(String.init).joined(separator: " or ")) bits.")
        }
        var dst = AudioStreamBasicDescription()
        dst.mSampleRate = sampleRate
        dst.mChannelsPerFrame = UInt32(channels)
        let type: AudioFileTypeID
        switch options.format {
        case .aiff:
            type = kAudioFileAIFFType
            dst.mFormatID = kAudioFormatLinearPCM
            dst.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsBigEndian | kAudioFormatFlagIsPacked
            dst.mBitsPerChannel = UInt32(options.bitDepth)
            dst.mBytesPerFrame = UInt32(options.bitDepth / 8 * channels)
            dst.mBytesPerPacket = dst.mBytesPerFrame
            dst.mFramesPerPacket = 1
        case .flac:
            type = kAudioFileFLACType
            dst.mFormatID = kAudioFormatFLAC
            dst.mFormatFlags = options.bitDepth == 16 ? kAppleLosslessFormatFlag_16BitSourceData : kAppleLosslessFormatFlag_24BitSourceData
        case .alac:
            type = kAudioFileM4AType
            dst.mFormatID = kAudioFormatAppleLossless
            dst.mFormatFlags = options.bitDepth == 16 ? kAppleLosslessFormatFlag_16BitSourceData : kAppleLosslessFormatFlag_24BitSourceData
        case .aac:
            type = kAudioFileM4AType
            dst.mFormatID = kAudioFormatMPEG4AAC
        case .wav, .opus, .mp3, .apac:
            fatalError()
        }
        if options.format != .aiff {
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let s = AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &size, &dst)
            guard s == noErr else { throw ExportError.encoder("describe the format", s) }
        }
        var ref: ExtAudioFileRef?
        var status = ExtAudioFileCreateWithURL(url as CFURL, type, &dst, nil, AudioFileFlags.eraseFile.rawValue, &ref)
        guard status == noErr, let ref else { throw ExportError.encoder("create \(url.lastPathComponent)", status) }
        file = ref
        var client = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        status = ExtAudioFileSetProperty(ref, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard status == noErr else { throw ExportError.encoder("accept float audio", status) }
        if options.format == .aac {
            var converter: AudioConverterRef?
            var size = UInt32(MemoryLayout<AudioConverterRef?>.size)
            ExtAudioFileGetProperty(ref, kExtAudioFileProperty_AudioConverter, &size, &converter)
            if let converter {
                var rate = UInt32(options.bitRate)
                AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &rate)
                // Tells ExtAudioFile to apply the converter change (an empty configuration).
                var none: Unmanaged<CFArray>?
                withUnsafeMutablePointer(to: &none) { ptr in
                    _ = ExtAudioFileSetProperty(ref, kExtAudioFileProperty_ConverterConfig, UInt32(MemoryLayout<Unmanaged<CFArray>?>.size), ptr)
                }
            }
        }
    }

    deinit { if let file { ExtAudioFileDispose(file) } }

    public func write(_ samples: UnsafeBufferPointer<Float>) throws {
        guard let file, let base = samples.baseAddress else { return }
        let frames = samples.count / channels
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(samples.count * 4),
                                                                              mData: UnsafeMutableRawPointer(mutating: base)))
        let status = ExtAudioFileWrite(file, UInt32(frames), &list)
        guard status == noErr else { throw ExportError.encoder("encode", status) }
    }

    public func finish() throws {
        guard let f = file else { return }
        file = nil
        let status = ExtAudioFileDispose(f)
        guard status == noErr else { throw ExportError.encoder("finish the file", status) }
    }

    /// Renders `range` of a plan into a file in one go.
    public static func export(_ plan: RenderPlan, range: Range<Frame>, to url: URL, options: EncodedExportOptions,
                              progress: (Double) -> Bool = { _ in true }) throws {
        if options.format == .apac {
            try APACWriter.export(plan, range: range, to: url, progress: progress)
            return
        }
        if options.format == .opus {
            try OggOpusWriter.export(plan, range: range, to: url, bitRate: options.bitRate, chapters: options.chapters)
            _ = progress(1)
            return
        }
        if options.format == .mp3 {
            guard let make = mp3Factory else { throw ExportError.unsupported("MP3 isn't available in this build.") }
            let w = try make(url, plan.channels, plan.sampleRate, options.bitRate, options.id3)
            try plan.render(range) { try w.write($0) }
            try w.finish()
            _ = progress(1)
            return
        }
        if options.format == .aac || options.format == .alac, !options.chapters.isEmpty {
            try M4AChapterWriter.export(plan, range: range, to: url, options: options, progress: progress)
            return
        }
        let w = try EncodedWriter(url: url, options: options, channels: plan.channels, sampleRate: plan.sampleRate)
        var done: Frame = 0
        var cancelled = false
        try plan.render(range) { block in
            guard !cancelled else { return }
            try w.write(block)
            done += Frame(block.count / plan.channels)
            if !progress(Double(done) / Double(max(1, range.count))) { cancelled = true }
        }
        try w.finish()
        if cancelled {
            try? FileManager.default.removeItem(at: url)
            throw CancellationError()
        }
    }
}

extension ExportError: KeyedFailure {}
