import Accelerate
import Foundation

public enum DebleedError: Error, LocalizedError, Equatable {
    case noSpeakers
    case needsTracks

    public var reason: String {
        switch self {
        case .noSpeakers: "no_speakers"
        case .needsTracks: "needs_tracks"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .noSpeakers: "Gate needs each track's speech; run diarize with mode by_track first."
        case .needsTracks: "Cancel needs two or more tracks that play at the same time."
        }
    }
    /// The same message by its key in the app's string catalogue (see `KeyedMessage`).
    public var keyed: KeyedMessage? {
        switch self {
        case .noSpeakers: KeyedMessage("error.debleed.noSpeakers")
        case .needsTracks: KeyedMessage("error.debleed.needsTracks")
        }
    }
}

public struct DebleedReport: Sendable, Equatable {
    public var tracks: Int
    /// How much quieter the other speakers became on the processed tracks, measured where
    /// only they talk (dB, the mean over tracks).
    public var reductionDB: Double
}

public enum Debleed {
    /// Gain over time for gate: 1 inside `speech` (exactly, so the speech stays bit for
    /// bit), `floor` outside, with equal-power ramps of `ramp` frames placed outside the
    /// speech.
    static func gateEnvelope(count: Int, speech: [Range<Int>], floor: Float, ramp: Int) -> [Float] {
        var g = [Float](repeating: floor, count: count)
        for r in speech {
            let lo = max(0, r.lowerBound), hi = min(count, r.upperBound)
            if hi > lo { for i in lo..<hi { g[i] = 1 } }
            for k in 0..<ramp {
                let w = Float(sin(Double(ramp - k) / Double(ramp) * .pi / 2))
                let v = floor + (1 - floor) * w * w
                let a = lo - 1 - k, b = hi + k
                if a >= 0, a < count, g[a] < v { g[a] = v }
                if b >= 0, b < count, g[b] < v { g[b] = v }
            }
        }
        return g
    }

    /// The delay (frames, 0…maxLag) at which `ref` leaks into `x`, by GCC-PHAT on the
    /// waveforms (sharp even for a faint, band-limited leak); `x` should have its own
    /// speech zeroed. Uses up to the first 60 s.
    static func leakDelay(_ x: [Float], ref: [Float], maxLag: Int, sampleRate: Double) -> Int {
        let n = min(x.count, ref.count, Int(60 * sampleRate))
        guard n > 0 else { return 0 }
        var log2n = 1
        while (1 << log2n) < n + maxLag { log2n += 1 }
        let size = 1 << log2n
        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { return 0 }
        defer { vDSP_destroy_fftsetup(setup) }
        func spectrum(_ s: [Float]) -> ([Float], [Float]) {
            var buf = [Float](repeating: 0, count: size)
            for i in 0..<n { buf[i] = s[i] }
            var re = [Float](repeating: 0, count: size / 2), im = [Float](repeating: 0, count: size / 2)
            re.withUnsafeMutableBufferPointer { r in
                im.withUnsafeMutableBufferPointer { m in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: m.baseAddress!)
                    buf.withUnsafeBytes { raw in vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(size / 2)) }
                    vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(kFFTDirection_Forward))
                }
            }
            return (re, im)
        }
        let (xr, xi) = spectrum(x), (rr, ri) = spectrum(ref)
        // X · conj(R), whitened (PHAT). Bin 0 packs DC and Nyquist; drop both.
        var cr = [Float](repeating: 0, count: size / 2), ci = [Float](repeating: 0, count: size / 2)
        for k in 1..<(size / 2) {
            let a = xr[k] * rr[k] + xi[k] * ri[k], b = xi[k] * rr[k] - xr[k] * ri[k]
            let m = max(1e-12, (a * a + b * b).squareRoot())
            cr[k] = a / m
            ci[k] = b / m
        }
        var out = [Float](repeating: 0, count: size)
        cr.withUnsafeMutableBufferPointer { r in
            ci.withUnsafeMutableBufferPointer { m in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: m.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(kFFTDirection_Inverse))
                out.withUnsafeMutableBytes { raw in vDSP_ztoc(&split, 1, raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(size / 2)) }
            }
        }
        // out[d] is the correlation of x(t) with ref(t − d): the leak arrives after.
        var best = 0
        for d in 0...min(maxLag, size - 1) where out[d] > out[best] { best = d }
        return best
    }

    /// Removes `ref`'s leak from `x`: delays `ref` by `delay` frames, then per STFT bin a
    /// complex transfer H = Σ X·R* / Σ |R|² learnt over frames where `learn` is true (x's own
    /// speaker silent, the other talking), subtracted from every frame. Channels mono.
    static func cancel(_ x: [Float], ref: [Float], delay: Int, learn: (Int) -> Bool, size: Int = 2_048) -> [Float] {
        let n = x.count, hop = size / 4
        var r = [Float](repeating: 0, count: n)
        for i in 0..<n where i - delay >= 0 && i - delay < ref.count { r[i] = ref[i - delay] }
        let stft = Spectral.STFT(size: size)
        let bins = size / 2
        let xs = x + [Float](repeating: 0, count: size), rs = r + [Float](repeating: 0, count: size)
        var frames: [(Int, ([Float], [Float]), ([Float], [Float]))] = []
        var at = -size + hop
        while at < n {
            func frame(_ s: [Float]) -> ([Float], [Float]) {
                var f = [Float](repeating: 0, count: size)
                for i in 0..<size where at + i >= 0 && at + i < s.count { f[i] = s[at + i] }
                return f.withUnsafeBufferPointer { stft.forward($0.baseAddress!) }
            }
            frames.append((at, frame(xs), frame(rs)))
            at += hop
        }
        var num = [(Double, Double)](repeating: (0, 0), count: bins), den = [Double](repeating: 1e-12, count: bins)
        for (at, X, R) in frames where learn(at + size / 2) {
            for k in 0..<bins {
                let xr = Double(X.0[k]), xi = Double(X.1[k]), rr = Double(R.0[k]), ri = Double(R.1[k])
                num[k].0 += xr * rr + xi * ri
                num[k].1 += xi * rr - xr * ri
                den[k] += rr * rr + ri * ri
            }
        }
        let h = (0..<bins).map { k in (num[k].0 / den[k], num[k].1 / den[k]) }
        var acc = [Float](repeating: 0, count: n + 2 * size), norm = [Float](repeating: 0, count: n + 2 * size)
        for (at, X, R) in frames {
            var re = X.0, im = X.1
            for k in 1..<bins {
                let (hr, hi) = h[k]
                re[k] -= Float(hr * Double(R.0[k]) - hi * Double(R.1[k]))
                im[k] -= Float(hr * Double(R.1[k]) + hi * Double(R.0[k]))
            }
            let y = stft.inverse(re, im)
            for i in 0..<size {
                let idx = at + i + size
                guard idx >= 0, idx < acc.count else { continue }
                acc[idx] += y[i] * stft.window[i]
                norm[idx] += stft.window[i] * stft.window[i]
            }
        }
        return (0..<n).map { i in norm[i + size] > 1e-6 ? acc[i + size] / norm[i + size] / Float(2 * size) : x[i] }
    }
}

extension Project {
    /// debleed: gate lowers each track outside its own speaker's turns; cancel subtracts the
    /// other tracks' leak, found by cross-correlation (up to `searchMs`) and learnt where the
    /// track's own speaker is silent. Each processed track is bounced into one new file
    /// over its extent, words and turns carried over.
    public func debleeding(method: String, tracks wanted: [UUID]? = nil, amountDB: Double = -18, windowMs: Double = 30,
                           searchMs: Double = 1_000, pool: SourcePool, media: URL) throws -> (Project, DebleedReport) {
        let active = tracks.indices.filter { !tracks[$0].isMuted && !tracks[$0].clips.isEmpty }
        let turns = placedTurns()
        var targets = active.filter { t in wanted?.contains(tracks[t].id) ?? true }
        if method == "gate" {
            targets = targets.filter { t in turns.contains { $0.track == t } }
            guard !targets.isEmpty else { throw DebleedError.noSpeakers }
        } else {
            guard hasOverlappingTracks, active.count >= 2, !targets.isEmpty else { throw DebleedError.needsTracks }
        }
        // Own speech per track: the diarised turns, else the bleed-aware level detection.
        let speech: [Int: [Range<Frame>]] = {
            var out: [Int: [Range<Frame>]] = [:]
            for t in active { out[t] = turns.filter { $0.track == t }.map { $0.start..<$0.end } }
            if method == "cancel", out.values.contains(where: \.isEmpty) {
                for d in Diarization.byTrack(self, pool: pool, tracks: active.map { tracks[$0].id }) {
                    if let t = tracks.firstIndex(where: { $0.id == d.track }), out[t]?.isEmpty ?? true { out[t] = d.turns.map(\.range) }
                }
            }
            return out
        }()
        func mono(_ t: Int) -> [Float] {
            var solo = self
            solo.tracks = [tracks[t]]
            solo.withoutMixer()
            solo.tracks[0].gainDB = 0
            solo.tracks[0].isMuted = false
            let raw = PlanCompiler.compile(solo, pool: pool).render(from: 0, frames: Int(length))
            return stride(from: 0, to: raw.count, by: channels).map { i in (0..<channels).reduce(Float(0)) { $0 + raw[i + $1] } / Float(channels) }
        }
        func inside(_ f: Int, _ rs: [Range<Frame>]) -> Bool { rs.contains { $0.contains(Frame(f)) } }
        func level(_ x: [Float], where keep: (Int) -> Bool) -> Double {
            var e = 0.0, n = 0
            for i in stride(from: 0, to: x.count, by: 4) where keep(i) { e += Double(x[i] * x[i]); n += 1 }
            return 10 * log10(max(1e-20, e / Double(max(1, n))))
        }
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        var p = self
        let words = placedWords()
        var reductions: [Double] = []
        let monos = Dictionary(uniqueKeysWithValues: active.map { ($0, mono($0)) })
        for t in targets {
            let own = speech[t] ?? []
            let others = active.filter { $0 != t }
            let othersOnly: (Int) -> Bool = { f in !inside(f, own) && others.contains { inside(f, speech[$0] ?? []) } }
            let first = tracks[t].clips.map(\.start).min()!, end = tracks[t].end
            // Render the track as heard (stereo), process per channel.
            var solo = self
            solo.tracks = [tracks[t]]
            solo.withoutMixer()
            solo.tracks[0].gainDB = 0
            solo.tracks[0].isMuted = false
            let raw = PlanCompiler.compile(solo, pool: pool).render(from: 0, frames: Int(length))
            var out = raw
            if method == "gate" {
                let env = Debleed.gateEnvelope(count: Int(length), speech: own.map { Int($0.lowerBound)..<Int($0.upperBound) },
                                               floor: Float(pow(10, amountDB / 20)), ramp: Int(0.02 * sampleRate))
                for i in 0..<Int(length) where env[i] != 1 { for c in 0..<channels { out[i * channels + c] = raw[i * channels + c] * env[i] } }
            } else {
                for o in others {
                    // The leak's delay: cross-correlate this track (own speech removed) with the other.
                    var masked = monos[t]!
                    for (i, _) in masked.enumerated() where inside(i, own) { masked[i] = 0 }
                    let delay = Debleed.leakDelay(masked, ref: monos[o]!, maxLag: Int(frames(searchMs / 1_000)), sampleRate: sampleRate)
                    let learn: (Int) -> Bool = { f in !inside(f, own) && inside(f, speech[o] ?? []) }
                    // The analysis frame covers the leak's spread around that delay (the window).
                    let size = windowMs <= 30 ? 2_048 : 4_096
                    for c in 0..<channels {
                        let x = stride(from: c, to: out.count, by: channels).map { out[$0] }
                        let y = Debleed.cancel(x, ref: monos[o]!, delay: delay, learn: learn, size: size)
                        for i in 0..<y.count { out[i * channels + c] = y[i] }
                    }
                }
            }
            let before = level(monos[t]!, where: othersOnly)
            let processedMono = stride(from: 0, to: out.count, by: channels).map { i in (0..<channels).reduce(Float(0)) { $0 + out[i + $1] } / Float(channels) }
            reductions.append(before - level(processedMono, where: othersOnly))
            let url = media.appending(path: "\(UUID().uuidString.prefix(8)) debleed.wav")
            // Noted as made by Jämmer: only such a file can ever be offered for removal (MediaStorage).
            MediaRegister.made(url, kind: "debleed", in: media)
            let w = try WAVWriter(url: url, options: .init(encoding: .float32, channels: channels, sampleRate: sampleRate))
            try w.write(Array(out[Int(first) * channels..<Int(end) * channels]))
            try w.finish()
            let src = SourceRef(name: "\(tracks[t].name) (de-bled)", path: url.path, info: try AudioFileReader.info(at: url)).withRepairs(repairsCarried(by: tracks[t]))
            p.sources.append(src)
            let mine = words.filter { $0.track == t }.map { w -> Word in var w2 = w.word; w2.start = w.start - first; w2.end = w.end - first; return w2 }
            if !mine.isEmpty { p.setTranscript(SourceTranscript(sourceID: src.id, language: transcripts.first?.language ?? "und", engine: "carried", words: mine)) }
            p.addCarriedTurns(turnsForBounce(track: t, range: first..<end), to: src.id)
            p.tracks[t].clips = [Clip(sourceID: src.id, start: first, length: end - first)]
        }
        p.pruneSources()
        let mean = reductions.isEmpty ? 0 : reductions.reduce(0, +) / Double(reductions.count)
        return (p, DebleedReport(tracks: targets.count, reductionDB: (mean * 10).rounded() / 10))
    }
}

extension DebleedError: KeyedFailure {}
