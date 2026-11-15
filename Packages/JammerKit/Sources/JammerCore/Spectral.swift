import Accelerate
import Foundation

/// Spectrogram columns for drawing, and spectral attenuation of a time–frequency box.
public enum Spectral {
    /// A short-time Fourier transform with a Hann window.
    final class STFT {
        let size: Int
        let log2n: vDSP_Length
        let setup: FFTSetup
        let window: [Float]

        init(size: Int) {
            self.size = size
            log2n = vDSP_Length(log2(Double(size)))
            setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
            var w = [Float](repeating: 0, count: size)
            vDSP_hann_window(&w, vDSP_Length(size), Int32(vDSP_HANN_NORM))
            window = w
        }

        deinit { vDSP_destroy_fftsetup(setup) }

        /// Forward transform of `frame` (size samples), windowed: (real, imag), size/2 bins
        /// (bin 0 holds DC in real and Nyquist in imag, vDSP's packing).
        func forward(_ frame: UnsafePointer<Float>) -> ([Float], [Float]) {
            var x = [Float](repeating: 0, count: size)
            vDSP_vmul(frame, 1, window, 1, &x, 1, vDSP_Length(size))
            var re = [Float](repeating: 0, count: size / 2), im = [Float](repeating: 0, count: size / 2)
            re.withUnsafeMutableBufferPointer { r in
                im.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    x.withUnsafeBytes { raw in vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(size / 2)) }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                }
            }
            return (re, im)
        }

        /// Inverse transform back to `size` samples (unscaled; the caller normalises).
        func inverse(_ re: [Float], _ im: [Float]) -> [Float] {
            var r = re, i = im
            var out = [Float](repeating: 0, count: size)
            r.withUnsafeMutableBufferPointer { rp in
                i.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                    out.withUnsafeMutableBytes { raw in vDSP_ztoc(&split, 1, raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(size / 2)) }
                }
            }
            return out
        }
    }

    /// Magnitudes in dBFS, one column per `hop` samples: result[column][bin], bins 0…size/2−1
    /// covering 0 Hz up to just below Nyquist.
    public static func spectrogram(_ x: [Float], size: Int = 2_048, hop: Int = 512) -> [[Float]] {
        guard x.count >= size else { return [] }
        let stft = STFT(size: size)
        var columns: [[Float]] = []
        columns.reserveCapacity((x.count - size) / hop + 1)
        // vDSP's real FFT doubles the DFT, and a sine of amplitude A gives A·Σw/2 in its
        // bin, so the amplitude is |X| / Σw.
        let scale = 2 / stft.window.reduce(0, +)
        x.withUnsafeBufferPointer { p in
            var at = 0
            while at + size <= x.count {
                let (re, im) = stft.forward(p.baseAddress! + at)
                var col = [Float](repeating: -140, count: size / 2)
                col[0] = 20 * log10(max(1e-7, abs(re[0]) * scale / 2))
                for k in 1..<(size / 2) {
                    let m = (re[k] * re[k] + im[k] * im[k]).squareRoot() * scale / 2
                    col[k] = 20 * log10(max(1e-7, m))
                }
                columns.append(col)
                at += hop
            }
        }
        return columns
    }

    /// Lowers `freq` (Hz) by `gainDB` inside `time` (samples) of one channel, through STFT and
    /// overlap-add (Hann, 75 % overlap). Samples outside the box's time span plus a short
    /// crossfade come back bit for bit.
    public static func attenuate(_ x: [Float], sampleRate: Double, time: Range<Int>, freq: ClosedRange<Double>, gainDB: Double,
                                 size: Int = 2_048) -> [Float] {
        let hop = size / 4
        let lo = max(0, time.lowerBound - size), hi = min(x.count, time.upperBound + size)
        guard hi - lo > size else { return x }
        let stft = STFT(size: size)
        let seg = Array(x[lo..<hi]) + [Float](repeating: 0, count: size)
        var acc = [Float](repeating: 0, count: seg.count + size)
        var norm = [Float](repeating: 0, count: seg.count + size)
        let g = Float(pow(10, gainDB / 20))
        let binHz = sampleRate / Double(size)
        let k0 = max(0, Int((freq.lowerBound / binHz).rounded(.down))), k1 = min(size / 2 - 1, Int((freq.upperBound / binHz).rounded(.up)))
        seg.withUnsafeBufferPointer { p in
            var at = -size + hop
            while at < seg.count {
                var frame = [Float](repeating: 0, count: size)
                for i in 0..<size where at + i >= 0 && at + i < seg.count { frame[i] = p[at + i] }
                var (re, im) = frame.withUnsafeBufferPointer { stft.forward($0.baseAddress!) }
                // Only frames centred inside the time box are changed, with a soft edge in time.
                let centre = lo + at + size / 2
                if centre >= time.lowerBound, centre < time.upperBound, k0 <= k1 {
                    for k in k0...k1 {
                        if k == 0 { re[0] *= g } else { re[k] *= g; im[k] *= g }
                    }
                }
                let y = stft.inverse(re, im)
                for i in 0..<size {
                    let idx = at + i + size
                    guard idx >= 0, idx < acc.count else { continue }
                    acc[idx] += y[i] * stft.window[i]
                    norm[idx] += stft.window[i] * stft.window[i]
                }
                at += hop
            }
        }
        // Normalise the overlap-add (vDSP's inverse is scaled by 2·size).
        var out = x
        let fade = hop
        for i in lo..<hi {
            let idx = i - lo + size
            guard norm[idx] > 1e-6 else { continue }
            let processed = acc[idx] / norm[idx] / Float(2 * size)
            // Crossfade back to the exact original at both ends of the span.
            let fromStart = i - (time.lowerBound - size / 2), toEnd = (time.upperBound + size / 2) - i
            let w = Float(max(0, min(1, Double(min(fromStart, toEnd)) / Double(fade))))
            out[i] = x[i] + w * (processed - x[i])
        }
        return out
    }
}
