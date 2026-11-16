import Foundation

extension Restoration {
    /// The level of what is left when nobody speaks.
    public struct NoiseFloor: Sendable, Equatable {
        /// RMS level of the pauses in dBFS (a full-scale sine is −3.01).
        public var level: Double
        /// How much pause it was measured over, in seconds.
        public var seconds: Double
    }

    /// The noise floor of a recording with pauses in it: 50 ms frames, the quietest ones
    /// (within 4 dB of the level 2 % of the frames are under, three or more in a row), their mean power. Nil when
    /// there is nothing to call a pause: under a second of sound, less than half a second
    /// of quiet frames, or quiet that isn't at least 10 dB under the loud parts (music, a
    /// steady tone, speech without a break). Frames of digital silence don't count: they
    /// are an edit or a gate, not the room, and a file that is silent between its sounds
    /// has no noise floor to report. Checked against noise added at known levels
    /// (docs/RESTORATION.md).
    public static func noiseFloor(_ x: [Float], sampleRate: Double) -> NoiseFloor? {
        let frame = max(1, Int(sampleRate * 0.05))
        // In time order; nil marks a frame of digital silence (−120 dBFS and under).
        var powers: [Double?] = []
        powers.reserveCapacity(x.count / frame)
        var i = 0
        while i + frame <= x.count {
            var e = 0.0
            for k in i..<(i + frame) { e += Double(x[k]) * Double(x[k]) }
            e /= Double(frame)
            powers.append(e > 1e-12 ? e : nil)
            i += frame
        }
        let sorted = powers.compactMap { $0 }.sorted()
        guard sorted.count >= 20 else { return nil }
        let low = sorted[sorted.count / 50], high = sorted[sorted.count * 95 / 100]
        guard 10 * log10(high / low) >= 10 else { return nil }
        let limit = low * pow(10, 0.4)
        // A pause is quiet for 150 ms or more; a dip between two syllables still has voice in it.
        var quiet: [Double] = [], run: [Double] = []
        for p in powers + [nil] {
            if let p, p <= limit { run.append(p); continue }
            if run.count >= 3 { quiet += run }
            run = []
        }
        guard quiet.count >= 10 else { return nil }
        return NoiseFloor(level: 10 * log10(quiet.reduce(0, +) / Double(quiet.count)), seconds: Double(quiet.count) * 0.05)
    }
}
