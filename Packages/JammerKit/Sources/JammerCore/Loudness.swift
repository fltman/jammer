import Accelerate
import Foundation

/// Loudness per ITU-R BS.1770-5 and EBU R 128 (Tech 3341 meters, Tech 3342 loudness range).
public struct LoudnessResult: Codable, Sendable, Equatable {
    /// Gated integrated loudness, LUFS. nil when everything is below the −70 LUFS gate.
    public var integrated: Double?
    /// Loudness range, LU.
    public var range: Double?
    public var maxMomentary: Double?
    public var maxShortTerm: Double?
    /// Highest absolute sample, dBFS.
    public var samplePeak: Double
    /// Highest inter-sample peak (oversampled), dBTP.
    public var truePeak: Double
    public var duration: Double
    /// Plain RMS level of all samples of all channels together, unweighted, dB relative to full scale
    /// (a full-scale sine reads −3.01). nil for silence, and in results from before 2026-11-16.
    public var rms: Double?

    public init(integrated: Double?, range: Double?, maxMomentary: Double?, maxShortTerm: Double?,
                samplePeak: Double, truePeak: Double, duration: Double, rms: Double? = nil) {
        self.rms = rms
        self.integrated = integrated
        self.range = range
        self.maxMomentary = maxMomentary
        self.maxShortTerm = maxShortTerm
        self.samplePeak = samplePeak
        self.truePeak = truePeak
        self.duration = duration
    }

    public var json: [String: Any] {
        func r(_ v: Double?) -> Any { v.map { $0.isFinite ? ($0 * 100).rounded() / 100 : -999 } ?? NSNull() }
        return ["integratedLUFS": r(integrated), "rangeLU": r(range), "maxMomentaryLUFS": r(maxMomentary),
                "maxShortTermLUFS": r(maxShortTerm), "samplePeakDBFS": r(samplePeak), "truePeakDBTP": r(truePeak), "rmsDB": r(rms),
                "duration": (duration * 1000).rounded() / 1000]
    }
}

/// Feed interleaved blocks, then read `result`.
public struct LoudnessMeter {
    public let sampleRate: Double
    public let channels: Int

    private let weights: [Double]
    private let setup: vDSP_biquad_SetupD
    private var delays: [[Double]]
    private let subBlock: Int
    private var subFill = 0
    private var subSums: [Double]
    /// Weighted mean-square energy of every complete 100 ms sub-block.
    private var subEnergies: [Double] = []
    private var frames: Int64 = 0
    private var samplePeak: Float = 0
    private var squares = 0.0
    private var samples = 0
    private var truePeak = TruePeak(channels: 1, sampleRate: 48_000)
    private var scratchF: [Float] = []
    private var scratchD: [Double] = []
    private var filtered: [Double] = []

    public init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = max(1, channels)
        weights = Self.channelWeights(self.channels)
        setup = vDSP_biquad_CreateSetupD(Self.kWeighting(sampleRate), 2)!
        delays = Array(repeating: [Double](repeating: 0, count: 2 * 2 + 2), count: self.channels)
        subBlock = Int((sampleRate * 0.1).rounded())
        subSums = [Double](repeating: 0, count: self.channels)
        truePeak = TruePeak(channels: self.channels, sampleRate: sampleRate)
    }

    /// BS.1770-5 channel weights by each loudspeaker's position (Annex 3, Tables 4 and 5): 1.41 for the
    /// surrounds between 60° and 120° in the ear layer (5.1's surrounds at ±110°, 7.1's sides at ±90°), 1.00
    /// for everything else (the fronts, 7.1's rears at ±135°, every height), and the LFE not measured. Until
    /// 2026-11-17 7.1's rears had 1.41, as ffmpeg's ebur128 still gives them, and 7.1.4's LFE was counted.
    static func channelWeights(_ n: Int) -> [Double] {
        guard let layout = ChannelLayout.standard(channels: n), n > 2 else { return [Double](repeating: 1, count: n) }
        return layout.speakers.map(\.loudnessWeight)
    }

    /// The two K-weighting stages (high shelf, then high-pass) for any sample rate,
    /// from the analog prototype that gives the BS.1770 48 kHz coefficients.
    /// Packed for vDSP: b0 b1 b2 a1 a2 per section.
    static func kWeighting(_ fs: Double) -> [Double] {
        var f0 = 1681.974450955533
        let gain = 3.999843853973347
        var q = 0.7071752369554196
        var k = tan(.pi * f0 / fs)
        let vh = pow(10, gain / 20)
        let vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelf = [(vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0,
                     2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0]
        f0 = 38.13547087602444
        q = 0.5003270373238773
        k = tan(.pi * f0 / fs)
        a0 = 1 + k / q + k * k
        let highPass = [1, -2, 1, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0]
        return shelf + highPass
    }

    public mutating func process(_ interleaved: UnsafeBufferPointer<Float>) {
        let n = interleaved.count / channels
        guard n > 0, let base = interleaved.baseAddress else { return }
        if scratchF.count < n {
            scratchF = [Float](repeating: 0, count: n)
            scratchD = [Double](repeating: 0, count: n)
            filtered = [Double](repeating: 0, count: n)
        }
        var peak: Float = 0
        vDSP_maxmgv(base, 1, &peak, vDSP_Length(interleaved.count))
        samplePeak = max(samplePeak, peak)
        var energy: Float = 0
        vDSP_svesq(base, 1, &energy, vDSP_Length(n * channels))
        squares += Double(energy)
        samples += n * channels
        truePeak.process(interleaved)

        // K-weight each channel over the whole block, then sum squares per sub-block.
        var perChannel: [[Double]] = []
        perChannel.reserveCapacity(channels)
        for ch in 0..<channels {
            scratchF.withUnsafeMutableBufferPointer { f in deinterleave(base + ch, channels, n, f.baseAddress!) }
            vDSP_vspdp(scratchF, 1, &scratchD, 1, vDSP_Length(n))
            vDSP_biquadD(setup, &delays[ch], scratchD, 1, &filtered, 1, vDSP_Length(n))
            perChannel.append(Array(filtered[0..<n]))
        }
        var i = 0
        while i < n {
            let take = min(subBlock - subFill, n - i)
            for ch in 0..<channels where weights[ch] > 0 {
                var s = 0.0
                perChannel[ch].withUnsafeBufferPointer { p in vDSP_svesqD(p.baseAddress! + i, 1, &s, vDSP_Length(take)) }
                subSums[ch] += s
            }
            subFill += take
            i += take
            if subFill == subBlock {
                var e = 0.0
                for ch in 0..<channels { e += weights[ch] * subSums[ch] / Double(subBlock) }
                subEnergies.append(e)
                subSums = [Double](repeating: 0, count: channels)
                subFill = 0
            }
        }
        frames += Int64(n)
    }

    public mutating func process(_ interleaved: [Float]) {
        interleaved.withUnsafeBufferPointer { process($0) }
    }

    static func lufs(_ energy: Double) -> Double { -0.691 + 10 * log10(energy) }

    /// Mean energy of each window of `size` sub-blocks, sliding one sub-block at a time.
    private func windows(_ size: Int) -> [Double] {
        guard subEnergies.count >= size else { return [] }
        var out: [Double] = []
        out.reserveCapacity(subEnergies.count - size + 1)
        var sum = subEnergies[0..<size].reduce(0, +)
        out.append(sum / Double(size))
        for j in size..<subEnergies.count {
            sum += subEnergies[j] - subEnergies[j - size]
            out.append(max(0, sum) / Double(size))
        }
        return out
    }

    /// K-weighted, channel-weighted mean-square energy of every complete 100 ms block so
    /// far; LUFS = −0.691 + 10·log10(e).
    public var blockEnergies: [Double] { subEnergies }

    public var result: LoudnessResult {
        let momentary = windows(4)
        let shortTerm = windows(30)
        let absGate = pow(10, (-70 + 0.691) / 10)

        var integrated: Double?
        let aboveAbs = momentary.filter { $0 > absGate }
        if !aboveAbs.isEmpty {
            let relGate = aboveAbs.reduce(0, +) / Double(aboveAbs.count) * pow(10, -10.0 / 10)
            let gated = aboveAbs.filter { $0 > relGate }
            if !gated.isEmpty { integrated = Self.lufs(gated.reduce(0, +) / Double(gated.count)) }
        }

        var range: Double?
        let stAbove = shortTerm.filter { $0 > absGate }
        if !stAbove.isEmpty {
            let relGate = stAbove.reduce(0, +) / Double(stAbove.count) * pow(10, -20.0 / 10)
            let levels = stAbove.filter { $0 >= relGate }.map(Self.lufs).sorted()
            if !levels.isEmpty {
                func percentile(_ p: Double) -> Double { levels[Int((Double(levels.count - 1) * p).rounded())] }
                range = percentile(0.95) - percentile(0.10)
            }
        }
        return LoudnessResult(integrated: integrated, range: range,
                              maxMomentary: momentary.max().map(Self.lufs), maxShortTerm: shortTerm.max().map(Self.lufs),
                              samplePeak: 20 * log10(Double(samplePeak)), truePeak: 20 * log10(Double(max(samplePeak, truePeak.peak))),
                              duration: Double(frames) / sampleRate,
                              rms: samples > 0 && squares > 0 ? 10 * log10(squares / Double(samples)) : nil)
    }
}

/// Inter-sample peak by polyphase oversampling (BS.1770 Annex 2): 4× below 96 kHz,
/// 2× below 192 kHz, none above. Kaiser-windowed sinc phases of 32 taps each.
struct TruePeak {
    static let tapsPerPhase = 32
    let factor: Int
    let channels: Int
    /// Reversed coefficients per phase, so vDSP_conv convolves.
    let phases: [[Float]]
    private var history: [[Float]]
    private(set) var peak: Float = 0
    private var work: [Float] = []
    private var out: [Float] = []

    init(channels: Int, sampleRate: Double) {
        self.channels = channels
        let factor = sampleRate < 96_000 ? 4 : (sampleRate < 192_000 ? 2 : 1)
        self.factor = factor
        let taps = Self.tapsPerPhase
        let total = factor * taps
        let center = Double(total - 1) / 2
        let beta = 8.0
        func bessel0(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0
            for k in 1..<30 {
                term *= (x / (2 * Double(k))) * (x / (2 * Double(k)))
                sum += term
            }
            return sum
        }
        var h = [Double](repeating: 0, count: total)
        for i in 0..<total {
            let t = (Double(i) - center) / Double(factor)
            let sinc = t == 0 ? 1 : sin(.pi * t) / (.pi * t)
            let r = (Double(i) - center) / center
            h[i] = sinc * bessel0(beta * sqrt(max(0, 1 - r * r))) / bessel0(beta)
        }
        var ps: [[Float]] = []
        for p in 0..<factor {
            var c = (0..<taps).map { h[p + $0 * factor] }
            let sum = c.reduce(0, +)
            if sum != 0 { c = c.map { $0 / sum } } // unity gain at DC for every phase
            ps.append(c.reversed().map(Float.init))
        }
        phases = ps
        history = Array(repeating: [Float](repeating: 0, count: taps - 1), count: channels)
    }

    mutating func process(_ interleaved: UnsafeBufferPointer<Float>) {
        let n = interleaved.count / channels
        guard n > 0, let base = interleaved.baseAddress else { return }
        if factor == 1 {
            var m: Float = 0
            vDSP_maxmgv(base, 1, &m, vDSP_Length(interleaved.count))
            peak = max(peak, m)
            return
        }
        let taps = Self.tapsPerPhase
        if work.count < n + taps - 1 { work = [Float](repeating: 0, count: n + taps - 1) }
        if out.count < n { out = [Float](repeating: 0, count: n) }
        for ch in 0..<channels {
            work.replaceSubrange(0..<(taps - 1), with: history[ch])
            work.withUnsafeMutableBufferPointer { w in deinterleave(base + ch, channels, n, w.baseAddress! + taps - 1) }
            for coeffs in phases {
                vDSP_conv(work, 1, coeffs, 1, &out, 1, vDSP_Length(n), vDSP_Length(taps))
                var m: Float = 0
                vDSP_maxmgv(out, 1, &m, vDSP_Length(n))
                peak = max(peak, m)
            }
            history[ch] = Array(work[n..<(n + taps - 1)])
        }
    }
}

extension LoudnessMeter {
    /// Measures a range of a rendered plan.
    public static func measure(_ plan: RenderPlan, _ range: Range<Frame>) -> LoudnessResult {
        var meter = LoudnessMeter(sampleRate: plan.sampleRate, channels: plan.channels)
        plan.render(range) { meter.process($0) }
        return meter.result
    }
}

/// Copies every `stride`-th float (one channel of interleaved audio), exactly.
func deinterleave(_ src: UnsafePointer<Float>, _ stride: Int, _ count: Int, _ dst: UnsafeMutablePointer<Float>) {
    var one: Float = 1
    vDSP_vsmul(src, vDSP_Stride(stride), &one, dst, 1, vDSP_Length(count))
}
