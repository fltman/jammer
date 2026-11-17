import AVFoundation
import CoreMedia
import Foundation

/// AAC or ALAC in M4A with chapters, the way Apple Podcasts and QuickTime read them: a
/// QuickTime text track holding the chapter titles, linked from the audio track as its
/// chapter list. Written with AVAssetWriter (Apple's encoders, as in the plain export).
public enum M4AChapterWriter {
    public static func export(_ plan: RenderPlan, range: Range<Frame>, to url: URL, options: EncodedExportOptions,
                              progress: (Double) -> Bool = { _ in true }) throws {
        precondition(options.format == .aac || options.format == .alac)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let sr = plan.sampleRate, ch = plan.channels
        var settings: [String: Any] = [AVSampleRateKey: sr, AVNumberOfChannelsKey: ch]
        if options.format == .aac {
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = options.bitRate
        } else {
            settings[AVFormatIDKey] = kAudioFormatAppleLossless
            settings[AVEncoderBitDepthHintKey] = options.bitDepth
        }
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        audio.expectsMediaDataInRealTime = false
        let chapterFormat = try textFormat()
        let text = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: chapterFormat)
        text.expectsMediaDataInRealTime = false
        text.marksOutputTrackAsEnabled = false
        if let tag = options.language, let code = Locale(identifier: tag).language.languageCode?.identifier(.alpha3) {
            for input in [audio, text] {
                input.languageCode = code
                input.extendedLanguageTag = tag
            }
        }
        guard writer.canAdd(audio), writer.canAdd(text) else { throw ExportError.unsupported(Said("error.export.can_t_write_chapters", "Can't write chapters into M4A here.")) }
        writer.add(audio)
        writer.add(text)
        audio.addTrackAssociation(withTrackOf: text, type: AVAssetTrack.AssociationType.chapterList.rawValue)
        guard writer.startWriting() else { throw writer.error ?? ExportError.unsupported(Said("error.export.m4a_writer_didn_t", "The M4A writer didn't start.")) }
        writer.startSession(atSourceTime: .zero)

        let total = Double(range.count) / sr
        let chapters = options.chapters.filter { $0.start < total }.sorted { $0.start < $1.start }
        var nextChapter = 0
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sr, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * ch), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * ch), mChannelsPerFrame: UInt32(ch),
            mBitsPerChannel: 32, mReserved: 0)
        var pcmFormat: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                       extensions: nil, formatDescriptionOut: &pcmFormat)
        guard let pcmFormat else { throw ExportError.unsupported(Said("error.export.can_t_describe_audio", "Can't describe the audio for the M4A writer.")) }

        func wait(_ input: AVAssetWriterInput) throws {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? ExportError.encoder("encode", -1) }
                usleep(2_000)
            }
        }
        // Chapter samples go in as the audio reaches them, so the writer can interleave.
        func appendChapters(upTo seconds: Double) throws {
            while nextChapter < chapters.count, chapters[nextChapter].start <= seconds {
                let c = chapters[nextChapter]
                let end = nextChapter + 1 < chapters.count ? chapters[nextChapter + 1].start : total
                try wait(text)
                guard text.append(try textSample(c.title, start: c.start, duration: max(0.001, end - c.start), format: chapterFormat)) else {
                    throw writer.error ?? ExportError.encoder("write a chapter", -1)
                }
                nextChapter += 1
            }
        }

        var done: Frame = 0
        var cancelled = false
        try plan.render(range, blockFrames: 16_384) { block in
            guard !cancelled else { return }
            let frames = block.count / ch
            try appendChapters(upTo: Double(done + Frame(frames)) / sr)
            let sample = try pcmSample(block, frames: frames, at: done, sampleRate: sr, format: pcmFormat)
            try wait(audio)
            guard audio.append(sample) else { throw writer.error ?? ExportError.encoder("encode", -1) }
            done += Frame(frames)
            if !progress(Double(done) / Double(max(1, range.count))) { cancelled = true }
        }
        try appendChapters(upTo: .infinity)
        audio.markAsFinished()
        text.markAsFinished()
        if cancelled {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw CancellationError()
        }
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else { throw writer.error ?? ExportError.encoder("finish the file", -1) }
    }

    static func pcmSample(_ block: UnsafeBufferPointer<Float>, frames: Int, at frame: Frame, sampleRate: Double,
                          format: CMAudioFormatDescription) throws -> CMSampleBuffer {
        var data: CMBlockBuffer?
        let bytes = block.count * 4
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &data) == noErr,
              let data, CMBlockBufferReplaceDataBytes(with: block.baseAddress!, blockBuffer: data, offsetIntoDestination: 0, dataLength: bytes) == noErr else {
            throw ExportError.encoder("buffer audio", -1)
        }
        var sample: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: data, formatDescription: format, sampleCount: frames,
            presentationTimeStamp: CMTime(value: frame, timescale: CMTimeScale(sampleRate)), packetDescriptions: nil, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw ExportError.encoder("buffer audio", status) }
        return sample
    }

    /// A QuickTime text sample: big-endian length, UTF-8 text, and an 'encd' atom saying UTF-8.
    static func textSample(_ title: String, start: Double, duration: Double, format: CMFormatDescription) throws -> CMSampleBuffer {
        let utf8 = Array(title.utf8.prefix(65_000))
        var payload = Data([UInt8(utf8.count >> 8), UInt8(utf8.count & 0xFF)])
        payload.append(contentsOf: utf8)
        payload.append(contentsOf: [0, 0, 0, 12] + Array("encd".utf8) + [0, 0, 1, 0])
        var data: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: payload.count, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: payload.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &data) == noErr,
              let data else { throw ExportError.encoder("buffer a chapter", -1) }
        _ = payload.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: data, offsetIntoDestination: 0, dataLength: payload.count) }
        var timing = CMSampleTimingInfo(duration: CMTime(seconds: duration, preferredTimescale: 1_000),
                                        presentationTimeStamp: CMTime(seconds: start, preferredTimescale: 1_000), decodeTimeStamp: .invalid)
        var size = payload.count
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreate(allocator: nil, dataBuffer: data, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                                          formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                          sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw ExportError.encoder("buffer a chapter", status) }
        return sample
    }

    /// The format of a QuickTime chapter text track, from a big-endian 'text' sample
    /// description (QuickTime File Format): no display flags, no box, default font. Built
    /// from the binary description because one made from extension keys is refused when
    /// the movie is finished (-12715).
    static func textFormat() throws -> CMFormatDescription {
        var b = [UInt8]()
        func u32(_ v: UInt32) { b += [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        func u16(_ v: UInt16) { b += [UInt8(v >> 8), UInt8(v & 0xFF)] }
        u32(0); b += Array("text".utf8); b += [0, 0, 0, 0, 0, 0]; u16(1) // size (patched), type, reserved, data reference
        u32(0); u32(0)                     // display flags, justification
        u16(0); u16(0); u16(0)             // background colour
        u16(0); u16(0); u16(0); u16(0)     // default text box
        u32(0); u32(0)                     // reserved
        u16(0); u16(0); b += [0]; u16(0)   // font number, face, reserved
        u16(0); u16(0); u16(0)             // foreground colour
        b += [0]                           // font name (empty Pascal string)
        let n = UInt32(b.count)
        b.replaceSubrange(0..<4, with: [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
        var desc: CMFormatDescription?
        let status = CMTextFormatDescriptionCreateFromBigEndianTextDescriptionData(allocator: nil, bigEndianTextDescriptionData: b, size: b.count,
                                                                                   flavor: nil, mediaType: kCMMediaType_Text, formatDescriptionOut: &desc)
        guard status == noErr, let desc else { throw ExportError.encoder("describe the chapter track", status) }
        return desc
    }
}
