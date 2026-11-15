import Accelerate
import Foundation

/// Restoration v1: de-hum, de-clip and de-click as plain DSP, offline.
///
/// Every processor works on one channel of float samples and returns the same
/// number of samples. `amount` blends: `x + amount × (processed − x)`, so 0 gives
/// back the input bit for bit and 1 the full repair.
public enum Restoration {}

// MARK: - De-hum

extension Restoration {
    public struct HumEstimate: Sendable, Equatable {
        /// Fundamental in Hz (around 50 or 60), refined to 0.002 Hz.
        public var frequency: Double
        /// How far the hum stands above the spectrum around it, in dB.
        public var prominence: Double
    }

    /// Looks for mains hum: power at the fundamental and its first harmonics,
    /// against the power just beside them. nil when there's no clear hum.
    public static func detectHum(_ x: [Float], sampleRate: Double, minProminence: Double = 10) -> HumEstimate? {
        guard x.count > Int(sampleRate / 2) else { return nil }
        // At most 20 s is plenty.
        let n = min(x.count, Int(sampleRate * 20))
        let s = Array(x[0..<n])
        func score(_ f0: Double) -> (on: Double, off: Double) {
            var on = 0.0, off = 0.0
            for k in 1...4 {
                let f = f0 * Double(k)
                guard f < sampleRate / 2 - 20 else { break }
                on += goertzel(s, f, sampleRate)
                off += (goertzel(s, f - 7, sampleRate) + goertzel(s, f + 7, sampleRate)) / 2
            }
            return (on, off)
        }
        var best: HumEstimate?
        for base in [50.0, 60.0] {
            var f = base - 0.5, bestF = base, bestOn = 0.0, bestOff = 1.0
            while f <= base + 0.5 + 1e-9 {
                let (on, off) = score(f)
                if on > bestOn { bestOn = on; bestOff = off; bestF = f }
                f += 0.05
            }
            let prominence = 10 * log10(max(bestOn, 1e-30) / max(bestOff, 1e-30))
            guard prominence >= minProminence, prominence > (best?.prominence ?? -.infinity) else { continue }
            // Fine search: every harmonic multiplies a frequency error, so the notches
            // need the fundamental to a few thousandths of a hertz.
            var fine = bestF, fineOn = bestOn
            var g = bestF - 0.05
            while g <= bestF + 0.05 + 1e-9 {
                let on = score(g).on
                if on > fineOn { fineOn = on; fine = g }
                g += 0.002
            }
            best = HumEstimate(frequency: (fine * 1_000).rounded() / 1_000, prominence: prominence)
        }
        return best
    }

    /// Power of one frequency over the whole signal (Goertzel).
    static func goertzel(_ x: [Float], _ f: Double, _ sampleRate: Double) -> Double {
        let w = 2 * Double.pi * f / sampleRate
        let c = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for v in x {
            let s0 = Double(v) + c * s1 - s2
            s2 = s1
            s1 = s0
        }
        return (s1 * s1 + s2 * s2 - c * s1 * s2) / Double(x.count * x.count)
    }

    /// Notches at `frequency` × 1…`harmonics`, each `bandwidth` Hz wide (−3 dB).
    /// Streaming: keep the value and feed blocks in order.
    public struct Dehum: Sendable {
        public let frequency: Double
        public let harmonics: Int
        private var sections: [Biquad]

        public init(frequency: Double, sampleRate: Double, harmonics: Int = 8, bandwidth: Double = 2) {
            self.frequency = frequency
            var s: [Biquad] = []
            for k in 1...max(1, harmonics) {
                let f = frequency * Double(k)
                guard f < sampleRate / 2 * 0.95 else { break }
                s.append(.notch(f, q: f / bandwidth, sampleRate: sampleRate))
            }
            self.harmonics = s.count
            sections = s
        }

        public mutating func process(_ x: [Float], amount: Float = 1) -> [Float] {
            var y = x.map(Double.init)
            for i in sections.indices { sections[i].run(&y) }
            return blend(x, y.map { Float($0) }, amount)
        }
    }

    /// A direct-form-I biquad in Double.
    struct Biquad: Sendable {
        var b0, b1, b2, a1, a2: Double
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        static func notch(_ f: Double, q: Double, sampleRate: Double) -> Biquad {
            let w = 2 * Double.pi * f / sampleRate
            let alpha = sin(w) / (2 * q)
            let a0 = 1 + alpha
            return Biquad(b0: 1 / a0, b1: -2 * cos(w) / a0, b2: 1 / a0, a1: -2 * cos(w) / a0, a2: (1 - alpha) / a0)
        }

        mutating func run(_ s: inout [Double]) {
            for i in s.indices {
                let x0 = s[i]
                let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = x0; y2 = y1; y1 = y0
                s[i] = y0
            }
        }
    }
}

// MARK: - De-clip

extension Restoration {
    public struct ClipReport: Sendable, Equatable {
        public var runs: Int
        public var samples: Int
        /// The level the clipping was found at (absolute).
        public var level: Float
    }

    /// Finds runs of at least `minRun` samples stuck at the extremes (within
    /// `tolerance` of the largest absolute value). Returns half-open index ranges.
    public static func clippedRuns(_ x: [Float], minRun: Int = 3, tolerance: Float = 0.001, level: Float? = nil) -> (level: Float, runs: [Range<Int>]) {
        var peak: Float = 0
        if let level { peak = level } else { vDSP_maxmgv(x, 1, &peak, vDSP_Length(x.count)) }
        guard peak > 0 else { return (0, []) }
        let threshold = peak * (1 - tolerance)
        var runs: [Range<Int>] = []
        var i = 0
        while i < x.count {
            guard abs(x[i]) >= threshold else { i += 1; continue }
            let sign = x[i] > 0
            var j = i + 1
            while j < x.count, abs(x[j]) >= threshold, (x[j] > 0) == sign { j += 1 }
            if j - i >= minRun { runs.append(i..<j) }
            i = j
        }
        return (peak, runs)
    }

    /// Rebuilds clipped runs by least-squares AR interpolation, keeping each
    /// rebuilt sample at least at the clip level and on the clipped side.
    /// Runs longer than `maxRun` are left alone (not clipping, or beyond repair).
    public static func declip(_ x: [Float], amount: Float = 1, order: Int = 24, maxRun: Int = 400, level knownLevel: Float? = nil) -> (output: [Float], report: ClipReport) {
        let (level, runs) = clippedRuns(x, level: knownLevel)
        let usable = runs.filter { $0.count <= maxRun }
        guard !usable.isEmpty else { return (x, ClipReport(runs: 0, samples: 0, level: level)) }
        var y = x
        for r in usable {
            let ctx = max(order * 4, r.count * 3)
            let lo = max(0, r.lowerBound - ctx), hi = min(x.count, r.upperBound + ctx)
            var segment = Array(y[lo..<hi])
            let missing = Array((r.lowerBound - lo)..<(r.upperBound - lo))
            // Other clipped runs inside the context stay out of the AR fit.
            let known = (0..<segment.count).filter { k in !usable.contains { $0.contains(k + lo) } }
            guard let coeffs = arCoefficients(segment, order: min(order, known.count / 4), exclude: Set((0..<segment.count).filter { !known.contains($0) })) else { continue }
            guard let filled = lsarInterpolate(segment, missing: missing, coeffs: coeffs) else { continue }
            let sign: Float = x[r.lowerBound] > 0 ? 1 : -1
            for (k, idx) in missing.enumerated() {
                // On the clipped side and at least at the clip level: the true wave went beyond it.
                let v = filled[k] * sign
                segment[idx] = sign * max(level, v)
            }
            for idx in missing { y[idx + lo] = segment[idx] }
        }
        return (blend(x, y, amount), ClipReport(runs: usable.count, samples: usable.reduce(0) { $0 + $1.count }, level: level))
    }
}

// MARK: - De-click

extension Restoration {
    public struct ClickReport: Sendable, Equatable {
        public var clicks: [Range<Int>]
    }

    /// Finds short impulses: where the AR prediction error jumps far above its
    /// usual size (median absolute deviation), in blocks of `block` samples.
    public static func detectClicks(_ x: [Float], sensitivity: Double = 1, order: Int = 20, block: Int = 4_096,
                                    maxLength: Int = 96) -> [Range<Int>] {
        guard x.count > order * 4 else { return [] }
        var flagged: [Int] = []
        var start = 0
        while start < x.count {
            let end = min(x.count, start + block)
            let lo = max(0, start - order)
            let seg = Array(x[lo..<end])
            if seg.count > order * 4, let a = arCoefficients(seg, order: order, exclude: []) {
                var e = [Double](repeating: 0, count: seg.count)
                for n in order..<seg.count {
                    var p = 0.0
                    for k in 0..<order { p += a[k] * Double(seg[n - 1 - k]) }
                    e[n] = Double(seg[n]) - p
                }
                let body = Array(e[order...]).map(abs).sorted()
                let mad = max(body[body.count / 2], 1e-7)
                let threshold = mad * 12 / sensitivity
                for n in max(order, start - lo)..<seg.count where abs(e[n]) > threshold { flagged.append(n + lo) }
            }
            start = end
        }
        // Group flagged samples into short regions with a little margin.
        var regions: [Range<Int>] = []
        for i in flagged.sorted() {
            let r = max(0, i - 2)..<min(x.count, i + 3)
            if let last = regions.last, r.lowerBound <= last.upperBound + 4 {
                regions[regions.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                regions.append(r)
            }
        }
        return regions.filter { $0.count <= maxLength }
    }

    /// Removes clicks: detect, then rebuild each region by LSAR interpolation.
    public static func declick(_ x: [Float], amount: Float = 1, sensitivity: Double = 1, order: Int = 20) -> (output: [Float], report: ClickReport) {
        let clicks = detectClicks(x, sensitivity: sensitivity, order: order)
        guard !clicks.isEmpty else { return (x, ClickReport(clicks: [])) }
        var y = x
        for r in clicks {
            let ctx = max(order * 6, r.count * 4)
            let lo = max(0, r.lowerBound - ctx), hi = min(x.count, r.upperBound + ctx)
            let segment = Array(y[lo..<hi])
            let missing = Array((r.lowerBound - lo)..<(r.upperBound - lo))
            let exclude = Set(clicks.flatMap { c in c.compactMap { $0 >= lo && $0 < hi ? $0 - lo : nil } })
            guard let a = arCoefficients(segment, order: order, exclude: exclude),
                  let filled = lsarInterpolate(segment, missing: missing, coeffs: a) else { continue }
            for (k, idx) in missing.enumerated() { y[idx + lo] = filled[k] }
        }
        return (blend(x, y, amount), ClickReport(clicks: clicks))
    }
}

// MARK: - Shared

extension Restoration {
    static func blend(_ x: [Float], _ y: [Float], _ amount: Float) -> [Float] {
        if amount == 0 { return x }
        if amount == 1 { return y }
        return zip(x, y).map { $0 + amount * ($1 - $0) }
    }

    /// AR coefficients a[0..<order] (x[n] ≈ Σ a[k]·x[n-1-k]) by least squares
    /// (covariance method), skipping predictions that touch `exclude`.
    static func arCoefficients(_ x: [Float], order: Int, exclude: Set<Int>) -> [Double]? {
        guard order > 0, x.count > order * 2 else { return nil }
        var r = [Double](repeating: 0, count: order * order)
        var b = [Double](repeating: 0, count: order)
        var rows = 0
        for n in order..<x.count {
            if !exclude.isEmpty, exclude.contains(n) || (1...order).contains(where: { exclude.contains(n - $0) }) { continue }
            rows += 1
            for i in 0..<order {
                let xi = Double(x[n - 1 - i])
                b[i] += xi * Double(x[n])
                for j in i..<order { r[i * order + j] += xi * Double(x[n - 1 - j]) }
            }
        }
        guard rows > order else { return nil }
        for i in 0..<order { for j in 0..<i { r[i * order + j] = r[j * order + i] } }
        // A touch of regularisation keeps silence and pure tones solvable.
        let trace = (0..<order).reduce(0.0) { $0 + r[$1 * order + $1] }
        for i in 0..<order { r[i * order + i] += trace / Double(order) * 1e-9 + 1e-12 }
        return solve(r, b, order)
    }

    /// Least-squares AR interpolation (Janssen et al.): the missing samples that
    /// minimise the total prediction error, given the AR model and the known samples.
    static func lsarInterpolate(_ x: [Float], missing: [Int], coeffs a: [Double]) -> [Float]? {
        let p = a.count
        let m = missing.count
        guard m > 0 else { return [] }
        // Prediction-error filter c = [1, -a1, …, -ap]; e[n] = Σ c[k] x[n-k].
        let c = [1.0] + a.map { -$0 }
        let index = Dictionary(uniqueKeysWithValues: missing.enumerated().map { ($1, $0) })
        let first = max(p, missing.first! ), last = min(x.count - 1, missing.last! + p)
        var ata = [Double](repeating: 0, count: m * m)
        var atb = [Double](repeating: 0, count: m)
        for n in first...last where n >= p {
            // e[n] = Σ_{missing j} c[n-j] x_j + Σ_{known} c[n-k] x_k
            var cols: [(Int, Double)] = []
            var known = 0.0
            for k in 0...p {
                let t = n - k
                guard t >= 0, t < x.count else { continue }
                if let j = index[t] { cols.append((j, c[k])) } else { known += c[k] * Double(x[t]) }
            }
            guard !cols.isEmpty else { continue }
            for (j1, v1) in cols {
                atb[j1] -= v1 * known
                for (j2, v2) in cols { ata[j1 * m + j2] += v1 * v2 }
            }
        }
        for i in 0..<m { ata[i * m + i] += 1e-12 }
        return solve(ata, atb, m)?.map { Float($0) }
    }

    /// Solves A·x = b (A n×n, row-major, symmetric positive definite) by Cholesky.
    static func solve(_ a: [Double], _ b: [Double], _ n: Int) -> [Double]? {
        var l = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0...i {
                var s = a[i * n + j]
                for k in 0..<j { s -= l[i * n + k] * l[j * n + k] }
                if i == j {
                    guard s > 0 else { return nil }
                    l[i * n + i] = s.squareRoot()
                } else {
                    l[i * n + j] = s / l[j * n + j]
                }
            }
        }
        var y = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var s = b[i]
            for k in 0..<i { s -= l[i * n + k] * y[k] }
            y[i] = s / l[i * n + i]
        }
        var x = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var s = y[i]
            for k in (i + 1)..<n { s -= l[k * n + i] * x[k] }
            x[i] = s / l[i * n + i]
        }
        return x.allSatisfy(\.isFinite) ? x : nil
    }
}
