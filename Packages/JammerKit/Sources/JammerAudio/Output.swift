import AudioToolbox
import CoreAudio
import Foundation
import JammerCore
import JammerEngine

/// Plays an engine through the default output device. The device thread calls
/// straight into the C++ engine (`jm_engine_au_render`); no Swift runs there.
/// The default-output unit follows the user's device choice by itself.
@MainActor
public final class AudioOutput {
    public let channels: Int
    public let sampleRate: Double
    /// The engine; owned by this object.
    public let engine: OpaquePointer
    private var unit: AudioUnit?
    public private(set) var isRunning = false

    public init(channels: Int, sampleRate: Double) {
        self.channels = channels
        self.sampleRate = sampleRate
        // About 340 ms rendered ahead at 48 kHz: edits during playback show up after that.
        engine = jm_engine_create(Int32(channels), sampleRate, Int32(sampleRate * 0.34))
    }

    isolated deinit {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioComponentInstanceDispose(unit)
        }
        jm_engine_destroy(engine)
    }

    public func setPlan(_ plan: RenderPlan) { jm_engine_set_plan(engine, plan.pointer) }
    public var playhead: Frame { jm_engine_playhead(engine) }
    public var isPlaying: Bool { jm_engine_is_playing(engine) }
    public var underruns: Int64 { jm_engine_underruns(engine) }
    public func setGain(_ gain: Float) { jm_engine_set_gain(engine, gain) }
    public func takePeak(channel: Int) -> Float { jm_engine_take_peak(engine, Int32(channel)) }

    public func play(from frame: Frame) throws {
        try startDevice()
        jm_engine_play(engine, frame)
    }

    public func stop() {
        jm_engine_stop(engine)
    }

    /// Stops the device too (call when playback has ended, to let the device sleep).
    public func stopDevice() {
        guard isRunning, let unit else { return }
        AudioOutputUnitStop(unit)
        isRunning = false
    }

    private func startDevice() throws {
        if isRunning { return }
        if unit == nil { unit = try makeUnit() }
        guard let unit else { return }
        try check(AudioOutputUnitStart(unit), "start the output")
        isRunning = true
    }

    private func makeUnit() throws -> AudioUnit {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_DefaultOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw OutputError("No default output device.") }
        var u: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &u), "open the output")
        guard let unit = u else { throw OutputError("No default output device.") }
        // Non-interleaved float at the project rate; the unit converts to the device.
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32, mReserved: 0)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format,
                                       UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "set the format")
        var callback = AURenderCallbackStruct(inputProc: jm_engine_au_render, inputProcRefCon: UnsafeMutableRawPointer(engine))
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback,
                                       UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "connect the engine")
        try check(AudioUnitInitialize(unit), "initialise the output")
        return unit
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw OutputError("Couldn't \(what) (error \(status)).") }
    }
}

public struct OutputError: Error, LocalizedError {
    public let message: String
    init(_ m: String) { message = m }
    public var errorDescription: String? { message }
}
