import Foundation

/// A feedback echo: out = x + mix · e, where e[n] = x[n−D] + feedback · e[n−D].
/// mix 0 returns the input bit for bit. Streaming: keep the value between blocks.
public struct Echo: Sendable, Equatable {
    public var delay: Double
    public var feedback: Double
    public var mix: Double

    public init(delay: Double, feedback: Double, mix: Double) {
        self.delay = delay
        self.feedback = feedback
        self.mix = mix
    }

    public static let delayRange = 0.02...2.0
    public static let feedbackRange = 0.0...0.95

    /// How long the echoes ring after the input stops: until they're 60 dB down, at most 10 s.
    public func tail(sampleRate: Double) -> Frame {
        let d = Frame((delay * sampleRate).rounded())
        guard feedback > 0 else { return d }
        let repeats = (log(0.001) / log(feedback)).rounded(.up)
        return min(Frame(sampleRate * 10), d * Frame(max(1, repeats)))
    }

    /// One channel's delay line.
    public struct Line: Sendable {
        let d: Int
        let feedback: Float, mix: Float
        var buffer: [Float]
        var pos = 0

        public init(_ echo: Echo, sampleRate: Double) {
            d = max(1, Int((echo.delay * sampleRate).rounded()))
            feedback = Float(echo.feedback)
            mix = Float(echo.mix)
            buffer = [Float](repeating: 0, count: d)
        }

        public mutating func process(_ x: [Float]) -> [Float] {
            if mix == 0 { return x }
            var y = x
            for i in x.indices {
                // buffer[pos] holds e[n − D]'s source: x[n−D] + feedback·e[n−D].
                let e = buffer[pos]
                y[i] = x[i] + mix * e
                buffer[pos] = x[i] + feedback * e
                pos += 1
                if pos == d { pos = 0 }
            }
            return y
        }
    }
}

public enum EffectError: Error, LocalizedError, Equatable {
    case nothingInRange
    case badValue(String)

    public var errorDescription: String? {
        switch self {
        case .nothingInRange: "There's no audio in that range on those tracks."
        case .badValue(let m): m
        }
    }
}

extension Project {
    /// Echo on `range` of the given tracks (nil: all), bounced in place: each track's own
    /// audio in the range is rendered through the echo into a new file in `media`, and
    /// replaces the clips there. With `tail`, room is opened after the range on every
    /// track (ripple) so the echoes ring out. Originals are untouched; undo is the old value.
    public func applyingEcho(_ echo: Echo, range: Range<Frame>, tracks: Set<UUID>? = nil, tail: Bool,
                             pool: SourcePool, media: URL) throws -> Project {
        guard Echo.delayRange.contains(echo.delay) else { throw EffectError.badValue("delay must be 0.02–2 seconds.") }
        guard Echo.feedbackRange.contains(echo.feedback) else { throw EffectError.badValue("feedback must be 0–0.95.") }
        guard (0...1).contains(echo.mix) else { throw EffectError.badValue("mix must be 0–1.") }
        let r = range.clamped(to: 0..<length)
        let targets = self.tracks.indices.filter { t in
            (tracks?.contains(self.tracks[t].id) ?? true) && self.tracks[t].clips.contains { $0.start < r.upperBound && $0.end > r.lowerBound }
        }
        guard !r.isEmpty, !targets.isEmpty else { throw EffectError.nothingInRange }
        let extra = tail ? echo.tail(sampleRate: sampleRate) : 0
        var p = self
        // The words heard in the range, per track, to carry over to the bounced files.
        let words = p.placedWords(in: r)
        if extra > 0 { p.insertGap(at: r.upperBound, length: extra) }
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let ch = channels
        for t in targets {
            // This track alone, at unity track gain (the track gain still applies afterwards).
            var solo = self
            solo.tracks = [self.tracks[t]]
            solo.withoutMixer()
            solo.tracks[0].gainDB = 0
            solo.tracks[0].isMuted = false
            let plan = PlanCompiler.compile(solo, pool: pool)
            let url = media.appending(path: "\(UUID().uuidString.prefix(8)) echo.wav")
            let writer = try WAVWriter(url: url, options: .init(encoding: .float32, channels: ch, sampleRate: sampleRate))
            var lines = (0..<ch).map { _ in Echo.Line(echo, sampleRate: sampleRate) }
            let total = r.count + Int(extra)
            let block = 65_536
            var done = 0
            while done < total {
                let n = min(block, total - done)
                let at = r.lowerBound + Frame(done)
                // Past the range (the tail) the input is silence.
                let inRange = max(0, min(n, Int(r.upperBound - at)))
                var raw = inRange > 0 ? plan.render(from: at, frames: inRange) : []
                raw += [Float](repeating: 0, count: (n - inRange) * ch)
                var out = [Float](repeating: 0, count: n * ch)
                for c in 0..<ch {
                    let y = lines[c].process(stride(from: c, to: raw.count, by: ch).map { raw[$0] })
                    for i in 0..<n { out[i * ch + c] = y[i] }
                }
                try writer.write(out)
                done += n
            }
            try writer.finish()
            let info = try AudioFileReader.info(at: url)
            let src = SourceRef(name: "\(self.tracks[t].name) (echo)", path: url.path, info: info).withRepairs(repairsCarried(by: self.tracks[t]))
            p.sources.append(src)
            // Replace the track's clips in the range (and its tail) with the bounced clip.
            let span = r.lowerBound..<(r.upperBound + extra)
            p.tracks[t].clips = p.tracks[t].clips.flatMap { c -> [Clip] in
                var parts: [Clip] = []
                let (left, rest) = c.split(at: span.lowerBound)
                if let left { parts.append(left) }
                if let rest { let (_, right) = rest.split(at: span.upperBound); if let right { parts.append(right) } }
                return parts
            }
            p.tracks[t].clips.append(Clip(sourceID: src.id, start: span.lowerBound, length: Frame(span.count)))
            p.tracks[t].clips.sort { $0.start < $1.start }
            let mine = words.filter { $0.track == t }.map { w -> Word in
                var w2 = w.word
                w2.start = w.start - r.lowerBound
                w2.end = w.end - r.lowerBound
                return w2
            }
            if !mine.isEmpty {
                let lang = transcripts.first?.language ?? "und"
                p.setTranscript(SourceTranscript(sourceID: src.id, language: lang, engine: "carried", words: mine))
            }
            p.addCarriedTurns(turnsForBounce(track: t, range: r), to: src.id)
        }
        p.pruneSources()
        return p
    }
}
