import AudioToolbox
import Foundation
import Testing
@testable import JammerAudio
import JammerCore

/// A bed of `channels` with a 1 kHz tone in one channel, for the spatial mixer to pull.
private final class Bed {
    let channels: Int, lit: Int
    var phase = 0.0
    init(channels: Int, lit: Int) { self.channels = channels; self.lit = lit }
}

private func bedRender(_ ref: UnsafeMutableRawPointer, _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ ts: UnsafePointer<AudioTimeStamp>,
                       _ bus: UInt32, _ frames: UInt32, _ data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let bed = Unmanaged<Bed>.fromOpaque(ref).takeUnretainedValue()
    guard let data else { return noErr }
    let list = UnsafeMutableAudioBufferListPointer(data)
    for (c, buffer) in list.enumerated() {
        guard let p = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
        for i in 0..<Int(frames) { p[i] = c == bed.lit ? Float(0.3 * sin(bed.phase + 2 * .pi * 1_000 * Double(i) / 48_000)) : 0 }
    }
    bed.phase += 2 * .pi * 1_000 * Double(frames) / 48_000
    return noErr
}

@Suite("Binaural listening through the spatial mixer")
struct BinauralTests {
    /// The energy at the left and the right ear for a tone in one channel of a layout.
    func ears(_ layout: ChannelLayout, lit: Int) throws -> (left: Double, right: Double) {
        let bed = Bed(channels: layout.channels, lit: lit)
        let ref = Unmanaged.passRetained(bed)
        defer { ref.release() }
        let mixer = try Binaural.makeMixer(layout: layout, rate: 48_000, callback: AURenderCallbackStruct(inputProc: bedRender, inputProcRefCon: ref.toOpaque()))
        defer { AudioComponentInstanceDispose(mixer) }
        try #require(AudioUnitInitialize(mixer) == noErr)
        let frames: UInt32 = 512
        var left = [Float](repeating: 0, count: Int(frames)), right = [Float](repeating: 0, count: Int(frames))
        var el = 0.0, er = 0.0
        var ts = AudioTimeStamp()
        ts.mFlags = .sampleTimeValid
        for block in 0..<60 {
            ts.mSampleTime = Double(block) * Double(frames)
            var flags = AudioUnitRenderActionFlags()
            let status = left.withUnsafeMutableBytes { l in right.withUnsafeMutableBytes { r -> OSStatus in
                let list = AudioBufferList.allocate(maximumBuffers: 2)
                defer { list.unsafeMutablePointer.deallocate() }
                list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: l.baseAddress)
                list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: r.baseAddress)
                return AudioUnitRender(mixer, &flags, &ts, 0, frames, list.unsafeMutablePointer)
            } }
            try #require(status == noErr, "render \(status)")
            if block >= 20 { for i in 0..<Int(frames) { el += Double(left[i] * left[i]); er += Double(right[i] * right[i]) } }
        }
        return (el, er)
    }

    @Test("A tone in 5.1's left surround is louder at the left ear, the right surround at the right, the centre the same at both; 7.1.4's left top front at the left ear")
    func sides() throws {
        let ls = try ears(.surround51, lit: 4), rs = try ears(.surround51, lit: 5), c = try ears(.surround51, lit: 2)
        func db(_ e: (left: Double, right: Double)) -> Double { 10 * log10(e.left / e.right) }
        #expect(ls.left > 0 && rs.right > 0 && c.left > 0, "the mixer renders sound")
        #expect(db(ls) > 3 && db(rs) < -3, "Ls \(db(ls)) dB, Rs \(db(rs)) dB (left over right)")
        #expect(abs(db(c)) < 1, "C \(db(c)) dB")
        let tfl = try ears(.immersive714, lit: 8)
        #expect(db(tfl) > 3, "Ltf \(db(tfl)) dB")
    }
}
