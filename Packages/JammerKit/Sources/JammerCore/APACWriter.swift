import AudioToolbox
import Foundation

/// APAC (Apple Positional Audio Codec) in MP4, by the encoder that comes with macOS 26 and later, for a
/// document in 5.1, 7.1 or 7.1.4: the channels as a bed in their layout. Settings as Apple's APAC paper
/// (June 2025) gives them: the content source, the loudness/DRC configuration (required: "None should not
/// be utilized"), and an audio synchronization packet every 75 packets. Objects and Ambisonics are not
/// written (Jämmer has no objects; Ambisonics documents aren't built).
public enum APACWriter {
    /// The channel layout tag whose order is the document's (as for listening: 5.1 MPEG_5_1_A, 7.1 WAVE_7_1, 7.1.4 CICP_19).
    public static func tag(_ layout: ChannelLayout) -> AudioChannelLayoutTag? {
        switch layout {
        case .surround51: kAudioChannelLayoutTag_MPEG_5_1_A
        case .surround71: kAudioChannelLayoutTag_WAVE_7_1
        case .immersive714: kAudioChannelLayoutTag_CICP_19
        // AmbiX: Core Audio's ACN/SN3D tag, ORed with the channel count (CoreAudioBaseTypes.h).
        case .ambix1, .ambix2, .ambix3: kAudioChannelLayoutTag_HOA_ACN_SN3D | AudioChannelLayoutTag(layout.channels)
        case .mono, .stereo: nil
        }
    }

    /// Through AudioToolbox (an ExtAudioFile with the APAC encoder): AVAssetWriter takes only Apple's own
    /// content-source labels (1–10), and this is not Apple's content. Content source 38, "Traditional
    /// professional AV offline encoded content such as stereo and multichannel"; DRC configuration Movie.
    public static func export(_ plan: RenderPlan, range: Range<Frame>, to url: URL, progress: (Double) -> Bool = { _ in true }) throws {
        guard let layout = ChannelLayout.standard(channels: plan.channels), let tag = tag(layout) else {
            throw ExportError.unsupported("APAC is written for 5.1, 7.1, 7.1.4 and Ambisonics documents.")
        }
        try? FileManager.default.removeItem(at: url)
        let sr = plan.sampleRate, ch = plan.channels
        var dst = AudioStreamBasicDescription()
        dst.mSampleRate = sr
        dst.mChannelsPerFrame = UInt32(ch)
        dst.mFormatID = kAudioFormatAPAC
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var status = AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &size, &dst)
        guard status == noErr else { throw ExportError.unsupported("This Mac can't write APAC (it needs macOS 26 or later).") }
        var channelLayout = AudioChannelLayout(mChannelLayoutTag: tag, mChannelBitmap: [], mNumberChannelDescriptions: 0, mChannelDescriptions: AudioChannelDescription())
        var ref: ExtAudioFileRef?
        status = ExtAudioFileCreateWithURL(url as CFURL, kAudioFileMPEG4Type, &dst, &channelLayout, AudioFileFlags.eraseFile.rawValue, &ref)
        guard status == noErr, let file = ref else { throw ExportError.encoder("create \(url.lastPathComponent)", status) }
        var closed = false
        defer { if !closed { ExtAudioFileDispose(file) } }
        var client = AudioStreamBasicDescription(
            mSampleRate: sr, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * ch), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * ch), mChannelsPerFrame: UInt32(ch),
            mBitsPerChannel: 32, mReserved: 0)
        status = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard status == noErr else { throw ExportError.encoder("accept float audio", status) }
        status = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientChannelLayout, UInt32(MemoryLayout<AudioChannelLayout>.size), &channelLayout)
        guard status == noErr else { throw ExportError.encoder("set the layout", status) }
        // The encoder's settings, on its converter, then applied.
        var converter: AudioConverterRef?
        var csize = UInt32(MemoryLayout<AudioConverterRef?>.size)
        status = ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioConverter, &csize, &converter)
        guard status == noErr, let converter else { throw ExportError.encoder("reach the encoder", status) }
        // A sound field is spatial content (39); loudspeaker beds are traditional multichannel (38).
        var source = Int32(layout.isAmbisonic ? kAudioCodecContentSource_AV_Spatial_Offline : kAudioCodecContentSource_AV_Traditional_Offline)
        var drc = UInt32(kAudioCodecDynamicRangeControlConfiguration_Movie)
        var asp: UInt32 = 75
        status = AudioConverterSetProperty(converter, kAudioCodecPropertyContentSource, 4, &source)
        guard status == noErr else { throw ExportError.encoder("set the content source", status) }
        status = AudioConverterSetProperty(converter, kAudioCodecPropertyDynamicRangeControlConfiguration, 4, &drc)
        guard status == noErr else { throw ExportError.encoder("set the loudness configuration", status) }
        status = AudioConverterSetProperty(converter, kAudioCodecPropertyASPFrequency, 4, &asp)
        guard status == noErr else { throw ExportError.encoder("set the sync packets", status) }
        var none: CFArray? = nil
        status = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ConverterConfig, UInt32(MemoryLayout<CFArray?>.size), &none)
        guard status == noErr else { throw ExportError.encoder("apply the encoder's settings", status) }
        var done: Frame = 0
        var cancelled = false
        try plan.render(range, blockFrames: 16_384) { block in
            guard !cancelled else { return }
            let frames = block.count / ch
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(ch), mDataByteSize: UInt32(block.count * 4),
                                                                                  mData: UnsafeMutableRawPointer(mutating: block.baseAddress)))
            let s = ExtAudioFileWrite(file, UInt32(frames), &list)
            guard s == noErr else { throw ExportError.encoder("encode", s) }
            done += Frame(frames)
            if !progress(Double(done) / Double(max(1, range.count))) { cancelled = true }
        }
        closed = true
        status = ExtAudioFileDispose(file)
        if cancelled {
            try? FileManager.default.removeItem(at: url)
            throw CancellationError()
        }
        guard status == noErr else { throw ExportError.encoder("finish the file", status) }
    }
}
