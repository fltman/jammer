import Accelerate
import Foundation

/// What a track played before `duck` replaced it with the ducked file.
public struct DuckOrigin: Codable, Hashable, Sendable {
    public var clips: [Clip]
    /// The one clip the track was given; while the track is exactly this, `clips` is its original.
    public var bounce: Clip
}

public struct DuckReport: Sendable, Equatable {
    public var tracks = 0
    /// Stretches the tracks are held down over (speech, with the pauses shorter than the hold).
    public var regions = 0
    public var duckedSeconds = 0.0
    /// "turns" when the speakers' turns said where the speech is, "level" when the level did.
    public var trigger = "level"
    /// Tracks whose earlier ducking was replaced (not added to).
    public var replaced = 0
}

public enum DuckError: Error, LocalizedError, Equatable {
    case notFound(String), overlap(String), needsTracks, noSpeech

    public var reason: String {
        switch self {
        case .notFound: "not_found"
        case .overlap: "bad_request"
        case .needsTracks: "needs_tracks"
        case .noSpeech: "no_speech"
        }
    }
    public var errorDescription: String? {
        switch self {
        case .notFound(let id): "no track with id \(id)."
        case .overlap(let name): "\(name) can't be both ducked and ducked under: `under` must not name a track in `tracks`."
        case .needsTracks: "there is no other track with sound to duck under."
        case .noSpeech: "the tracks to duck under never reach the threshold in that range, so nothing was changed."
        }
    }
}

public enum Ducking {
    public struct Settings: Sendable, Equatable {
        public var amountDB = -12.0
        /// Momentary loudness (LUFS) over which the controlling tracks count as speaking.
        public var threshold = -40.0
        public var attackMs = 150.0, releaseMs = 600.0, holdMs = 400.0
        /// How long before the speech the ducking starts. Nil: the attack, so it is down when the first word comes.
        public var lookaheadMs: Double?
        /// On top of an earlier ducking instead of in its place.
        public var stack = false
        public init() {}
    }

    /// Where the sound is over `threshold` LUFS: 100 ms blocks, K-weighted, each judged with its two
    /// neighbours (so 300 ms, centred, and a word isn't found late). `read` gives interleaved audio
    /// for a range of frames; it is asked in order, in pieces.
    static func loudRanges(length: Int, channels: Int, sampleRate: Double, threshold: Double,
                           read: (Range<Int>) -> [Float]) -> [Range<Int>] {
        let block = max(1, Int((sampleRate * 0.1).rounded()))
        guard length >= block else { return [] }
        let setup = vDSP_biquad_CreateSetupD(LoudnessMeter.kWeighting(sampleRate), 2)!
        defer { vDSP_biquad_DestroySetupD(setup) }
        var delays = [[Double]](repeating: [Double](repeating: 0, count: 6), count: channels)
        var energies: [Double] = []
        let blocksPerPiece = 100
        var at = 0
        while at + block <= length {
            let n = min(blocksPerPiece, (length - at) / block) * block
            let raw = read(at..<(at + n))
            var sums = [Double](repeating: 0, count: n / block)
            for c in 0..<channels {
                var x = [Double](repeating: 0, count: n), y = [Double](repeating: 0, count: n)
                for i in 0..<n { x[i] = Double(raw[i * channels + c]) }
                vDSP_biquadD(setup, &delays[c], x, 1, &y, 1, vDSP_Length(n))
                for b in 0..<(n / block) {
                    var e = 0.0
                    y.withUnsafeBufferPointer { vDSP_svesqD($0.baseAddress! + b * block, 1, &e, vDSP_Length(block)) }
                    sums[b] += e / Double(block)
                }
            }
            energies += sums
            at += n
        }
        let limit = pow(10, (threshold + 0.691) / 10)
        var out: [Range<Int>] = []
        var start: Int?
        for b in 0...energies.count {
            var loud = false
            if b < energies.count {
                let lo = max(0, b - 1), hi = min(energies.count - 1, b + 1)
                loud = energies[lo...hi].reduce(0, +) / Double(hi - lo + 1) > limit
            }
            if loud, start == nil { start = b }
            if !loud, let s = start { out.append((s * block)..<(b * block)); start = nil }
        }
        return out
    }

    /// The stretches to hold the sound down over: each range kept `hold` frames longer, joined where they then meet.
    static func regions(_ ranges: [Range<Int>], hold: Int) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) where !r.isEmpty {
            let held = r.lowerBound..<(r.upperBound + hold)
            if let last = out.last, held.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound..<max(last.upperBound, held.upperBound)
            } else {
                out.append(held)
            }
        }
        return out
    }

    /// How far down the sound is at each frame of `span`, 0 (untouched) to 1 (all of the amount): down over
    /// `attack` frames starting `lookahead` before each region, held through it, up over `release` after.
    static func depth(_ span: Range<Int>, regions: [Range<Int>], attack: Int, release: Int, lookahead: Int) -> [Float] {
        var w = [Float](repeating: 0, count: span.count)
        let attack = max(1, attack), release = max(1, release)
        for r in regions {
            let down = r.lowerBound - lookahead, full = down + attack
            guard down < span.upperBound, r.upperBound + release > span.lowerBound else { continue }
            for i in max(span.lowerBound, down)..<min(span.upperBound, r.upperBound + release) {
                let v: Float
                if i < full { v = Float(i - down) / Float(attack) }
                else if i < r.upperBound { v = 1 }
                else { v = 1 - Float(i - r.upperBound) / Float(release) }
                // A release that the next attack cuts into: whichever holds it further down.
                if v > w[i - span.lowerBound] { w[i - span.lowerBound] = min(1, v) }
            }
        }
        return w
    }
}

extension Project {
    /// Lowers `wanted` while the tracks in `under` have speech, and lets them up in the pauses. Each
    /// ducked track plays from a new file over its extent; outside the ducked stretches and their ramps
    /// that file is the old sound bit for bit. A track that still plays the file of an earlier ducking
    /// is ducked afresh from what it played before, unless `settings.stack`.
    public func ducking(tracks wanted: [UUID], under: [UUID]? = nil, settings: Ducking.Settings = .init(), range: Range<Frame>? = nil,
                        pool: SourcePool, media: URL) throws -> (Project, DuckReport) {
        var targets: [Int] = []
        for id in wanted {
            guard let t = tracks.firstIndex(where: { $0.id == id }) else { throw DuckError.notFound(id.uuidString) }
            if !targets.contains(t) { targets.append(t) }
        }
        var controls: [Int] = []
        if let under {
            for id in under {
                guard let t = tracks.firstIndex(where: { $0.id == id }) else { throw DuckError.notFound(id.uuidString) }
                guard !targets.contains(t) else { throw DuckError.overlap(tracks[t].name) }
                if !controls.contains(t) { controls.append(t) }
            }
        } else {
            controls = tracks.indices.filter { !targets.contains($0) }
        }
        controls = controls.filter { !tracks[$0].isMuted && !tracks[$0].clips.isEmpty }
        targets = targets.filter { !tracks[$0].clips.isEmpty }
        guard !targets.isEmpty, !controls.isEmpty else { throw DuckError.needsTracks }

        // From what the tracks played before an earlier ducking, when they still play its file.
        var base = self
        var report = DuckReport()
        for t in targets {
            if !settings.stack, let o = tracks[t].ducked, tracks[t].clips == [o.bounce],
               o.clips.allSatisfy({ c in sources.contains { $0.id == c.sourceID } }) {
                base.tracks[t].clips = o.clips
                report.replaced += 1
            }
        }
        let total = Int(base.length)
        let span = range.map { max(0, Int($0.lowerBound))..<min(total, Int($0.upperBound)) } ?? 0..<total
        guard !span.isEmpty else { throw DuckError.noSpeech }

        // Where the speech is: the speakers' turns on the controlling tracks, or their level.
        var speech = base.placedTurns().filter { controls.contains($0.track) }.map { Int($0.start)..<Int($0.end) }
        if speech.isEmpty {
            var mix = base
            mix.tracks = controls.map { base.tracks[$0] }
            mix.master = Master()
            for i in mix.tracks.indices { mix.tracks[i].inserts = [] }
            let plan = PlanCompiler.compile(mix, pool: pool)
            speech = Ducking.loudRanges(length: total, channels: channels, sampleRate: sampleRate, threshold: settings.threshold) {
                plan.render(from: Frame($0.lowerBound), frames: $0.count)
            }
        } else {
            report.trigger = "turns"
        }
        speech = speech.compactMap { r in
            let lo = max(r.lowerBound, span.lowerBound), hi = min(r.upperBound, span.upperBound)
            return hi > lo ? lo..<hi : nil
        }
        let regions = Ducking.regions(speech, hold: Int(frames(settings.holdMs / 1_000)))
        guard !regions.isEmpty else { throw DuckError.noSpeech }
        let attack = Int(frames(settings.attackMs / 1_000)), release = Int(frames(settings.releaseMs / 1_000))
        let lookahead = Int(frames((settings.lookaheadMs ?? settings.attackMs) / 1_000))

        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        var p = base
        let words = base.placedWords()
        for t in targets {
            let first = Int(base.tracks[t].clips.map(\.start).min()!), end = Int(base.tracks[t].end)
            var solo = base
            solo.tracks = [base.tracks[t]]
            solo.withoutMixer()
            solo.tracks[0].gainDB = 0
            solo.tracks[0].isMuted = false
            solo.tracks[0].inserts = []
            let plan = PlanCompiler.compile(solo, pool: pool)
            let url = media.appending(path: "\(UUID().uuidString.prefix(8)) duck.wav")
            let w = try WAVWriter(url: url, options: .init(encoding: .float32, channels: channels, sampleRate: sampleRate))
            let piece = Int(sampleRate * 10)
            var at = first
            while at < end {
                let n = min(piece, end - at)
                var raw = plan.render(from: Frame(at), frames: n)
                let depth = Ducking.depth(at..<(at + n), regions: regions, attack: attack, release: release, lookahead: lookahead)
                for i in 0..<n where depth[i] > 0 {
                    let g = Float(pow(10, settings.amountDB * Double(depth[i]) / 20))
                    for c in 0..<channels { raw[i * channels + c] *= g }
                }
                try w.write(raw)
                at += n
            }
            try w.finish()
            let src = SourceRef(name: "\(base.tracks[t].name) (ducked)", path: url.path, info: try AudioFileReader.info(at: url))
                .withRepairs(base.repairsCarried(by: base.tracks[t]))
            p.sources.append(src)
            let mine = words.filter { $0.track == t }.map { w -> Word in var w2 = w.word; w2.start = w.start - Frame(first); w2.end = w.end - Frame(first); return w2 }
            if !mine.isEmpty { p.setTranscript(SourceTranscript(sourceID: src.id, language: transcripts.first?.language ?? "und", engine: "carried", words: mine)) }
            p.addCarriedTurns(base.turnsForBounce(track: t, range: Frame(first)..<Frame(end)), to: src.id)
            let clip = Clip(sourceID: src.id, start: Frame(first), length: Frame(end - first))
            // With `stack` on top of an earlier ducking, the original stays the one from before that.
            let origin = settings.stack ? (tracks[t].ducked.flatMap { tracks[t].clips == [$0.bounce] ? $0.clips : nil } ?? base.tracks[t].clips) : base.tracks[t].clips
            p.tracks[t].clips = [clip]
            p.tracks[t].ducked = DuckOrigin(clips: origin, bounce: clip)
        }
        p.pruneSources()
        report.tracks = targets.count
        report.regions = regions.count
        report.duckedSeconds = (Double(regions.reduce(0) { $0 + $1.count }) / sampleRate * 100).rounded() / 100
        return (p, report)
    }
}
