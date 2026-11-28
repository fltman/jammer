import Foundation

/// The spectrogram's frequency scale as the timeline draws it: logarithmic from `low` at the bottom of a lane to
/// `high` at its top. Its ticks, and a frequency in words for the readout under the pointer (the comfort sweep of
/// 2026-11-25, [19]: nothing said what time or frequency was under the pointer, and there was no scale).
public enum SpectrogramScale {
    /// The frequencies a tick may sit at.
    static let candidates: [Double] = [50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000]

    /// Points from the lane's top to `f`, in a lane `height` points high.
    public static func y(of f: Double, low: Double, high: Double, height: Double) -> Double {
        (1 - log(max(low, f) / low) / log(high / low)) * max(0, height - 1)
    }
    /// The frequency `y` points from the lane's top.
    public static func hz(atY y: Double, low: Double, high: Double, height: Double) -> Double {
        let r = min(max(0, y), max(0, height - 1)) / max(1, height - 1)
        return low * pow(high / low, 1 - r)
    }

    /// The ticks that fit in a lane: strictly inside (low, high), at least `spacing` points apart and from both ends,
    /// the lower ones kept first (speech lives there).
    public static func ticks(low: Double, high: Double, height: Double, spacing: Double = 14) -> [Double] {
        var out: [Double] = []
        var lastY = height   // the bottom edge
        for f in candidates where f > low && f < high {
            let y = Self.y(of: f, low: low, high: high, height: height)
            guard lastY - y >= spacing, y >= spacing else { continue }
            out.append(f)
            lastY = y
        }
        return out
    }

    /// A frequency as a tick says it ("100", "1k", "10k") and as the readout does: the number and whether it is kHz.
    public static func tick(_ f: Double) -> String {
        f >= 1_000 ? (f.truncatingRemainder(dividingBy: 1_000) == 0 ? "\(Int(f / 1_000))k" : String(format: "%.1fk", f / 1_000)) : "\(Int(f))"
    }
    public static func readout(_ f: Double) -> (value: Double, decimals: Int, kilo: Bool) {
        f >= 1_000 ? (f / 1_000, f >= 10_000 ? 1 : 2, true) : (f.rounded(), 0, false)
    }
}
