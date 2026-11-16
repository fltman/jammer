import Foundation

/// Delivery targets for loudness. By itself a preset picks the gain that reaches the loudness
/// target without the true peak passing the ceiling, and says when the ceiling held it back;
/// with the limiter (`Project.matching`) it reaches the target and says what that cost.
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

public struct LoudnessMatch: Sendable, Equatable {
    public var gainDB = 0.0
    public var integratedBefore = 0.0
    public var integratedAfter = 0.0
    public var truePeakAfter = 0.0
    /// The ceiling kept the gain short of the target (only without the limiter, or when the limiter couldn't make up for it).
    public var limitedByPeak = false
    /// The limiter was used.
    public var limited = false
    public var reductionMaxDB = 0.0
    public var limitedSeconds = 0.0
    /// Loudness range before and after, LU: what the limiter took of the dynamics.
    public var rangeBefore: Double?
    public var rangeAfter: Double?
}

extension Project {
    /// Brings `range` to a preset's loudness. Without `limit`, or when the peaks leave room, it is one
    /// gain. With `limit` and peaks in the way, the gain goes all the way to the target and the limiter
    /// holds the peaks at the preset's ceiling; limiting takes a little loudness back, so the gain is
    /// corrected for that and the pass repeated (at most three times) until the result is within 0.1 LU.
    /// `measure` reads loudness the way the session does.
    public func matching(_ preset: LoudnessPreset, range r: Range<Frame>, limit: Bool, pool: SourcePool?, media: URL?,
                         measure: (Project, Range<Frame>) -> LoudnessResult) throws -> (Project, LoudnessMatch)? {
        let m = measure(self, r)
        guard let plan = preset.plan(for: m), let before = m.integrated else { return nil }
        var out = LoudnessMatch()
        out.integratedBefore = before
        out.rangeBefore = m.range
        guard limit, plan.limitedByPeak, let pool, let media else {
            var p = self
            try p.changeGain(r, by: plan.gainDB)
            out.gainDB = plan.gainDB
            out.integratedAfter = plan.integratedAfter
            out.truePeakAfter = plan.truePeakAfter
            out.limitedByPeak = plan.limitedByPeak
            out.rangeAfter = m.range
            return (p, out)
        }
        var gain = preset.integrated - before
        var best: (Project, LoudnessMatch)?
        var written: [URL] = []
        for _ in 0..<3 {
            var p = self
            try p.changeGain(r, by: gain)
            let (limited, report) = try p.limiting(Limiter(ceilingDB: preset.truePeakCeiling), range: r, pool: pool, media: media)
            let after = measure(limited, r)
            guard let reached = after.integrated else { break }
            var now = out
            now.gainDB = (gain * 100).rounded() / 100
            now.integratedAfter = reached
            now.truePeakAfter = report.truePeakAfterDB
            now.limited = true
            now.reductionMaxDB = report.reductionMaxDB
            now.limitedSeconds = report.limitedSeconds
            now.rangeAfter = after.range
            now.limitedByPeak = abs(preset.integrated - reached) > 0.1
            // The earlier try's files are not played by anything: take them away.
            let mine = Set(limited.sources.map(\.path)).subtracting(sources.map(\.path))
            for u in written where !mine.contains(u.path) { try? FileManager.default.removeItem(at: u) }
            written = mine.map { URL(fileURLWithPath: $0) }
            best = (limited, now)
            if !now.limitedByPeak { break }
            gain += preset.integrated - reached
        }
        return best
    }
}
