import Foundation

/// An area of the spectrogram: time in timeline seconds, frequency in Hz.
public enum SpectralShape: Sendable, Equatable {
    case box(start: Double, end: Double, low: Double, high: Double)
    /// Corners in order; at least three.
    case polygon([SpectralPoint])
    /// A brush stroke through `points`, `radius` Hz and `radiusTime` seconds around it.
    case brush([SpectralPoint], radius: Double, radiusTime: Double)

    /// The time span it covers (seconds).
    public var timeSpan: ClosedRange<Double> {
        switch self {
        case .box(let a, let b, _, _): return min(a, b)...max(a, b)
        case .polygon(let p): return p.map(\.t).min()!...p.map(\.t).max()!
        case .brush(let p, _, let rt): return (p.map(\.t).min()! - rt)...(p.map(\.t).max()! + rt)
        }
    }

    public var frequencySpan: ClosedRange<Double> {
        switch self {
        case .box(_, _, let lo, let hi): return min(lo, hi)...max(lo, hi)
        case .polygon(let p): return p.map(\.f).min()!...p.map(\.f).max()!
        case .brush(let p, let r, _): return max(0, p.map(\.f).min()! - r)...(p.map(\.f).max()! + r)
        }
    }

    public func contains(t: Double, f: Double) -> Bool {
        switch self {
        case .box(let a, let b, let lo, let hi):
            return t >= min(a, b) && t <= max(a, b) && f >= min(lo, hi) && f <= max(lo, hi)
        case .polygon(let p):
            // Ray casting in (t, f).
            var inside = false
            var j = p.count - 1
            for i in p.indices {
                if (p[i].f > f) != (p[j].f > f), t < (p[j].t - p[i].t) * (f - p[i].f) / (p[j].f - p[i].f) + p[i].t { inside.toggle() }
                j = i
            }
            return inside
        case .brush(let p, let r, let rt):
            guard r > 0, rt > 0 else { return false }
            func d(_ a: SpectralPoint, _ b: SpectralPoint) -> Double {
                // Distance from (t, f) to segment a–b, in units of the brush radii.
                let ax = a.t / rt, ay = a.f / r, bx = b.t / rt, by = b.f / r, px = t / rt, py = f / r
                let vx = bx - ax, vy = by - ay
                let len = vx * vx + vy * vy
                let u = len > 0 ? max(0, min(1, ((px - ax) * vx + (py - ay) * vy) / len)) : 0
                let dx = px - (ax + u * vx), dy = py - (ay + u * vy)
                return (dx * dx + dy * dy).squareRoot()
            }
            if p.count == 1 { return d(p[0], p[0]) <= 1 }
            return zip(p, p.dropFirst()).contains { d($0, $1) <= 1 }
        }
    }

    /// "4.20–4.60 s, 2000–6000 Hz", for VoiceOver and the status bar.
    public var summary: String {
        let t = timeSpan, f = frequencySpan
        let kind: String
        switch self {
        case .box: kind = "Box"
        case .polygon(let p): kind = "Lasso (\(p.count) corners)"
        case .brush: kind = "Brush"
        }
        return String(format: "%@, %.2f–%.2f s, %.0f–%.0f Hz", kind, t.lowerBound, t.upperBound, f.lowerBound, f.upperBound)
    }
}

public struct SpectralPoint: Sendable, Equatable {
    public var t: Double
    public var f: Double
    public init(t: Double, f: Double) {
        self.t = t
        self.f = f
    }
}

public enum SpectralAction: String, Sendable { case attenuate, heal }

public enum SpectralEditError: Error, LocalizedError, Equatable {
    case badShape(String)
    case tooLong(Double)
    case noContext

    public var reason: String {
        switch self {
        case .badShape: "bad_shape"
        case .tooLong: "too_long"
        case .noContext: "no_context"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .badShape(let m): m
        case .tooLong(let s): String(format: "Heal is for short sounds (up to %.1f s); this area is %.2f s. Use attenuate for longer ones.", Spectral.healLimit, s)
        case .noContext: "Heal needs sound on both sides of the area to rebuild it from; this one touches the start or the end."
        }
    }
    /// The same message by its key in the app's string catalogue (see `KeyedMessage`).
    public var keyed: KeyedMessage? {
        switch self {
        case .badShape: nil
        case .tooLong: nil
        case .noContext: KeyedMessage("error.spectralEdit.noContext")
        }
    }
}

extension Spectral {
    /// The longest area heal rebuilds: it interpolates between the frames on either side.
    public static let healLimit = 0.5

    /// Runs one channel through the STFT and changes the bins inside `mask` (frame-centre
    /// sample index relative to `x`, frequency in Hz): attenuate scales them by `gain`;
    /// heal rebuilds each bin's magnitude by interpolating, in log, between the frames
    /// just before and after the area, keeping the original phase. Samples outside the
    /// touched frames (plus a short crossfade) come back bit for bit.
    public static func edit(_ x: [Float], sampleRate: Double, span: Range<Int>, action: SpectralAction, gain: Float = 0.1,
                            size: Int = 2_048, mask: (Int, Double) -> Bool) -> [Float] {
        let hop = size / 4
        let lo = max(0, span.lowerBound - size), hi = min(x.count, span.upperBound + size)
        guard hi - lo > size else { return x }
        let stft = STFT(size: size)
        let seg = Array(x[lo..<hi]) + [Float](repeating: 0, count: size)
        let binHz = sampleRate / Double(size)
        let bins = size / 2
        // Every frame's spectrum first (heal needs the neighbours).
        var starts: [Int] = []
        var specs: [([Float], [Float])] = []
        seg.withUnsafeBufferPointer { p in
            var at = -size + hop
            while at < seg.count {
                var frame = [Float](repeating: 0, count: size)
                for i in 0..<size where at + i >= 0 && at + i < seg.count { frame[i] = p[at + i] }
                specs.append(frame.withUnsafeBufferPointer { stft.forward($0.baseAddress!) })
                starts.append(at)
                at += hop
            }
        }
        // The mask per frame and bin, softened over ±2 bins in frequency.
        var m = [[Float]](repeating: [Float](repeating: 0, count: bins), count: specs.count)
        for (j, at) in starts.enumerated() {
            let centre = lo + at + size / 2
            guard centre >= span.lowerBound - hop, centre < span.upperBound + hop else { continue }
            var raw = [Float](repeating: 0, count: bins)
            for k in 0..<bins where mask(centre, Double(k) * binHz) { raw[k] = 1 }
            for k in 0..<bins {
                var v: Float = 0
                for d in -2...2 where k + d >= 0 && k + d < bins { v = max(v, raw[k + d] * (1 - Float(abs(d)) / 3)) }
                m[j][k] = v
            }
        }
        var out = specs
        switch action {
        case .attenuate:
            for j in specs.indices {
                for k in 0..<bins where m[j][k] > 0 {
                    let s = 1 - m[j][k] + m[j][k] * gain
                    if k == 0 { out[j].0[0] *= s } else { out[j].0[k] *= s; out[j].1[k] *= s }
                }
            }
        case .heal:
            for k in 1..<bins {
                var j = 0
                while j < specs.count {
                    guard m[j][k] > 0 else { j += 1; continue }
                    let first = j
                    while j < specs.count, m[j][k] > 0 { j += 1 }
                    let l = first - 1, r = j
                    guard l >= 0, r < specs.count else { continue }
                    func mag(_ i: Int) -> Float { max(1e-12, (specs[i].0[k] * specs[i].0[k] + specs[i].1[k] * specs[i].1[k]).squareRoot()) }
                    let ml = log(mag(l)), mr = log(mag(r))
                    for i in first..<r {
                        let a = Float(i - l) / Float(r - l)
                        let target = exp(ml + (mr - ml) * a)
                        let now = mag(i)
                        let w = m[i][k]
                        let s = (1 - w) + w * (target / now)
                        out[i].0[k] = specs[i].0[k] * s
                        out[i].1[k] = specs[i].1[k] * s
                    }
                }
            }
        }
        var acc = [Float](repeating: 0, count: seg.count + size)
        var norm = [Float](repeating: 0, count: seg.count + size)
        for (j, at) in starts.enumerated() {
            let y = stft.inverse(out[j].0, out[j].1)
            for i in 0..<size {
                let idx = at + i + size
                guard idx >= 0, idx < acc.count else { continue }
                acc[idx] += y[i] * stft.window[i]
                norm[idx] += stft.window[i] * stft.window[i]
            }
        }
        var result = x
        let fade = hop
        for i in lo..<hi {
            let idx = i - lo + size
            guard norm[idx] > 1e-6 else { continue }
            let processed = acc[idx] / norm[idx] / Float(2 * size)
            let fromStart = i - (span.lowerBound - size), toEnd = (span.upperBound + size) - i
            let w = Float(max(0, min(1, Double(min(fromStart, toEnd)) / Double(fade))))
            result[i] = x[i] + w * (processed - x[i])
        }
        return result
    }
}

extension Project {
    /// spectral_edit: changes an area of the spectrogram on the given tracks (nil: all),
    /// bounced per track into a new file; words and speaker turns go with it.
    public func applyingSpectralEdit(_ shape: SpectralShape, action: SpectralAction, gainDB: Double = -20, tracks: Set<UUID>? = nil,
                                     pool: SourcePool, media: URL) throws -> Project {
        let t = shape.timeSpan, f = shape.frequencySpan
        if case .polygon(let p) = shape, p.count < 3 { throw SpectralEditError.badShape("A lasso needs at least three corners.") }
        guard t.upperBound > t.lowerBound || action == .heal, f.upperBound > f.lowerBound else { throw SpectralEditError.badShape("The area is empty.") }
        guard t.lowerBound < duration, t.upperBound > 0, f.lowerBound < sampleRate / 2 else {
            throw SpectralEditError.badShape("The area lies outside the audio (0–\(String(format: "%.2f", duration)) s, 0–\(Int(sampleRate / 2)) Hz).")
        }
        guard (-80...0).contains(gainDB) else { throw SpectralEditError.badShape("db must be between -80 and 0.") }
        if action == .heal {
            guard t.upperBound - t.lowerBound <= Spectral.healLimit else { throw SpectralEditError.tooLong(t.upperBound - t.lowerBound) }
            guard t.lowerBound > 0.05, t.upperBound < duration - 0.05 else { throw SpectralEditError.noContext }
        }
        // Heal reaches half an analysis window past the drawn area: frames whose window
        // overlaps the sound must be rebuilt too, or a short click survives in them.
        let pad = action == .heal ? 1_024.0 / sampleRate : 0
        let r = frames(max(0, t.lowerBound - pad))..<min(length, frames(t.upperBound + pad) + 1)
        let targets = self.tracks.indices.filter { i in
            (tracks?.contains(self.tracks[i].id) ?? true) && self.tracks[i].clips.contains { $0.start < r.upperBound && $0.end > r.lowerBound }
        }
        guard !r.isEmpty, !targets.isEmpty else { throw EffectError.nothingInRange }
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        var p = self
        let words = p.placedWords(in: r)
        let margin = 8_192
        let g = Float(pow(10, gainDB / 20))
        for ti in targets {
            var solo = self
            solo.tracks = [self.tracks[ti]]
            solo.withoutMixer()
            solo.tracks[0].gainDB = 0
            solo.tracks[0].isMuted = false
            let plan = PlanCompiler.compile(solo, pool: pool)
            let lo = max(0, r.lowerBound - Frame(margin)), hi = r.upperBound + Frame(margin)
            let raw = plan.render(from: lo, frames: Int(hi - lo))
            var out = [Float](repeating: 0, count: r.count * channels)
            for c in 0..<channels {
                let x = stride(from: c, to: raw.count, by: channels).map { raw[$0] }
                let y = Spectral.edit(x, sampleRate: sampleRate, span: Int(r.lowerBound - lo)..<Int(r.upperBound - lo), action: action, gain: g) { idx, hz in
                    let time = Double(lo + Frame(idx)) / sampleRate
                    return shape.contains(t: pad > 0 ? min(max(time, t.lowerBound), t.upperBound) : time, f: hz)
                        && time >= t.lowerBound - pad && time <= t.upperBound + pad
                }
                for i in 0..<r.count { out[i * channels + c] = y[i + Int(r.lowerBound - lo)] }
            }
            let url = media.appending(path: "\(UUID().uuidString.prefix(8)) spectral-\(action.rawValue).wav")
            // Noted as made by Jämmer: only such a file can ever be offered for removal (MediaStorage).
            MediaRegister.made(url, kind: "spectral", in: media)
            let w = try WAVWriter(url: url, options: .init(encoding: .float32, channels: channels, sampleRate: sampleRate))
            try w.write(out)
            try w.finish()
            let src = SourceRef(name: "\(self.tracks[ti].name) (\(action == .heal ? "healed" : "attenuated"))", path: url.path, info: try AudioFileReader.info(at: url)).withRepairs(repairsCarried(by: self.tracks[ti]))
            p.sources.append(src)
            p.tracks[ti].clips = p.tracks[ti].clips.flatMap { c -> [Clip] in
                var parts: [Clip] = []
                let (left, rest) = c.split(at: r.lowerBound)
                if let left { parts.append(left) }
                if let rest { let (_, right) = rest.split(at: r.upperBound); if let right { parts.append(right) } }
                return parts
            }
            p.tracks[ti].clips.append(Clip(sourceID: src.id, start: r.lowerBound, length: Frame(r.count)))
            p.tracks[ti].clips.sort { $0.start < $1.start }
            let mine = words.filter { $0.track == ti }.map { w -> Word in var w2 = w.word; w2.start = w.start - r.lowerBound; w2.end = w.end - r.lowerBound; return w2 }
            if !mine.isEmpty { p.setTranscript(SourceTranscript(sourceID: src.id, language: transcripts.first?.language ?? "und", engine: "carried", words: mine)) }
            p.addCarriedTurns(turnsForBounce(track: ti, range: r), to: src.id)
        }
        p.pruneSources()
        return p
    }
}

extension SpectralEditError: KeyedFailure {}
