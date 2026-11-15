import Accelerate
import Foundation

/// MERL's MRX ("The Cocktail Fork Problem", ICASSP 2022; MIT, checkpoints included):
/// music, speech and effects from a soundtrack. Three STFT resolutions feed encoders, three
/// parallel bidirectional LSTM stacks, and one mask decoder per source and resolution.
/// After MERL's mrx.py, on the CPU with Accelerate so the output is the same on every Mac.
public final class MRXNet: @unchecked Sendable {
    public static let sources = ["music", "speech", "effects"]
    public static let sampleRate = 44_100.0
    static let windows = [1_024, 2_048, 8_192], hop = 256, hidden = 512

    struct Linear { var wT: [Float]; var inputs: Int; var outputs: Int }   // transposed: inputs × outputs
    struct Norm { var scale: [Float]; var shift: [Float] }                 // eval-mode batch norm folded
    struct LSTMDir { var ihT: [Float]; var hhT: [Float]; var bias: [Float]; var inputs: Int }

    let encoders: [(Norm, Linear, Norm)]
    let lstms: [[(LSTMDir, LSTMDir)]]                 // branch → layer → (forward, reverse)
    let decoders: [[(Linear, Norm, Linear, Norm)]]    // source → resolution
    let ffts: [FFT]

    public init(checkpoint ck: TorchCheckpoint) throws {
        func linear(_ name: String) throws -> Linear {
            let (shape, w) = try ck.floats(name)
            var t = [Float](repeating: 0, count: w.count)
            vDSP_mtrans(w, 1, &t, 1, vDSP_Length(shape[1]), vDSP_Length(shape[0]))
            return Linear(wT: t, inputs: shape[1], outputs: shape[0])
        }
        func norm(_ p: String) throws -> Norm {
            let w = try ck.floats(p + ".weight").values, b = try ck.floats(p + ".bias").values
            let m = try ck.floats(p + ".running_mean").values, v = try ck.floats(p + ".running_var").values
            let scale = zip(w, v).map { $0 / ($1 + 1e-5).squareRoot() }
            return Norm(scale: scale, shift: zip(zip(b, m), scale).map { $0.0 - $0.1 * $1 })
        }
        func dir(_ p: String, _ suffix: String) throws -> LSTMDir {
            let ih = try linear(p + "weight_ih_" + suffix), hh = try linear(p + "weight_hh_" + suffix)
            let b = zip(try ck.floats(p + "bias_ih_" + suffix).values, try ck.floats(p + "bias_hh_" + suffix).values).map(+)
            return LSTMDir(ihT: ih.wT, hhT: hh.wT, bias: b, inputs: ih.inputs)
        }
        encoders = try (0..<3).map { r in (try norm("_encoders.\(r).layer.0"), try linear("_encoders.\(r).layer.1.weight"), try norm("_encoders.\(r).layer.2")) }
        lstms = try (0..<3).map { b in try (0..<3).map { l in (try dir("_cross_net.lstm.\(b).", "l\(l)"), try dir("_cross_net.lstm.\(b).", "l\(l)_reverse")) } }
        decoders = try (0..<3).map { s in try (0..<3).map { r in
            let p = "_decoders.\(s).\(r).block."
            return (try linear(p + "0.weight"), try norm(p + "1"), try linear(p + "3.weight"), try norm(p + "4"))
        } }
        ffts = Self.windows.map(FFT.init)
    }

    /// A real FFT of one size with torch.stft's conventions (periodic Hann, normalized).
    final class FFT {
        let n: Int, log2n: vDSP_Length, setup: FFTSetup, window: [Float]
        init(_ n: Int) {
            self.n = n
            log2n = vDSP_Length(log2(Double(n)))
            setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
            var w = [Float](repeating: 0, count: n)
            vDSP_hann_window(&w, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
            window = w
        }
        deinit { vDSP_destroy_fftsetup(setup) }
        var bins: Int { n / 2 + 1 }

        /// Windowed frame → bins 0…n/2 (re, im), scaled by 1/√n.
        func forward(_ frame: [Float], re: inout [Float], im: inout [Float], at: Int) {
            var x = [Float](repeating: 0, count: n)
            vDSP_vmul(frame, 1, window, 1, &x, 1, vDSP_Length(n))
            var r = [Float](repeating: 0, count: n / 2), i = [Float](repeating: 0, count: n / 2)
            r.withUnsafeMutableBufferPointer { rp in i.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                x.withUnsafeBytes { vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(n / 2)) }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            } }
            let s = 0.5 / Float(n).squareRoot()
            re[at] = r[0] * s; im[at] = 0
            for k in 1..<(n / 2) { re[at + k] = r[k] * s; im[at + k] = i[k] * s }
            re[at + n / 2] = i[0] * s; im[at + n / 2] = 0
        }

        /// Bins → windowed time frame (the inverse of `forward`, times the window again for overlap-add).
        func inverse(re: [Float], im: [Float], at: Int) -> [Float] {
            var r = [Float](repeating: 0, count: n / 2), i = [Float](repeating: 0, count: n / 2)
            r[0] = re[at]; i[0] = re[at + n / 2]
            for k in 1..<(n / 2) { r[k] = re[at + k]; i[k] = im[at + k] }
            var out = [Float](repeating: 0, count: n)
            r.withUnsafeMutableBufferPointer { rp in i.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                out.withUnsafeMutableBytes { vDSP_ztoc(&split, 1, $0.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(n / 2)) }
            } }
            var s = 1 / Float(n).squareRoot()   // undo 1/√n and vDSP's factor of n… (2·n/2 from zrip, ×√n)
            vDSP_vsmul(out, 1, &s, &out, 1, vDSP_Length(n))
            vDSP_vmul(out, 1, window, 1, &out, 1, vDSP_Length(n))
            return out
        }
    }

    static func apply(_ l: Linear, _ x: [Float], rows: Int) -> [Float] {
        var y = [Float](repeating: 0, count: rows * l.outputs)
        vDSP_mmul(x, 1, l.wT, 1, &y, 1, vDSP_Length(rows), vDSP_Length(l.outputs), vDSP_Length(l.inputs))
        return y
    }

    static func apply(_ nrm: Norm, _ x: inout [Float], rows: Int) {
        let c = nrm.scale.count
        x.withUnsafeMutableBufferPointer { p in
            for r in 0..<rows {
                vDSP_vma(p.baseAddress! + r * c, 1, nrm.scale, 1, nrm.shift, 1, p.baseAddress! + r * c, 1, vDSP_Length(c))
            }
        }
    }

    /// One direction of an LSTM layer over `T` steps: x is T × inputs, returns T × 256.
    static func run(_ d: LSTMDir, _ x: [Float], steps T: Int, reverse: Bool) -> [Float] {
        let H = 256
        var gates = [Float](repeating: 0, count: T * 4 * H)
        vDSP_mmul(x, 1, d.ihT, 1, &gates, 1, vDSP_Length(T), vDSP_Length(4 * H), vDSP_Length(d.inputs))
        var out = [Float](repeating: 0, count: T * H)
        var h = [Float](repeating: 0, count: H), c = [Float](repeating: 0, count: H)
        var rec = [Float](repeating: 0, count: 4 * H), g = [Float](repeating: 0, count: 4 * H)
        var n = Int32(H)
        for step in 0..<T {
            let t = reverse ? T - 1 - step : step
            vDSP_mmul(h, 1, d.hhT, 1, &rec, 1, 1, vDSP_Length(4 * H), vDSP_Length(H))
            for k in 0..<(4 * H) { g[k] = gates[t * 4 * H + k] + rec[k] + d.bias[k] }
            // i, f, g, o
            for k in 0..<H {
                let i = 1 / (1 + exp(-g[k])), f = 1 / (1 + exp(-g[H + k])), o = 1 / (1 + exp(-g[3 * H + k]))
                c[k] = f * c[k] + i * tanh(g[2 * H + k])
                h[k] = o * tanh(c[k])
            }
            _ = n
            out.replaceSubrange((t * H)..<((t + 1) * H), with: h)
        }
        n = 0
        return out
    }

    /// The raw model: `x` is one channel's samples; returns one waveform per source.
    public func separate(channel x: [Float]) -> [[Float]] {
        let n = x.count, T = 1 + n / Self.hop, H = Self.hidden
        // STFT at each resolution (centred, reflect-padded).
        var specs: [(re: [Float], im: [Float])] = []
        var cross1 = [Float](repeating: 0, count: T * H)
        for (r, fft) in ffts.enumerated() {
            let B = fft.bins, pad = fft.n / 2
            var re = [Float](repeating: 0, count: T * B), im = re
            var frame = [Float](repeating: 0, count: fft.n)
            for t in 0..<T {
                for i in 0..<fft.n {
                    var s = t * Self.hop + i - pad
                    if s < 0 { s = -s }
                    if s >= n { s = 2 * (n - 1) - s }
                    frame[i] = s >= 0 && s < n ? x[s] : 0
                }
                fft.forward(frame, re: &re, im: &im, at: t * B)
            }
            var mag = [Float](repeating: 0, count: T * B)
            for k in 0..<(T * B) { mag[k] = (re[k] * re[k] + im[k] * im[k]).squareRoot() }
            let (n0, lin, n2) = encoders[r]
            Self.apply(n0, &mag, rows: T)
            var e = Self.apply(lin, mag, rows: T)
            Self.apply(n2, &e, rows: T)
            for k in 0..<(T * H) { cross1[k] += tanh(e[k]) / 3 }
            specs.append((re, im))
        }
        // Three bidirectional LSTM stacks, averaged.
        var cross2 = [Float](repeating: 0, count: T * H)
        for branch in lstms {
            var input = cross1
            for (fwd, bwd) in branch {
                let a = Self.run(fwd, input, steps: T, reverse: false), b = Self.run(bwd, input, steps: T, reverse: true)
                var next = [Float](repeating: 0, count: T * H)
                for t in 0..<T {
                    next.replaceSubrange((t * H)..<(t * H + 256), with: a[(t * 256)..<((t + 1) * 256)])
                    next.replaceSubrange((t * H + 256)..<((t + 1) * H), with: b[(t * 256)..<((t + 1) * 256)])
                }
                input = next
            }
            for k in 0..<(T * H) { cross2[k] += input[k] / 3 }
        }
        var features = [Float](repeating: 0, count: T * 2 * H)
        for t in 0..<T {
            features.replaceSubrange((t * 2 * H)..<(t * 2 * H + H), with: cross1[(t * H)..<((t + 1) * H)])
            features.replaceSubrange((t * 2 * H + H)..<((t + 1) * 2 * H), with: cross2[(t * H)..<((t + 1) * H)])
        }
        // Masks per source and resolution, applied to the mix's spectra; inverse STFTs summed.
        return decoders.map { perResolution in
            var out = [Float](repeating: 0, count: n)
            for (r, (l0, n1, l3, n4)) in perResolution.enumerated() {
                let fft = ffts[r], B = fft.bins, pad = fft.n / 2
                var hdn = Self.apply(l0, features, rows: T)
                Self.apply(n1, &hdn, rows: T)
                vDSP_vthr(hdn, 1, [0], &hdn, 1, vDSP_Length(hdn.count))
                var mask = Self.apply(l3, hdn, rows: T)
                Self.apply(n4, &mask, rows: T)
                vDSP_vthr(mask, 1, [0], &mask, 1, vDSP_Length(mask.count))
                var re = [Float](repeating: 0, count: T * B), im = re
                vDSP_vmul(specs[r].re, 1, mask, 1, &re, 1, vDSP_Length(T * B))
                vDSP_vmul(specs[r].im, 1, mask, 1, &im, 1, vDSP_Length(T * B))
                var acc = [Float](repeating: 0, count: n + fft.n), env = acc
                for t in 0..<T {
                    let y = fft.inverse(re: re, im: im, at: t * B)
                    let base = t * Self.hop
                    for i in 0..<fft.n where base + i < acc.count { acc[base + i] += y[i]; env[base + i] += fft.window[i] * fft.window[i] }
                }
                for i in 0..<n where env[i + pad] > 1e-11 { out[i] += acc[i + pad] / env[i + pad] }
            }
            return out
        }
    }
}
