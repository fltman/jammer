import AudioToolbox
import CoreAudio
import Foundation
import JammerCore
import JammerEngine

/// Plays an engine through the default output device.
///
/// Normally through the HAL: an IOProc on the device itself (`jm_engine_ioproc`,
/// C++, nonblocking; no Swift runs on the device thread). The engine's worker
/// resamples when the device runs at another rate than the project, so the
/// device rate is never changed behind the user's back. The default device,
/// its sample rate and its stream layout are followed while running.
///
/// If the device can't be driven that way (no float output streams), it falls
/// back to the default-output audio unit, which converts by itself.
@MainActor
public final class AudioOutput {
    /// `binaural`: through the spatial mixer for headphones; `spatialSpeakers`: through it for loudspeakers (an Ambisonics document).
    public enum Path: String, Sendable { case hal, audioUnit, binaural, spatialSpeakers }

    public let channels: Int
    public let sampleRate: Double
    /// The engine; owned by this object.
    public let engine: OpaquePointer
    public private(set) var isRunning = false
    /// How audio currently reaches the device.
    public private(set) var path: Path?
    public private(set) var deviceName: String?
    public var deviceRate: Double { jm_engine_output_rate(engine) }
    /// Called on the main actor after the device changed under us (new default, new rate).
    public var onDeviceChange: (() -> Void)?

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var unit: AudioUnit?
    /// The spatial mixer between the engine and the output unit, while listening binaurally.
    private var spatialMixer: AudioUnit?
    /// Listening on headphones through the spatial mixer (a document wider than stereo only). Changing it
    /// rebuilds the way to the device and carries on where it was.
    public var binaural = false {
        didSet {
            guard binaural != oldValue, channels > 2 else { return }
            // (An Ambisonics document is rebuilt too: headphones or loudspeakers.)
            rebuild()
        }
    }
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    /// The listener's head while it is followed (headphones with motion sensors), applied to the spatial mixer;
    /// nil faces the front. Only listening: the engine, exports and meters never see it.
    public var head: HeadPose? {
        didSet { if let spatialMixer { Binaural.setHead(spatialMixer, head ?? HeadPose()) } }
    }

    public init(channels: Int, sampleRate: Double) {
        self.channels = channels
        self.sampleRate = sampleRate
        // About 340 ms rendered ahead at 48 kHz: edits during playback show up after that.
        engine = jm_engine_create(Int32(channels), sampleRate, Int32(sampleRate * 0.34))
        listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
    }

    isolated deinit {
        for (object, address, block) in listeners {
            var a = address
            AudioObjectRemovePropertyListenerBlock(object, &a, DispatchQueue.main, block)
        }
        tearDown()
        jm_engine_destroy(engine)
    }

    public func setPlan(_ plan: RenderPlan) { jm_engine_set_plan(engine, plan.pointer) }
    public var playhead: Frame { jm_engine_playhead(engine) }
    public var isPlaying: Bool { jm_engine_is_playing(engine) }
    public var underruns: Int64 { jm_engine_underruns(engine) }
    /// Test copies: nothing reaches the device, after the meters have seen it.
    public func setSilent(_ silent: Bool) { jm_engine_set_silent(engine, silent) }
    /// Test copies: counts what is handed to the device (before the volume) from now on.
    public func startTap() { jm_engine_tap(engine, true) }
    /// The device frames handed over since `startTap`, and their level (RMS over all channels, dB; nil for silence).
    public var tapped: (frames: Int64, rmsDB: Double?) {
        var e = 0.0
        var n: Int64 = 0
        jm_engine_tap_read(engine, &e, &n)
        guard n > 0, e > 0 else { return (n, nil) }
        return (n, 10 * log10(e / Double(n * Int64(channels))))
    }
    public func setGain(_ gain: Float) { jm_engine_set_gain(engine, gain) }
    /// How far ahead of the playhead the engine renders, in seconds; 0 is the whole ring (about a third
    /// of a second). Short while a hand is on the mixer: a change is then heard that soon.
    public func setAhead(seconds: Double) { jm_engine_set_ahead(engine, Int32(max(0, seconds) * sampleRate)) }
    /// A level under a hand while the sound plays (see jm_engine_set_live_gain): `db` on a strip of the plan
    /// with that serial, in its lane's place (`replaces`) or on top of it. `serial` 0 takes it off.
    public func setLiveGain(kind: Int32, index: Int32, db: Double, replaces: Bool, serial: UInt64) {
        jm_engine_set_live_gain(engine, kind, index, Float(db), replaces, serial)
    }
    /// What the engine has put on since the last call: the strip, the frame of its timeline, the level in dB.
    public func takeApplied() -> [(kind: Int32, index: Int32, frame: Int64, db: Double)] {
        var out: [(Int32, Int32, Int64, Double)] = []
        var kinds = [Int32](repeating: 0, count: 1_024), indices = kinds, frames = [Int64](repeating: 0, count: 1_024), db = [Float](repeating: 0, count: 1_024)
        while true {
            let n = Int(jm_engine_take_applied(engine, &kinds, &indices, &frames, &db, 1_024))
            for i in 0..<n { out.append((kinds[i], indices[i], frames[i], Double(db[i]))) }
            if n < 1_024 { break }
        }
        return out.map { (kind: $0.0, index: $0.1, frame: $0.2, db: $0.3) }
    }
    /// The meters: each strip's highest sample after its fader over the blocks heard in `from..<to` (timeline
    /// frames), linear; kind 0 tracks, 1 buses, 2 the master (count 1). Lock-free.
    public func meterPeaks(from: Frame, to: Frame, kind: Int32, count: Int) -> [Float] {
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        jm_engine_meter_peaks(engine, from, to, kind, Int32(count), &out)
        return out
    }
    /// Seconds rendered and not yet played: how long a change to the plan takes to be heard from now.
    public var buffered: Double { Double(jm_engine_buffered(engine)) / sampleRate }
    /// How many plans have gone on from the one before without a reset since the engine was made.
    public var continued: Int64 { jm_engine_continued(engine) }
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
        guard isRunning else { return }
        if let procID { AudioDeviceStop(device, procID) }
        if let unit { AudioOutputUnitStop(unit) }
        isRunning = false
    }

    // MARK: Device

    private func startDevice() throws {
        if isRunning { return }
        if procID == nil && unit == nil {
            // An Ambisonics document is always heard through the spatial mixer (nothing else decodes it): for
            // headphones when binaural listening is on, else for loudspeakers.
            if channels > 2, let layout = ChannelLayout.standard(channels: channels), binaural || layout.isAmbisonic {
                do {
                    try openBinaural(layout, headphones: binaural)
                } catch {
                    tearDown()
                    if !layout.isAmbisonic { binaural = false }
                    throw error
                }
            } else {
            do {
                try openHAL()
            } catch {
                tearDown()
                unit = try makeUnit()
                path = .audioUnit
                deviceName = Self.defaultDevice().flatMap(Self.name)
            }
            }
        }
        if let procID {
            try check(AudioDeviceStart(device, procID), Said("output.do.start_the_output_device", "start the output device"))
        } else if let unit {
            try check(AudioOutputUnitStart(unit), Said("output.do.start_the_output", "start the output"))
        }
        isRunning = true
    }

    private func tearDown() {
        stopDevice()
        if let procID {
            AudioDeviceDestroyIOProcID(device, procID)
            self.procID = nil
        }
        if let unit {
            AudioComponentInstanceDispose(unit)
            self.unit = nil
        }
        if let spatialMixer {
            AudioComponentInstanceDispose(spatialMixer)
            self.spatialMixer = nil
        }
        for (i, l) in listeners.enumerated().reversed() where l.0 == device && device != kAudioObjectUnknown {
            var a = l.1
            AudioObjectRemovePropertyListenerBlock(l.0, &a, DispatchQueue.main, l.2)
            listeners.remove(at: i)
        }
        device = AudioObjectID(kAudioObjectUnknown)
        path = nil
    }

    private func openHAL() throws {
        guard let id = Self.defaultDevice() else { throw OutputError(Said("error.output.default_output_device", "No default output device.")) }
        let streams = try Self.outputChannels(id)
        guard !streams.isEmpty, try Self.outputIsFloat32(id) else { throw OutputError(Said("error.output.output_device_doesn_t", "The output device doesn't take float audio.")) }
        let rate = try Self.nominalRate(id)
        let slots = Self.slots(projectChannels: channels, streams: streams, stereo: Self.preferredStereo(id))
        guard !slots.isEmpty else { throw OutputError(Said("error.output.output_device_has_channels", "The output device has no channels.")) }
        var b = slots.map(\.buffer), c = slots.map(\.channel), s = slots.map(\.source), g = slots.map(\.gain)
        jm_engine_set_output(engine, rate, &b, &c, &s, &g, Int32(slots.count))
        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcID(id, jm_engine_ioproc, UnsafeMutableRawPointer(engine), &proc), Said("output.do.connect_to_the_output_device", "connect to the output device"))
        device = id
        procID = proc
        path = .hal
        deviceName = Self.name(id)
        listen(id, kAudioDevicePropertyNominalSampleRate)
        listen(id, kAudioDevicePropertyStreamConfiguration)
        listen(id, kAudioDevicePropertyDeviceIsAlive)
    }

    /// The way to the device changed (binaural on or off): rebuild and carry on where we were.
    private func rebuild() { deviceChanged() }

    /// Engine → spatial mixer (the document's channels as a bed, rendered for headphones) → the default output.
    private func openBinaural(_ layout: ChannelLayout, headphones: Bool = true) throws {
        var none: Int32 = 0
        jm_engine_set_output(engine, sampleRate, &none, &none, &none, nil, 0)
        let mixer = try Binaural.makeMixer(layout: layout, rate: sampleRate,
                                           callback: AURenderCallbackStruct(inputProc: jm_engine_au_render, inputProcRefCon: UnsafeMutableRawPointer(engine)),
                                           headphones: headphones)
        spatialMixer = mixer
        if let head { Binaural.setHead(mixer, head) }
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_DefaultOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw OutputError(Said("error.output.default_output_device", "No default output device.")) }
        var u: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &u), Said("output.do.open_the_output", "open the output"))
        guard let out = u else { throw OutputError(Said("error.output.default_output_device", "No default output device.")) }
        unit = out
        var stereo = Binaural.format(2, sampleRate)
        try check(AudioUnitSetProperty(out, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &stereo,
                                       UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), Said("output.do.set_the_format", "set the format"))
        var connection = AudioUnitConnection(sourceAudioUnit: mixer, sourceOutputNumber: 0, destInputNumber: 0)
        try check(AudioUnitSetProperty(out, kAudioUnitProperty_MakeConnection, kAudioUnitScope_Input, 0, &connection,
                                       UInt32(MemoryLayout<AudioUnitConnection>.size)), Said("output.do.connect_the_spatial_mixer", "connect the spatial mixer"))
        try check(AudioUnitInitialize(mixer), Said("output.do.initialize_the_spatial_mixer", "initialize the spatial mixer"))
        try check(AudioUnitInitialize(out), Said("output.do.initialize_the_output", "initialize the output"))
        path = headphones ? .binaural : .spatialSpeakers
        deviceName = Self.defaultDevice().flatMap(Self.name)
    }

    /// The default device, its rate or its layout changed: rebuild and carry on where we were.
    private func deviceChanged() {
        guard procID != nil || unit != nil else { return }
        let wasRunning = isRunning
        let wasPlaying = isPlaying
        let at = playhead
        tearDown()
        if wasRunning {
            try? startDevice()
            if wasPlaying { jm_engine_play(engine, at) }
        }
        onDeviceChange?()
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.deviceChanged() }
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr {
            listeners.append((object, address, block))
        }
    }

    // MARK: Routing

    nonisolated struct Slot: Equatable, Sendable {
        var buffer: Int32; var channel: Int32; var source: Int32
        /// For a fold-down: several slots feed one device channel, each with its gain.
        var gain: Float = 1
    }

    /// Which device channel plays which project channel. `streams` is the channel count
    /// of each output buffer; `stereo` the device's preferred pair (1-based, across buffers).
    /// Mono goes to both channels of the pair; stereo to the pair; more channels in order.
    nonisolated static func slots(projectChannels: Int, streams: [Int], stereo: (Int, Int)?) -> [Slot] {
        var all: [(Int32, Int32)] = []
        for (b, n) in streams.enumerated() { for c in 0..<n { all.append((Int32(b), Int32(c))) } }
        guard !all.isEmpty else { return [] }
        func at(_ oneBased: Int) -> (Int32, Int32)? { (1...all.count).contains(oneBased) ? all[oneBased - 1] : nil }
        let pair = stereo.flatMap { p in at(p.0).flatMap { l in at(p.1).map { (l, $0) } } }
            ?? (all.count >= 2 ? (all[0], all[1]) : nil)
        switch projectChannels {
        case 1:
            guard let pair else { return [Slot(buffer: all[0].0, channel: all[0].1, source: 0)] }
            return [Slot(buffer: pair.0.0, channel: pair.0.1, source: 0), Slot(buffer: pair.1.0, channel: pair.1.1, source: 0)]
        case 2:
            guard let pair else { return [Slot(buffer: all[0].0, channel: all[0].1, source: 0)] }
            return [Slot(buffer: pair.0.0, channel: pair.0.1, source: 0), Slot(buffer: pair.1.0, channel: pair.1.1, source: 1)]
        default:
            // A document wider than stereo on a device with fewer channels than it has: folded down to the
            // stereo pair for listening, by the same coefficients as a wide source in a stereo document
            // (ChannelLayout.gains). The document and its exports keep their channels.
            if all.count < projectChannels, let pair, let layout = ChannelLayout.standard(channels: projectChannels) {
                let m = ChannelLayout.gains(from: layout, to: .stereo)
                var out: [Slot] = []
                for k in 0..<projectChannels {
                    for (d, dev) in [pair.0, pair.1].enumerated() where m[k * 2 + d] != 0 {
                        out.append(Slot(buffer: dev.0, channel: dev.1, source: Int32(k), gain: m[k * 2 + d]))
                    }
                }
                return out
            }
            return all.prefix(projectChannels).enumerated().map { Slot(buffer: $1.0, channel: $1.1, source: Int32($0)) }
        }
    }

    /// Whether a document of this many channels is folded down to fit the default device (for the window to say so).
    nonisolated static func foldsDown(projectChannels: Int, deviceChannels: Int) -> Bool { projectChannels > 2 && deviceChannels < projectChannels }

    // MARK: HAL queries

    nonisolated static func defaultDevice() -> AudioObjectID? {
        var id = AudioObjectID(kAudioObjectUnknown)
        guard get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    nonisolated static func nominalRate(_ id: AudioObjectID) throws -> Double {
        var rate: Float64 = 0
        let status = get(id, kAudioDevicePropertyNominalSampleRate, &rate)
        guard status == noErr, rate > 0 else { throw OutputError(Said("error.output.couldn_t_read_device", "Couldn't read the device's sample rate (error %@).", "\(status)")) }
        return rate
    }

    nonisolated static func name(_ id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var name: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
        guard status == noErr, let n = name else { return nil }
        return n.takeRetainedValue() as String
    }

    /// Channels per output buffer, as the IOProc will see them.
    nonisolated static func outputChannels(_ id: AudioObjectID) throws -> [Int] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size), Said("output.do.read_the_device_layout", "read the device layout"))
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw), Said("output.do.read_the_device_layout", "read the device layout"))
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    /// Every output stream's virtual format is 32-bit float (what the IOProc writes).
    nonisolated static func outputIsFloat32(_ id: AudioObjectID) throws -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size), Said("output.do.read_the_device_streams", "read the device streams"))
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &streams), Said("output.do.read_the_device_streams", "read the device streams"))
        return !streams.isEmpty && streams.allSatisfy { s in
            var f = AudioStreamBasicDescription()
            guard get(s, kAudioStreamPropertyVirtualFormat, &f) == noErr else { return false }
            return f.mFormatID == kAudioFormatLinearPCM && f.mFormatFlags & kAudioFormatFlagIsFloat != 0 && f.mBitsPerChannel == 32
        }
    }

    nonisolated static func preferredStereo(_ id: AudioObjectID) -> (Int, Int)? {
        var pair: [UInt32] = [0, 0]
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
                                                 mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<UInt32>.size * 2)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &pair) == noErr, pair[0] > 0, pair[1] > 0 else { return nil }
        return (Int(pair[0]), Int(pair[1]))
    }

    nonisolated private static func get<T: BitwiseCopyable>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> OSStatus {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
    }

    // MARK: Fallback: the default-output unit

    private func makeUnit() throws -> AudioUnit {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_DefaultOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw OutputError(Said("error.output.default_output_device", "No default output device.")) }
        var u: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &u), Said("output.do.open_the_output", "open the output"))
        guard let unit = u else { throw OutputError(Said("error.output.default_output_device", "No default output device.")) }
        // The unit converts rate and layout itself, so the engine runs at the project rate.
        var none: Int32 = 0
        jm_engine_set_output(engine, sampleRate, &none, &none, &none, nil, 0)
        // Non-interleaved float at the project rate; the unit converts to the device.
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32, mReserved: 0)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format,
                                       UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), Said("output.do.set_the_format", "set the format"))
        var callback = AURenderCallbackStruct(inputProc: jm_engine_au_render, inputProcRefCon: UnsafeMutableRawPointer(engine))
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback,
                                       UInt32(MemoryLayout<AURenderCallbackStruct>.size)), Said("output.do.connect_the_engine", "connect the engine"))
        try check(AudioUnitInitialize(unit), Said("output.do.initialize_the_output", "initialize the output"))
        return unit
    }
}

private func check(_ status: OSStatus, _ what: Said) throws {
    guard status == noErr else { throw OutputError(Said("error.output.couldnt", "Couldn't %2$@ (error %1$@).", "\(status)", inner: what)) }
}

public struct OutputError: Error, LocalizedError, KeyedFailure {
    public let message: String
    public let keyed: KeyedMessage?
    init(_ said: Said) { message = said.text; keyed = said.keyed }
    public var errorDescription: String? { message }
}
