import AudioToolbox
import CoreAudio
import Foundation
import JammerCore

/// Listening on headphones to a document wider than stereo: Apple's spatial mixer (AUSpatialMixer) takes the
/// document's channels as a bed, each channel from its loudspeaker's direction (the bus's channel layout),
/// and renders them for headphones. For listening only: exports and measurements are the document's channels.
/// No head tracking (it needs an entitlement that has to come with the app's signing).
public enum Binaural {
    /// The channel layout tag whose order is the document's (the WAV order): 5.1 as L R C LFE Ls Rs, 7.1 as
    /// WAVE_7_1 (L R C LFE Rls Rrs Ls Rs), 7.1.4 as CICP_19 (L R C LFE Rls Rrs Lss Rss Vhl Vhr Ltr Rtr).
    public static func tag(_ layout: ChannelLayout) -> AudioChannelLayoutTag {
        switch layout {
        case .mono: kAudioChannelLayoutTag_Mono
        case .stereo: kAudioChannelLayoutTag_Stereo
        case .surround51: kAudioChannelLayoutTag_MPEG_5_1_A
        case .surround71: kAudioChannelLayoutTag_WAVE_7_1
        case .immersive714: kAudioChannelLayoutTag_CICP_19
        }
    }

    static func format(_ channels: Int, _ rate: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: UInt32(channels),
                                    mBitsPerChannel: 32, mReserved: 0)
    }

    /// A spatial mixer set up for a bed in `layout` at `rate`, rendering for headphones, with `callback`
    /// feeding its one input. Not initialized (the caller connects it first).
    public static func makeMixer(layout: ChannelLayout, rate: Double, callback: AURenderCallbackStruct) throws -> AudioUnit {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Mixer, componentSubType: kAudioUnitSubType_SpatialMixer,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw OutputError("This Mac has no spatial mixer.") }
        var u: AudioUnit?
        try binauralCheck(AudioComponentInstanceNew(comp, &u), "open the spatial mixer")
        guard let mixer = u else { throw OutputError("This Mac has no spatial mixer.") }
        func set<T>(_ id: AudioUnitPropertyID, _ scope: AudioUnitScope, _ value: T, _ what: String) throws {
            var v = value
            try binauralCheck(AudioUnitSetProperty(mixer, id, scope, 0, &v, UInt32(MemoryLayout<T>.size)), what)
        }
        try set(kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, UInt32(1), "give the spatial mixer one input")
        try set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, format(layout.channels, rate), "set the bed's format")
        try set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, format(2, rate), "set the headphones' format")
        var channelLayout = AudioChannelLayout(mChannelLayoutTag: tag(layout), mChannelBitmap: [], mNumberChannelDescriptions: 0,
                                               mChannelDescriptions: AudioChannelDescription())
        try binauralCheck(AudioUnitSetProperty(mixer, kAudioUnitProperty_AudioChannelLayout, kAudioUnitScope_Input, 0, &channelLayout,
                                               UInt32(MemoryLayout<AudioChannelLayout>.size)), "set the bed's loudspeakers")
        try set(kAudioUnitProperty_SpatialMixerSourceMode, kAudioUnitScope_Input, AUSpatialMixerSourceMode.spatialMixerSourceMode_AmbienceBed.rawValue, "make the input a bed")
        try set(kAudioUnitProperty_SpatializationAlgorithm, kAudioUnitScope_Input, AUSpatializationAlgorithm.spatializationAlgorithm_UseOutputType.rawValue, "choose the rendering")
        try set(kAudioUnitProperty_SpatialMixerOutputType, kAudioUnitScope_Global, AUSpatialMixerOutputType.spatialMixerOutputType_Headphones.rawValue, "render for headphones")
        try set(kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, callback, "connect the engine")
        return mixer
    }
}

func binauralCheck(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw OutputError("Couldn't \(what) (error \(status)).") }
}
