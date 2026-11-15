import Foundation

/// De-reverberation by weighted prediction error (WPE; Nakatani et al., 2010): in each
/// frequency band the late reverberation is what can be predicted linearly from the
/// band's own past, a few frames back, and that prediction is subtracted. The direct
/// sound and early reflections (inside the prediction delay) are left alone. No model.
extension Restoration {
    struct WPE {
        var delay = 3          // frames skipped before the prediction starts (about 30 ms)
        var taps = 24          // frames predicted from (about 0.25 s)
        var iterations = 3
        var maxHz = 12_000.0   // above this the room rings too briefly to matter; left as is
    }

    /// One channel in, the same length out. `amount` blends from the original (0) to the full result (1).
    public static func dereverb(_ x: [Float], sampleRate: Double, amount: Float = 1) -> [Float] {
        guard amount > 0, x.count > 8_192 else { return x }
        let cfg = WPE()
        let size = sampleRate > 60_000 ? 4_096 : (sampleRate > 30_000 ? 2_048 : 1_024), hop = size / 4
        let stft = Spectral.STFT(size: size)
        let n = x.count
        let padded = [Float](repeating: 0, count: size) + x + [Float](repeating: 0, count: size * 2)
        let T = (padded.count - size) / hop + 1
        let bins = size / 2
        var re = [[Float]](repeating: [], count: T), im = re
        padded.withUnsafeBufferPointer { p in
            for t in 0..<T { (re[t], im[t]) = stft.forward(p.baseAddress! + t * hop) }
        }
        let top = min(bins - 1, Int(cfg.maxHz / (sampleRate / Double(size))))
        let K = cfg.taps, D = cfg.delay
        var yr = [Double](repeating: 0, count: T), yi = yr, dr = yr, di = yr, lambda = yr
        var R = [Double](repeating: 0, count: K * K * 2), p = [Double](repeating: 0, count: K * 2), g = p
        for k in 1...top {
            var mean = 0.0
            for t in 0..<T { yr[t] = Double(re[t][k]); yi[t] = Double(im[t][k]); mean += yr[t] * yr[t] + yi[t] * yi[t] }
            mean /= Double(T)
            guard mean > 1e-18 else { continue }
            // The variance floor keeps quiet frames (noise between words) from dominating the
            // estimate, which is what makes WPE lift a noise floor.
            let floor = mean * 3e-3
            for t in 0..<T { dr[t] = yr[t]; di[t] = yi[t] }
            for _ in 0..<cfg.iterations {
                for t in 0..<T {
                    // Smoothed over neighbouring frames: steadier than a single frame's power.
                    var s = 0.0, c = 0.0
                    for u in max(0, t - 1)...min(T - 1, t + 1) { s += dr[u] * dr[u] + di[u] * di[u]; c += 1 }
                    lambda[t] = max(s / c, floor)
                }
                for i in 0..<(K * K * 2) { R[i] = 0 }
                for i in 0..<(K * 2) { p[i] = 0 }
                // The hot loop, on raw pointers (bounds checks made it several times slower).
                yr.withUnsafeBufferPointer { yr in yi.withUnsafeBufferPointer { yi in
                    R.withUnsafeMutableBufferPointer { R in p.withUnsafeMutableBufferPointer { p in
                        for t in (D + K - 1)..<T {
                            let w = 1 / lambda[t]
                            let cr = yr[t] * w, ci = yi[t] * w
                            for a in 0..<K {
                                let ar = yr[t - D - a], ai = yi[t - D - a]
                                // p[a] += x̃[a]·conj(y[t])
                                p[a * 2] += ar * cr + ai * ci
                                p[a * 2 + 1] += ai * cr - ar * ci
                                let wr = ar * w, wi = ai * w
                                var idx = (a * K + a) * 2
                                for b in a..<K {
                                    let br = yr[t - D - b], bi = yi[t - D - b]
                                    // R[a][b] += x̃[a]·conj(x̃[b])
                                    R[idx] += wr * br + wi * bi
                                    R[idx + 1] += wi * br - wr * bi
                                    idx += 2
                                }
                            }
                        }
                    } }
                } }
                var trace = 0.0
                for a in 0..<K {
                    trace += R[(a * K + a) * 2]
                    for b in 0..<a { R[(a * K + b) * 2] = R[(b * K + a) * 2]; R[(a * K + b) * 2 + 1] = -R[(b * K + a) * 2 + 1] }
                }
                let load = 1e-4 * trace / Double(K) + 1e-20
                for a in 0..<K { R[(a * K + a) * 2] += load }
                guard solve(&R, p, &g, K) else { break }
                // d[t] = y[t] − Σ conj(g[a])·x̃[a]
                for t in 0..<T {
                    var sr = 0.0, si = 0.0
                    if t >= D {
                        for a in 0..<min(K, t - D + 1) {
                            let xr = yr[t - D - a], xi = yi[t - D - a], gr = g[a * 2], gi = -g[a * 2 + 1]
                            sr += gr * xr - gi * xi
                            si += gr * xi + gi * xr
                        }
                    }
                    dr[t] = yr[t] - sr
                    di[t] = yi[t] - si
                }
            }
            for t in 0..<T { re[t][k] = Float(dr[t]); im[t][k] = Float(di[t]) }
        }
        var acc = [Float](repeating: 0, count: padded.count), norm = acc
        for t in 0..<T {
            let y = stft.inverse(re[t], im[t])
            for i in 0..<size { acc[t * hop + i] += y[i] * stft.window[i]; norm[t * hop + i] += stft.window[i] * stft.window[i] }
        }
        var out = x
        for i in 0..<n where norm[i + size] > 1e-6 {
            let wet = acc[i + size] / norm[i + size] / Float(2 * size)
            out[i] = x[i] + amount * (wet - x[i])
        }
        return out
    }

    /// Solves the K×K complex system A·g = b (interleaved re, im) by Gaussian elimination with pivoting.
    static func solve(_ A: inout [Double], _ b: [Double], _ g: inout [Double], _ K: Int) -> Bool {
        var rhs = b
        for c in 0..<K {
            var best = c, bestMag = 0.0
            for r in c..<K {
                let m = A[(r * K + c) * 2] * A[(r * K + c) * 2] + A[(r * K + c) * 2 + 1] * A[(r * K + c) * 2 + 1]
                if m > bestMag { bestMag = m; best = r }
            }
            guard bestMag > 1e-300 else { return false }
            if best != c {
                for j in 0..<(K * 2) { A.swapAt(c * K * 2 + j, best * K * 2 + j) }
                rhs.swapAt(c * 2, best * 2); rhs.swapAt(c * 2 + 1, best * 2 + 1)
            }
            let pr = A[(c * K + c) * 2], pi = A[(c * K + c) * 2 + 1]
            for r in (c + 1)..<K where A[(r * K + c) * 2] != 0 || A[(r * K + c) * 2 + 1] != 0 {
                // factor = A[r][c] / pivot
                let ar = A[(r * K + c) * 2], ai = A[(r * K + c) * 2 + 1]
                let fr = (ar * pr + ai * pi) / bestMag, fi = (ai * pr - ar * pi) / bestMag
                for j in c..<K {
                    let xr = A[(c * K + j) * 2], xi = A[(c * K + j) * 2 + 1]
                    A[(r * K + j) * 2] -= fr * xr - fi * xi
                    A[(r * K + j) * 2 + 1] -= fr * xi + fi * xr
                }
                rhs[r * 2] -= fr * rhs[c * 2] - fi * rhs[c * 2 + 1]
                rhs[r * 2 + 1] -= fr * rhs[c * 2 + 1] + fi * rhs[c * 2]
            }
        }
        for c in stride(from: K - 1, through: 0, by: -1) {
            var sr = rhs[c * 2], si = rhs[c * 2 + 1]
            for j in (c + 1)..<K where j < K {
                let xr = A[(c * K + j) * 2], xi = A[(c * K + j) * 2 + 1]
                sr -= xr * g[j * 2] - xi * g[j * 2 + 1]
                si -= xr * g[j * 2 + 1] + xi * g[j * 2]
            }
            let pr = A[(c * K + c) * 2], pi = A[(c * K + c) * 2 + 1], m = pr * pr + pi * pi
            g[c * 2] = (sr * pr + si * pi) / m
            g[c * 2 + 1] = (si * pr - sr * pi) / m
        }
        return true
    }

    /// A rough reverberation time from how the level falls after sounds stop: the slope of
    /// each free decay, fitted from 8 dB under its start (the first drop is the direct sound
    /// ending, not the room), and of those the middle one. Calibrated on clean voices in rooms
    /// of known length (docs/RESTORATION.md): within about 0.1 s up to 1 s; longer rooms read
    /// short, because speech rarely pauses long enough to show them. Nil when there are too few
    /// decays to tell, which needs pauses and a noise floor some 20 dB under the voice.
    public static func estimateRT60(_ x: [Float], sampleRate: Double) -> Double? {
        estimateRT60(x, sampleRate: sampleRate, window: 0.03, rise: 2, minDrop: 12, above: 12, quantile: 0.5, fitFrom: 8)
    }

    /// The estimator with its knobs, for calibration: `window` seconds per level value (hop 10 ms),
    /// `rise` dB a decay may climb between values, `minDrop` dB a decay must fall, `above` dB over
    /// the floor its start must be, `quantile` of the sorted times that is reported, `fitFrom` dB
    /// under the start where the fitted part begins.
    static func estimateRT60(_ x: [Float], sampleRate: Double, window: Double, rise: Double, minDrop: Double, above: Double,
                             quantile: Double, fitFrom: Double) -> Double? {
        let hop = max(1, Int(sampleRate * 0.01)), win = max(hop, Int(sampleRate * window))
        var env: [Double] = []
        var i = 0
        while i + win <= x.count {
            var e = 0.0
            for k in i..<(i + win) { e += Double(x[k] * x[k]) }
            env.append(10 * log10(e / Double(win) + 1e-12))
            i += hop
        }
        guard env.count > 100 else { return nil }
        let floor = env.sorted()[env.count / 20] + 6
        var times: [Double] = []
        var t = 1
        while t < env.count - 1 {
            // A decay starts at a local peak well above the floor and runs while the level keeps falling.
            guard env[t] > floor + above, env[t] >= env[t - 1], env[t] > env[t + 1] else { t += 1; continue }
            var end = t
            while end + 1 < env.count, env[end + 1] <= env[end] + rise, env[end + 1] > floor { end += 1 }
            let drop = env[t] - env[end]
            if drop >= minDrop, end - t >= 4 {
                // Least-squares slope over the later part.
                let pts = (t...end).filter { env[t] - env[$0] >= fitFrom }
                if pts.count >= 3 {
                    let mx = Double(pts.reduce(0, +)) / Double(pts.count), my = pts.map { env[$0] }.reduce(0, +) / Double(pts.count)
                    var sxy = 0.0, sxx = 0.0
                    for q in pts { sxy += (Double(q) - mx) * (env[q] - my); sxx += (Double(q) - mx) * (Double(q) - mx) }
                    let slope = sxy / sxx / 0.01 // dB per second, negative
                    if slope < -20 { times.append(60 / -slope) }
                }
            }
            t = max(end, t + 1)
        }
        guard times.count >= 3 else { return nil }
        times.sort()
        return times[Int(Double(times.count) * quantile)]
    }

}
