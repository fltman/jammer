import AudioToolbox
import Foundation

/// Where the listener's head points, in degrees, for listening on headphones only (never an export or a meter):
/// yaw positive turned to the left (as an azimuth), pitch positive looking up, roll positive tilted toward the
/// right shoulder (the left side lifted, as a field's roll). Relative to where the head was when it was centred.
public struct HeadPose: Equatable, Sendable {
    public var yaw: Double, pitch: Double, roll: Double
    public init(yaw: Double = 0, pitch: Double = 0, roll: Double = 0) { self.yaw = yaw; self.pitch = pitch; self.roll = roll }

}

extension Binaural {
    /// Turns the spatial mixer's listener to the head's pose. The mixer's own parameters are the aircraft's
    /// convention, measured here (BinauralTests.head): HeadYaw positive turns the head to the right, HeadPitch
    /// positive looks up, HeadRoll positive tilts toward the right shoulder. Not on the audio thread.
    public static func setHead(_ mixer: AudioUnit, _ pose: HeadPose) {
        func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Float { Float(min(r.upperBound, max(r.lowerBound, v))) }
        AudioUnitSetParameter(mixer, kSpatialMixerParam_HeadYaw, kAudioUnitScope_Global, 0, clamp(-wrapped(pose.yaw), -180...180), 0)
        AudioUnitSetParameter(mixer, kSpatialMixerParam_HeadPitch, kAudioUnitScope_Global, 0, clamp(pose.pitch, -90...90), 0)
        AudioUnitSetParameter(mixer, kSpatialMixerParam_HeadRoll, kAudioUnitScope_Global, 0, clamp(wrapped(pose.roll), -180...180), 0)
    }
    static func wrapped(_ a: Double) -> Double { let r = (a + 180).truncatingRemainder(dividingBy: 360); return (r < 0 ? r + 360 : r) - 180 }
}
