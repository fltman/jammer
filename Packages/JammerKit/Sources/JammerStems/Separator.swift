import Foundation
import JammerCore

/// Estimates each stem's magnitude spectrogram from the mix's: `frames` × 1024 bins × 2
/// channels in, one array of that shape per stem out. `SpleeterNet` in the app; tests use fakes.
public protocol StemEstimator {
    var frames: Int { get }
    var stemNames: [String] { get }
    func estimate(_ mix: [Float]) -> [[Float]]
}

extension SpleeterNet: StemEstimator {
    public var stemNames: [String] { Array(Self.stems4.prefix(outputs.count)) }
    public func estimate(_ mix: [Float]) -> [[Float]] { run(mix) }
}

/// Spleeter-style separation (Deezer's configuration: 44.1 kHz, 4096-sample Hann frames,
/// hop 1024, the lowest 1024 bins, ratio masks with exponent 2), streamed block by block so
/// an hour of audio needs no more memory than a minute.
///
/// One deliberate difference from Spleeter: it leaves everything above 11 kHz out of all
/// stems. Here whatever the masks don't cover goes to the last stem ("other"), so the stems
/// always add up to the original.
public enum StemSeparator {
    public static let sampleRate = 44_100.0
    static let size = 4_096, hop = 1_024, bins = 1_024

    /// `audio`: interleaved stereo at 44.1 kHz. `write(stem, samples)` gets consecutive
    /// interleaved stereo blocks per stem; together exactly as long as the input.
    public static func separate(_ audio: [Float], with net: StemEstimator, progress: (Double) -> Bool = { _ in true },
                                write: (Int, [Float]) throws -> Void) throws {
        let n = audio.count / 2
        let stems = net.stemNames.count
        let stft = Spectral.STFT(size: size)
        let tfScale = 1 / (2 * (stft.window.max() ?? 1))   // vDSP doubles the DFT; the window here is scaled
        let first = -size + hop
        let total = (n - first + hop - 1) / hop            // frames until the last one starting inside the audio
        let half = size / 2
        // Overlap-add state per stem and channel, for the samples from `done` on.
        var acc = [[[Float]]](repeating: [[Float]](repeating: [Float](repeating: 0, count: net.frames * hop + size), count: 2), count: stems)
        var norm = [Float](repeating: 0, count: net.frames * hop + size)
        var done = 0 // samples written so far (the buffers start at sample `first + block·hop`)
        var frame = [Float](repeating: 0, count: size)
        var t0 = 0
        while t0 < total {
            let count = min(net.frames, total - t0)
            var re = [[[Float]]](repeating: [], count: 2), im = [[[Float]]](repeating: [], count: 2)
            var mags = [Float](repeating: 0, count: net.frames * bins * 2)
            for c in 0..<2 {
                for t in 0..<count {
                    let at = first + (t0 + t) * hop
                    for i in 0..<size { let s = at + i; frame[i] = s >= 0 && s < n ? audio[s * 2 + c] : 0 }
                    let (r, m) = frame.withUnsafeBufferPointer { stft.forward($0.baseAddress!) }
                    for k in 1..<bins { mags[(t * bins + k) * 2 + c] = (r[k] * r[k] + m[k] * m[k]).squareRoot() * tfScale }
                    mags[(t * bins) * 2 + c] = abs(r[0]) * tfScale
                    re[c].append(r); im[c].append(m)
                }
            }
            let est = net.estimate(mags)
            for c in 0..<2 {
                for t in 0..<count {
                    // Ratio masks over the lowest bins; what's left of the frame goes to the last stem.
                    var rest = (re[c][t], im[c][t])
                    for s in 0..<stems {
                        var r = [Float](repeating: 0, count: half), m = [Float](repeating: 0, count: half)
                        if s < stems - 1 {
                            for k in 1..<bins {
                                var sum: Float = 1e-10
                                for j in 0..<stems { let e = est[j][(t * bins + k) * 2 + c]; sum += e * e }
                                let e = est[s][(t * bins + k) * 2 + c]
                                let mask = (e * e + 1e-10 / Float(stems)) / sum
                                r[k] = re[c][t][k] * mask; m[k] = im[c][t][k] * mask
                                rest.0[k] -= r[k]; rest.1[k] -= m[k]
                            }
                        } else {
                            r = rest.0; m = rest.1
                        }
                        let y = stft.inverse(r, m)
                        let base = t * hop
                        for i in 0..<size { acc[s][c][base + i] += y[i] * stft.window[i] }
                    }
                    if c == 0 { let base = t * hop; for i in 0..<size { norm[base + i] += stft.window[i] * stft.window[i] } }
                }
            }
            // Samples before the next block's first frame are final.
            let bufferStart = first + t0 * hop
            let lastBlock = t0 + count >= total
            let finalUntil = lastBlock ? n : first + (t0 + count) * hop
            let from = max(done, 0), to = max(from, min(n, finalUntil))
            if to > from {
                for s in 0..<stems {
                    var out = [Float](repeating: 0, count: (to - from) * 2)
                    for i in from..<to {
                        let b = i - bufferStart
                        let w = norm[b] > 1e-6 ? 1 / (norm[b] * Float(2 * size)) : 0
                        out[(i - from) * 2] = acc[s][0][b] * w
                        out[(i - from) * 2 + 1] = acc[s][1][b] * w
                    }
                    try write(s, out)
                }
                done = to
            }
            // Slide: keep the overlap tail for the next block.
            let shift = count * hop
            for s in 0..<stems { for c in 0..<2 { acc[s][c].removeFirst(shift); acc[s][c] += [Float](repeating: 0, count: shift) } }
            norm.removeFirst(shift); norm += [Float](repeating: 0, count: shift)
            t0 += count
            if !progress(Double(t0) / Double(total)) { throw CancellationError() }
        }
    }
}
