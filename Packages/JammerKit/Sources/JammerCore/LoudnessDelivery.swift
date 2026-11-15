import Foundation

/// Delivering a lossy file at a loudness target. An encoder changes the loudness a little
/// (LAME at 160 kbit/s took 0.4 LU off one test file) and can push peaks up, so the file
/// is encoded, decoded and measured, the gain before the encoder is corrected, and it is
/// encoded again: at most two corrections, never past the true-peak ceiling.
public struct LoudnessDelivery: Sendable, Equatable {
    public struct Target: Sendable, Equatable {
        public var integrated: Double
        /// dBTP the delivered file may not pass.
        public var ceiling: Double
        public init(integrated: Double, ceiling: Double = -1) {
            self.integrated = integrated
            self.ceiling = ceiling
        }
    }

    /// Integrated loudness of the file as written, LUFS. Nil when it couldn't be read back
    /// or is silent; the caller then reports the mix and says so.
    public var loudness: Double?
    public var truePeak: Double?
    /// Gain put in before the encoder, dB (0 when the first encode was on target).
    public var compensatedDB: Double
    /// How many times the file was encoded.
    public var encodes: Int
    /// The ceiling stopped the gain short of the target.
    public var limitedByPeak: Bool

    public static let tolerance = 0.05

    public init(loudness: Double?, truePeak: Double?, compensatedDB: Double = 0, encodes: Int = 1, limitedByPeak: Bool = false) {
        self.loudness = loudness
        self.truePeak = truePeak
        self.compensatedDB = compensatedDB
        self.encodes = encodes
        self.limitedByPeak = limitedByPeak
    }

    /// `encode(gainDB)` writes the file with that much gain before the encoder; `measure()`
    /// reads it back. Ends as soon as the file is within 0.05 LU of the target (or as near as
    /// the ceiling allows).
    public static func deliver(_ target: Target, corrections: Int = 2, encode: (Double) throws -> Void,
                               measure: () -> LoudnessResult?) rethrows -> LoudnessDelivery {
        var gain = 0.0
        var d = LoudnessDelivery(loudness: nil, truePeak: nil, compensatedDB: 0, encodes: 0)
        while true {
            try encode(gain)
            d.encodes += 1
            d.compensatedDB = (gain * 100).rounded() / 100
            guard let m = measure(), let integrated = m.integrated, m.truePeak.isFinite else {
                d.loudness = nil
                d.truePeak = nil
                return d
            }
            d.loudness = integrated
            d.truePeak = m.truePeak
            let toTarget = target.integrated - integrated, toCeiling = target.ceiling - m.truePeak
            d.limitedByPeak = toCeiling < toTarget - tolerance
            let step = min(toTarget, toCeiling)
            if abs(step) < tolerance || d.encodes > corrections { return d }
            gain += step
        }
    }
}

extension EncodedWriter {
    /// What a written file measures when decoded again. Nil when this Mac can't decode it.
    public static func measureWritten(_ url: URL, scratch: URL) -> LoudnessResult? {
        let dir = scratch.appending(path: "written-check-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let r = try? AudioImporter.importFile(url, mediaFolder: dir) else { return nil }
        let p = Project(source: r.source)
        return LoudnessMeter.measure(PlanCompiler.compile(p, pool: SourcePool()), 0..<p.length)
    }
}

extension ExportFormat {
    /// Lossy formats: the encoder changes the loudness, so the delivered file is measured and
    /// corrected. (A file that can't be read back is left as encoded and reported as unmeasured.)
    public var loudnessIsCompensated: Bool { !isLossless }
}
