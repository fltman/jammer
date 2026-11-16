import AVFoundation
import AudioToolbox
import Foundation
import JammerCore

/// An Audio Unit with a sidechain input and known arithmetic, registered in this test process only
/// (nothing is installed): where the key on its second input isn't silent, the audio is a quarter of
/// what came in; elsewhere it is untouched. It is here to try Jämmer's own wiring of an Audio Unit's
/// second input, which no effect on this Mac has. It is not a stand-in for another vendor's plugin.
final class KeyedGateAU: AUAudioUnit, @unchecked Sendable {
    static let componentDescription = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0x6A6D6B79 /* jmky */,
                                                                componentManufacturer: 0x4A6D6D72 /* Jmmr */, componentFlags: 0, componentFlagsMask: 0)
    static let plugin = PluginID("aufx/jmky/Jmmr")!
    static let registered: Bool = {
        AUAudioUnit.registerSubclass(KeyedGateAU.self, as: componentDescription, name: "Jammer: Keyed Gate (test)", version: 1)
        return true
    }()

    private var inputs: AUAudioUnitBusArray!
    private var outputs: AUAudioUnitBusArray!
    private let storage: UnsafeMutablePointer<Float>
    private let lists: [UnsafeMutableAudioBufferListPointer]
    private static let most = 4_096, channels = 2

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        storage = .allocate(capacity: Self.most * Self.channels * 2)
        storage.initialize(repeating: 0, count: Self.most * Self.channels * 2)
        lists = [AudioBufferList.allocate(maximumBuffers: Self.channels), AudioBufferList.allocate(maximumBuffers: Self.channels)]
        try super.init(componentDescription: componentDescription, options: options)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [try AUAudioUnitBus(format: format), try AUAudioUnitBus(format: format)])
        outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [try AUAudioUnitBus(format: format)])
        maximumFramesToRender = AUAudioFrameCount(Self.most)
    }
    deinit {
        storage.deallocate()
        for l in lists { free(l.unsafeMutablePointer) }
    }

    override var inputBusses: AUAudioUnitBusArray { inputs }
    override var outputBusses: AUAudioUnitBusArray { outputs }

    override var internalRenderBlock: AUInternalRenderBlock {
        let storage = storage, lists = lists, most = Self.most, channels = Self.channels
        return { _, timestamp, frames, _, output, _, pull in
            guard let pull, Int(frames) <= most else { return kAudioUnitErr_TooManyFramesToProcess }
            let n = Int(frames)
            // Both inputs into this unit's own memory: bus 0 the audio, bus 1 the key.
            for bus in 0..<2 {
                let list = lists[bus]
                list.count = channels
                for c in 0..<channels {
                    list[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: UnsafeMutableRawPointer(storage + (bus * channels + c) * most))
                }
                var flags = AudioUnitRenderActionFlags()
                let err = pull(&flags, timestamp, frames, bus, list.unsafeMutablePointer)
                guard err == noErr else { return err }
            }
            let out = UnsafeMutableAudioBufferListPointer(output)
            for i in 0..<n {
                var open = true
                for c in 0..<channels where lists[1][c].mData!.assumingMemoryBound(to: Float.self)[i] != 0 { open = false }
                if !open { for c in 0..<channels { lists[0][c].mData!.assumingMemoryBound(to: Float.self)[i] *= 0.25 } }
            }
            for c in 0..<out.count {
                let from = lists[0][min(c, channels - 1)].mData!
                if let to = out[c].mData { memcpy(to, from, n * 4) } else { out[c].mData = from }
                out[c].mDataByteSize = UInt32(n * 4)
            }
            return noErr
        }
    }
}
