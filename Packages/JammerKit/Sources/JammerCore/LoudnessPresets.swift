import Foundation

/// Delivery targets for loudness. Without a true-peak limiter (that comes with mastering),
/// a preset picks the gain that reaches the loudness target without the true peak passing
/// the ceiling, and says when the ceiling held it back.
public enum LoudnessPreset: String, Sendable, CaseIterable, Codable {
    case applePodcasts = "apple_podcasts", spotify, youtube, ebuR128 = "ebu_r128", atscA85 = "atsc_a85"

    public var title: String {
        switch self {
        case .applePodcasts: "Apple Podcasts (−16 LUFS, −1 dBTP)"
        case .spotify: "Spotify (−14 LUFS, −1 dBTP)"
        case .youtube: "YouTube (−14 LUFS, −1 dBTP)"
        case .ebuR128: "EBU R 128 broadcast (−23 LUFS, −1 dBTP)"
        case .atscA85: "ATSC A/85 broadcast (−24 LUFS, −2 dBTP)"
        }
    }

    public var integrated: Double {
        switch self {
        case .applePodcasts: -16
        case .spotify, .youtube: -14
        case .ebuR128: -23
        case .atscA85: -24
        }
    }

    public var truePeakCeiling: Double { self == .atscA85 ? -2 : -1 }

    public struct Plan: Sendable, Equatable {
        public var gainDB: Double
        public var integratedAfter: Double
        public var truePeakAfter: Double
        public var limitedByPeak: Bool
    }

    /// The gain for a measurement; nil when the range is silent.
    public func plan(for m: LoudnessResult) -> Plan? {
        guard let integrated = m.integrated, m.truePeak.isFinite else { return nil }
        let toTarget = self.integrated - integrated
        let toCeiling = truePeakCeiling - m.truePeak
        let gain = min(toTarget, toCeiling)
        return Plan(gainDB: (gain * 100).rounded() / 100, integratedAfter: integrated + gain, truePeakAfter: m.truePeak + gain,
                    limitedByPeak: toCeiling < toTarget)
    }
}
