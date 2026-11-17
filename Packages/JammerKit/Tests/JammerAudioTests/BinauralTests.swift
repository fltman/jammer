import AudioToolbox
import Foundation
import Testing
@testable import JammerAudio
import JammerCore

/// A bed of `channels` with a 1 kHz tone in one channel, for the spatial mixer to pull.
private final class Bed {
    let channels: Int, lit: Int
    /// For a sound field: the tone encoded with these gains into every component (else one channel lit).
    let gains: [Float]?
    var phase = 0.0
    init(channels: Int, lit: Int, gains: [Float]? = nil) { self.channels = channels; self.lit = lit; self.gains = gains }
}

private func bedRender(_ ref: UnsafeMutableRawPointer, _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ ts: UnsafePointer<AudioTimeStamp>,
                       _ bus: UInt32, _ frames: UInt32, _ data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let bed = Unmanaged<Bed>.fromOpaque(ref).takeUnretainedValue()
    guard let data else { return noErr }
    let list = UnsafeMutableAudioBufferListPointer(data)
    for (c, buffer) in list.enumerated() {
        guard let p = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let g: Float = bed.gains.map { $0[c] } ?? (c == bed.lit ? 1 : 0)
        for i in 0..<Int(frames) { p[i] = g * Float(0.3 * sin(bed.phase + 2 * .pi * 1_000 * Double(i) / 48_000)) }
    }
    bed.phase += 2 * .pi * 1_000 * Double(frames) / 48_000
    return noErr
}

@Suite("Binaural listening through the spatial mixer")
struct BinauralTests {
    /// The energy at the left and the right ear for a tone in one channel of a layout.
    func ears(_ layout: ChannelLayout, lit: Int, gains: [Float]? = nil, head: HeadPose? = nil) throws -> (left: Double, right: Double) {
        let bed = Bed(channels: layout.channels, lit: lit, gains: gains)
        let ref = Unmanaged.passRetained(bed)
        defer { ref.release() }
        let mixer = try Binaural.makeMixer(layout: layout, rate: 48_000, callback: AURenderCallbackStruct(inputProc: bedRender, inputProcRefCon: ref.toOpaque()))
        defer { AudioComponentInstanceDispose(mixer) }
        try #require(AudioUnitInitialize(mixer) == noErr)
        if let head { Binaural.setHead(mixer, head) }
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

    @Test("An AmbiX field through the spatial mixer: a tone encoded at 90° left reaches the left ear more, at 90° right the right ear, in first and third order")
    func ambisonicField() throws {
        func db(_ e: (left: Double, right: Double)) -> Double { 10 * log10(e.left / e.right) }
        for layout in [ChannelLayout.ambix1, .ambix3] {
            let left = try ears(layout, lit: -1, gains: Ambisonics.encode(azimuth: 90, elevation: 0, order: layout.ambisonicOrder!))
            let right = try ears(layout, lit: -1, gains: Ambisonics.encode(azimuth: -90, elevation: 0, order: layout.ambisonicOrder!))
            #expect(left.left > 0 && db(left) > 3 && db(right) < -3, "\(layout.rawValue): left \(db(left)) dB, right \(db(right)) dB")
        }
    }

    @Test("The head followed: turned left, a voice in front moves to the right ear, turned right to the left ear; looking up, a sound above-left at 45° is more to the side than looking down; tilted to the right shoulder it stays to the left, tilted to the left it comes over the head to the middle (the spatial mixer's convention, measured)")
    func head() throws {
        func db(_ e: (left: Double, right: Double)) -> Double { 10 * log10(e.left / e.right) }
        func with(_ pose: HeadPose, _ layout: ChannelLayout, lit: Int) throws -> Double {
            try db(ears(layout, lit: lit, head: pose))
        }
        let front = try with(HeadPose(), .surround51, lit: 2)
        #expect(abs(front) < 1, "facing the front: \(front)")
        let left = try with(HeadPose(yaw: 40), .surround51, lit: 2), right = try with(HeadPose(yaw: -40), .surround51, lit: 2)
        #expect(left < -3 && right > 3, "head left: \(left) dB, head right: \(right) dB (left ear over right)")
        // 7.1.4's top front left (45° left, 30° up), channel 8 in the document's order.
        let up = try with(HeadPose(pitch: 40), .immersive714, lit: 8), down = try with(HeadPose(pitch: -40), .immersive714, lit: 8)
        #expect(up > down + 1, "looking up \(up) dB, down \(down) dB")
        let towardRight = try with(HeadPose(roll: 40), .immersive714, lit: 8), towardLeft = try with(HeadPose(roll: -40), .immersive714, lit: 8)
        #expect(towardRight > 3 && towardLeft < 1, "tilted right \(towardRight) dB, tilted left \(towardLeft) dB")
        // Out of range is held to the mixer's: a turn of 270° left is 90° right.
        #expect(Binaural.wrapped(270) == -90 && Binaural.wrapped(-190) == 170)
    }
}
