import AudioToolbox
import Foundation

/// Export formats beyond WAV, through Apple's encoders (ExtAudioFile). WAV and RF64 stay
/// with `WAVWriter`, which keeps bext, iXML and markers.
public enum ExportFormat: String, Sendable, Codable, CaseIterable {
    case wav, aiff, flac, alac, aac

    public var fileExtension: String {
        switch self {
        case .wav: "wav"
        case .aiff: "aiff"
        case .flac: "flac"
        case .alac, .aac: "m4a"
        }
    }

    public var isLossless: Bool { self != .aac }
    /// Bit depths a format can store (AAC has none).
    public var bitDepths: [Int] {
        switch self {
        case .wav: [16, 24, 32]
        case .aiff: [16, 24]
        case .flac: [16, 24]
        case .alac: [16, 24]
        case .aac: []
        }
    }
}

public struct EncodedExportOptions: Sendable {
    public var format: ExportFormat
    public var bitDepth: Int
    /// AAC only, bits per second (e.g. 128 000 for speech at 48 kHz stereo).
    public var bitRate: Int

    public init(format: ExportFormat, bitDepth: Int = 24, bitRate: Int = 160_000) {
        self.format = format
        self.bitDepth = bitDepth
        self.bitRate = bitRate
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
}

/// Writes a rendered plan to AIFF, FLAC, ALAC or AAC.
public final class EncodedWriter {
    private var file: ExtAudioFileRef?
    let channels: Int

    public init(url: URL, options: EncodedExportOptions, channels: Int, sampleRate: Double) throws {
        self.channels = channels
        guard options.format != .wav else { throw ExportError.unsupported("Use WAVWriter for WAV.") }
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
        case .wav:
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
                var none: CFArray?
                ExtAudioFileSetProperty(ref, kExtAudioFileProperty_ConverterConfig, UInt32(MemoryLayout<CFArray?>.size), &none)
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
