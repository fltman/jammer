import Foundation

extension Restoration {
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
