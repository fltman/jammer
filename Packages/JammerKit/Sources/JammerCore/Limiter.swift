import Accelerate
import Foundation

/// An offline true-peak limiter: one gain for all channels of a frame, found by looking
/// ahead, so the gain is already down when the peak arrives. Where the gain is 1 the
/// samples pass bit for bit; the signal itself never goes through a filter.
///
/// The gain per frame, from the oversampled level around that frame (the meter's own
/// filter, `TruePeak`): required = min(1, ceiling / level) → lowest required value in the
/// lookahead ahead → release (falls at once, rises with the time constant) → mean over
/// the lookahead. Every value averaged for a frame is at most that frame's required
/// gain, so the applied gain never exceeds it.
///
/// A moving gain shifts inter-sample peaks a little, so the promise is kept by measuring:
/// `limit` aims slightly under the ceiling, measures the result as the meter would, and
/// tries again with a larger margin if it is over.
///
/// A file of hours, without holding it in memory, with `Processor` and `PeakMeter`:
///   1. Read the file in blocks through a `PeakMeter`. At or under the ceiling: copy it.
///   2. Otherwise read it again through `Processor(marginDB: 0.05)`, writing what
///      `process` and `finish` return to a temporary file and feeding the same blocks to
///      a second `PeakMeter`.
///   3. If that meter reads over the ceiling, throw the temporary file away and repeat
///      step 2 with twice the margin (`Limiter.margins`); after the last, give up.
/// Block sizes don't matter: the output is the same bit for bit however it is fed.
public struct Limiter: Sendable, Equatable {
    /// The true peak the result stays at or under, dBTP.
    public var ceilingDB: Double
    /// Time constant with which the gain rises back, milliseconds.
    public var releaseMs: Double
    /// How far ahead a peak is seen, and how long the gain takes to get down, milliseconds.
    public var lookaheadMs: Double

    public init(ceilingDB: Double = -1, releaseMs: Double = 100, lookaheadMs: Double = 5) {
        self.ceilingDB = ceilingDB
        self.releaseMs = releaseMs
        self.lookaheadMs = lookaheadMs
    }

    public static let ceilingRange = -20.0...0.0
    public static let releaseRange = 1.0...2_000.0
    public static let lookaheadRange = 0.5...20.0
    /// The margins under the ceiling `limit` tries, in order, dB.
    public static let margins: [Double] = [0.05, 0.1, 0.2, 0.4, 0.8]

    /// NaN and infinity are in no range, so they are refused here too.
    public func validate() throws {
        guard Self.ceilingRange.contains(ceilingDB) else { throw LimiterError.badValue(Said("limiter.ceiling_20_0_dbtp", "ceiling must be −20 to 0 dBTP.")) }
        guard Self.releaseRange.contains(releaseMs) else { throw LimiterError.badValue(Said("limiter.release_1_2000_ms", "release must be 1 to 2000 ms.")) }
        guard Self.lookaheadRange.contains(lookaheadMs) else { throw LimiterError.badValue(Said("limiter.lookahead_0_5_20", "lookahead must be 0.5 to 20 ms.")) }
    }

    static func validate(channels: Int, sampleRate: Double) throws {
        guard (1...64).contains(channels) else { throw LimiterError.badValue(Said("limiter.channels_1_64", "channels must be 1 to 64.")) }
        guard (1_000.0...1_000_000.0).contains(sampleRate) else { throw LimiterError.badValue(Said("limiter.sample_rate_1_1000", "sample rate must be 1 to 1000 kHz.")) }
    }

    public struct Report: Sendable, Equatable {
        public var truePeakBeforeDB: Double
        public var truePeakAfterDB: Double
        /// The largest gain reduction, as a positive number of dB. 0: nothing was changed.
        public var reductionMaxDB: Double
        /// Time during which the gain was under 1.
        public var limitedSeconds: Double
        public var ceilingDB: Double
        /// How far under the ceiling the limiter had to aim. 0 when nothing was changed.
        public var marginDB: Double
    }

    /// Limits a whole buffer. Already at or under the ceiling: the input, bit for bit.
    /// Throws rather than return audio that is over the ceiling.
    public static func limit(_ interleaved: [Float], channels: Int, sampleRate: Double,
                             settings: Limiter) throws -> (output: [Float], report: Report) {
        try settings.validate()
        try validate(channels: channels, sampleRate: sampleRate)
        guard interleaved.count % channels == 0 else { throw LimiterError.badValue(Said("limiter.audio_whole_frames_channels", "the audio must be whole frames of %@ channels.", "\(channels)")) }
        func peak(_ x: [Float]) -> Double {
            var m = PeakMeter(channels: channels, sampleRate: sampleRate)
            m.process(x)
            return m.peakDB
        }
        let before = peak(interleaved)
        if interleaved.isEmpty || before <= settings.ceilingDB {
            return (interleaved, Report(truePeakBeforeDB: before, truePeakAfterDB: before, reductionMaxDB: 0,
                                        limitedSeconds: 0, ceilingDB: settings.ceilingDB, marginDB: 0))
        }
        var last = before
        for margin in margins {
            var p = try Processor(settings, channels: channels, sampleRate: sampleRate, marginDB: margin)
            var out = p.process(interleaved)
            out += p.finish()
            last = peak(out)
            if last <= settings.ceilingDB {
                return (out, Report(truePeakBeforeDB: before, truePeakAfterDB: last, reductionMaxDB: p.stats.reductionMaxDB,
                                    limitedSeconds: Double(p.stats.limitedFrames) / sampleRate,
                                    ceilingDB: settings.ceilingDB, marginDB: margin))
            }
        }
        throw LimiterError.ceilingNotMet(Said("limiter.ceilingNotMet", "The limiter couldn't keep the true peak under %1$@ dBTP (it came to %2$@). Try a longer lookahead.", values: [Said.n(settings.ceilingDB, 1), Said.n(last, 2)]))
    }
}

public enum LimiterError: Error, LocalizedError, Equatable, KeyedFailure {
    case badValue(Said)
    case ceilingNotMet(Said)
    /// The audio is already at or under the ceiling.
    case nothingToDo(Said)

    public var errorDescription: String? { said.text }
    public var keyed: KeyedMessage? { said.keyed }
    var said: Said {
        switch self {
        case .badValue(let m), .ceilingNotMet(let m), .nothingToDo(let m): m
        }
    }
}

extension Limiter {
    /// The peak as `LoudnessMeter` reports it (the higher of sample peak and oversampled
    /// peak), without the loudness work. Feed interleaved blocks, read `peakDB`.
    public struct PeakMeter: Sendable {
        private var truePeak: TruePeak
        private var samplePeak: Float = 0

        public init(channels: Int, sampleRate: Double) {
            truePeak = TruePeak(channels: max(1, channels), sampleRate: sampleRate)
        }

        public mutating func process(_ interleaved: UnsafeBufferPointer<Float>) {
            guard let base = interleaved.baseAddress, !interleaved.isEmpty else { return }
            var m: Float = 0
            vDSP_maxmgv(base, 1, &m, vDSP_Length(interleaved.count))
            samplePeak = max(samplePeak, m)
            truePeak.process(interleaved)
        }

        public mutating func process(_ interleaved: [Float]) {
            interleaved.withUnsafeBufferPointer { process($0) }
        }

        /// dBTP; −∞ for silence.
        public var peakDB: Double { 20 * log10(Double(max(samplePeak, truePeak.peak))) }
    }

    public struct Stats: Sendable, Equatable {
        /// Frames that left with a gain under 1.
        public var limitedFrames: Int64 = 0
        public var lowestGain: Float = 1
        public var reductionMaxDB: Double { lowestGain < 1 ? -20 * log10(Double(lowestGain)) : 0 }
    }

    /// The streaming limiter. `process` any number of times, then `finish`: together they
    /// return exactly the frames that went in, frame k out for frame k in. The lookahead is
    /// hidden; what `process` returns runs behind what it has been given, and `finish`
    /// returns the rest.
    public struct Processor: Sendable {
        public let channels: Int
        public let sampleRate: Double
        /// Lookahead in frames.
        public let lookahead: Int
        public private(set) var stats = Stats()

        /// The oversampler is always run over the same stretches of the file, whatever the
        /// caller's blocks are, so that not even its rounding depends on them.
        static let chunk = 4_096
        /// The oversampled points between frames j and j+1 come out of the meter's filter
        /// at index j+16 (its delay is 15.875 frames at every factor).
        static let reach = 16
        /// The release aims a little over 1 and is cut off there; aimed at 1 it would
        /// never arrive, and the gain has to be exactly 1 again for the audio to pass untouched.
        static let releaseAim = 1.001

        private let target: Double
        private let releaseStep: Double
        private let factor: Int
        private let phases: [[Float]]
        private var history: [[Float]]
        private var work: [Float]
        private var conv: [Float]
        private var env: [Float]
        private var lastEnv: Float = 0

        /// Input not yet returned; `fifoStart` is the frame its first sample belongs to.
        private var fifo: [Float] = []
        private var fifoStart = 0
        /// Frames run through the oversampler, required gains taken, frames returned.
        private var detected = 0
        private var pushed = 0
        private var emitted = 0
        private var finished = false

        /// Sliding minimum: candidates in rising order, oldest first.
        private let window: Int
        private var dqValue: [Double]
        private var dqIndex: [Int]
        private var dqHead = 0
        private var dqCount = 0
        private var released = 1.0
        /// Moving average, kept as what is missing from 1 so that "all ones" is exactly 0.
        private var ring: [Double]
        private var ringPos = 0
        private var ringSum = 0.0
        private var ringNonZero = 0

        /// `marginDB`: how far under the ceiling to aim (see `Limiter.limit`).
        public init(_ settings: Limiter, channels: Int, sampleRate: Double, marginDB: Double = 0) throws {
            try settings.validate()
            try Limiter.validate(channels: channels, sampleRate: sampleRate)
            guard (0.0...6.0).contains(marginDB) else { throw LimiterError.badValue(Said("limiter.margin_0_6_db", "margin must be 0 to 6 dB.")) }
            self.channels = channels
            self.sampleRate = sampleRate
            lookahead = max(1, Int((settings.lookaheadMs / 1_000 * sampleRate).rounded()))
            window = lookahead + 1
            target = pow(10, (settings.ceilingDB - marginDB) / 20)
            releaseStep = 1 - exp(-1 / (settings.releaseMs / 1_000 * sampleRate))
            // The meter's own filter, so the limiter sees the peaks the meter will.
            let meter = TruePeak(channels: 1, sampleRate: sampleRate)
            factor = meter.factor
            phases = meter.phases
            let taps = TruePeak.tapsPerPhase
            history = Array(repeating: [Float](repeating: 0, count: taps - 1), count: channels)
            let most = Self.chunk + Self.reach
            work = [Float](repeating: 0, count: most + taps - 1)
            conv = [Float](repeating: 0, count: most)
            env = [Float](repeating: 0, count: most)
            dqValue = [Double](repeating: 1, count: window)
            dqIndex = [Int](repeating: 0, count: window)
            ring = [Double](repeating: 0, count: window)
        }

        private var received: Int { fifoStart + fifo.count / channels }

        public mutating func process(_ interleaved: [Float]) -> [Float] {
            interleaved.withUnsafeBufferPointer { process($0) }
        }

        /// A block may end in the middle of a frame; the rest of the frame comes with the next.
        public mutating func process(_ interleaved: UnsafeBufferPointer<Float>) -> [Float] {
            guard !finished, !interleaved.isEmpty else { return [] }
            var out: [Float] = []
            out.reserveCapacity(interleaved.count + Self.chunk * channels)
            // In pieces, so a whole file given at once isn't copied whole.
            let piece = 65_536 * channels
            var at = 0
            while at < interleaved.count {
                let n = min(piece, interleaved.count - at)
                fifo.append(contentsOf: UnsafeBufferPointer(rebasing: interleaved[at..<(at + n)]))
                at += n
                var gains: [Float] = []
                while received - detected >= Self.chunk { run(Self.chunk, real: Self.chunk, into: &gains) }
                apply(gains, into: &out)
            }
            return out
        }

        /// The frames still held back. Nothing more can be processed afterwards.
        public mutating func finish() -> [Float] {
            var out: [Float] = []
            apply(finishGains(keep: true), into: &out)
            fifo = []
            return out
        }

        /// The gain of each frame instead of the limited audio, one value per frame, for a caller that
        /// applies it to something else than what was listened to: the mix is given here, and the same
        /// gain goes on every track of it, so that their sum is the limited mix. Same order and
        /// alignment as `process`: `gains` any number of times, then `finishGains`; gain k is frame k's.
        public mutating func gains(_ interleaved: [Float]) -> [Float] {
            guard !finished, !interleaved.isEmpty else { return [] }
            var all: [Float] = []
            let piece = 65_536 * channels
            var at = 0
            while at < interleaved.count {
                let n = min(piece, interleaved.count - at)
                fifo.append(contentsOf: interleaved[at..<(at + n)])
                at += n
                var gains: [Float] = []
                while received - detected >= Self.chunk { run(Self.chunk, real: Self.chunk, into: &gains) }
                dropReturned(gains.count)
                all += gains
            }
            return all
        }

        public mutating func finishGains() -> [Float] {
            let g = finishGains(keep: false)
            fifo = []
            return g
        }

        private mutating func finishGains(keep: Bool) -> [Float] {
            guard !finished else { return [] }
            var gains: [Float] = []
            // Silence after the end lets the oversampler reach the last frames, and
            // "no limiting needed" after the end lets the lookahead do the same.
            let real = received - detected
            run(real + Self.reach, real: real, into: &gains)
            for _ in 0..<lookahead { push(1, into: &gains) }
            finished = true
            if !keep { dropReturned(gains.count) }
            return gains
        }

        /// The frames these gains belong to (the oldest held), limited, and then let go.
        private mutating func apply(_ gains: [Float], into out: inout [Float]) {
            let ch = channels
            for (i, gain) in gains.enumerated() {
                let o = i * ch
                if gain < 1 {
                    for c in 0..<ch { out.append(fifo[o + c] * gain) }
                } else {
                    out.append(contentsOf: fifo[o..<(o + ch)])
                }
            }
            dropReturned(gains.count)
        }

        private mutating func dropReturned(_ frames: Int) {
            guard frames > 0 else { return }
            fifo.removeFirst(min(fifo.count, frames * channels))
            fifoStart += frames
        }

        /// Oversamples `n` frames from `detected` on, of which the first `real` exist and
        /// the rest are silence, and takes the required gain of each frame now in reach.
        private mutating func run(_ n: Int, real: Int, into out: inout [Float]) {
            // `out` gathers gains; the frames they belong to stay in `fifo` until the caller lets them go.
            let ch = channels, taps = TruePeak.tapsPerPhase
            let base = (detected - fifoStart) * ch
            env.withUnsafeMutableBufferPointer { vDSP_vclr($0.baseAddress!, 1, vDSP_Length(n)) }
            // No oversampling at 192 kHz and up, like the meter.
            if factor > 1 {
                for c in 0..<ch {
                    work.replaceSubrange(0..<(taps - 1), with: history[c])
                    work.withUnsafeMutableBufferPointer { w in
                        if real > 0 {
                            fifo.withUnsafeBufferPointer { deinterleave($0.baseAddress! + base + c, ch, real, w.baseAddress! + taps - 1) }
                        }
                        if real < n { vDSP_vclr(w.baseAddress! + taps - 1 + real, 1, vDSP_Length(n - real)) }
                    }
                    for coeffs in phases {
                        vDSP_conv(work, 1, coeffs, 1, &conv, 1, vDSP_Length(n), vDSP_Length(taps))
                        env.withUnsafeMutableBufferPointer { e in
                            vDSP_vmaxmg(conv, 1, e.baseAddress!, 1, e.baseAddress!, 1, vDSP_Length(n))
                        }
                    }
                    history[c] = Array(work[n..<(n + taps - 1)])
                }
            }
            for t in 0..<n {
                // The points on either side of frame j: just before it and just after.
                let e = env[t]
                var level = max(lastEnv, e)
                lastEnv = e
                let j = detected + t - Self.reach
                if j < 0 { continue }
                let o = (j - fifoStart) * ch
                for c in 0..<ch { level = max(level, abs(fifo[o + c])) }
                // Silence gives infinity and a NaN sample gives NaN: both mean "leave it".
                let g = target / Double(level)
                push(g < 1 ? g : 1, into: &out)
            }
            detected += n
        }

        /// Takes the required gain of frame `pushed`, and gives the gain of frame `pushed − lookahead`.
        private mutating func push(_ g: Double, into out: inout [Float]) {
            let k = pushed
            pushed += 1
            // Lowest required gain over frames k−lookahead…k.
            while dqCount > 0, dqValue[(dqHead + dqCount - 1) % window] >= g { dqCount -= 1 }
            if dqCount > 0, dqIndex[dqHead] <= k - window {
                dqHead = (dqHead + 1) % window
                dqCount -= 1
            }
            let slot = (dqHead + dqCount) % window
            dqValue[slot] = g
            dqIndex[slot] = k
            dqCount += 1
            released = min(dqValue[dqHead], 1, released + (Self.releaseAim - released) * releaseStep)

            let missing = 1 - released
            let old = ring[ringPos]
            ring[ringPos] = missing
            ringPos = (ringPos + 1) % window
            ringSum += missing - old
            ringNonZero += (missing != 0 ? 1 : 0) - (old != 0 ? 1 : 0)
            // Back at all ones: forget the rounding the running sum has gathered.
            if ringNonZero == 0 { ringSum = 0 }

            // The first `lookahead` values only fill the window: they belong to the time
            // before the file, where the gain is on its way down to what frame 0 needs.
            guard k >= lookahead else { return }
            let gain = Float(min(1, 1 - max(0, ringSum) / Double(window)))
            if gain < 1 {
                stats.limitedFrames += 1
                stats.lowestGain = min(stats.lowestGain, gain)
            }
            out.append(gain)
            emitted += 1
        }
    }
}
