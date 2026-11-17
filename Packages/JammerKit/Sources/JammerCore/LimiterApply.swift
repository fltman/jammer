import Foundation

public struct LimitReport: Sendable, Equatable {
    public var tracks = 0
    public var truePeakBeforeDB = 0.0
    public var truePeakAfterDB = 0.0
    public var reductionMaxDB = 0.0
    public var limitedSeconds = 0.0
    public var ceilingDB = 0.0
    public var marginDB = 0.0
    /// True when a limited track has plugins: they come after the limiter, so what they do to the
    /// peaks is not in these figures.
    public var beforePlugins = false
}

extension Project {
    /// A true-peak limiter on `range` of the given tracks (nil: all), bounced in place like `applyingEcho`.
    /// The gain is found on the mix of those tracks as they sound together (their levels and mutes, not
    /// their plugins) and the same gain goes on each of them, so their sum is the limited mix; limiting
    /// them one by one would not bound the sum. Each track's clips in the range are replaced by one new
    /// file, sample for sample where the old audio was: the limiter adds no delay. Where the gain is 1
    /// the new file is the old audio bit for bit, and outside the range nothing is touched.
    ///
    /// The promise is kept by measuring: the result is read as the meter reads it, and the limiter aims
    /// lower and runs again if it came out over the ceiling. Nothing is held in memory but a few blocks.
    public func limiting(_ settings: Limiter, range: Range<Frame>, tracks only: Set<UUID>? = nil,
                         pool: SourcePool, media: URL) throws -> (Project, LimitReport) {
        try settings.validate()
        let r = range.clamped(to: 0..<length)
        let targets = tracks.indices.filter { t in
            (only?.contains(tracks[t].id) ?? true) && tracks[t].clips.contains { $0.start < r.upperBound && $0.end > r.lowerBound }
        }
        guard !r.isEmpty, !targets.isEmpty else { throw EffectError.nothingInRange }
        let ch = channels, total = r.count, block = 65_536

        // What is listened to: the chosen tracks together.
        var together = self
        together.tracks = targets.map { tracks[$0] }
        // Not through the master: its limiter would already have taken the peaks this one is asked to find.
        together.master = Master()
        for i in together.tracks.indices { together.tracks[i].inserts = [] }
        let mix = PlanCompiler.compile(together, pool: pool)
        var report = LimitReport()
        report.tracks = targets.count
        report.ceilingDB = settings.ceilingDB
        // The plugins, on the tracks and on the buses, come after what the limiter makes.
        report.beforePlugins = targets.contains { !tracks[$0].inserts.isEmpty } || buses.contains { !$0.inserts.isEmpty }

        var before = Limiter.PeakMeter(channels: ch, sampleRate: sampleRate)
        var done = 0
        while done < total {
            let n = min(block, total - done)
            before.process(mix.render(from: r.lowerBound + Frame(done), frames: n))
            done += n
        }
        report.truePeakBeforeDB = before.peakDB
        guard before.peakDB > settings.ceilingDB else {
            throw LimiterError.nothingToDo(Said("limiter.nothingToDo", "The true peak there is %1$@ dBTP, already at or under the ceiling of %2$@. Nothing was changed.", values: [Said.n(before.peakDB, 1), Said.n(settings.ceilingDB, 1)]))
        }

        // Each track alone, at unity and without its plugins: its level and its plugins still apply afterwards.
        let solos = targets.map { t -> RenderPlan in
            var solo = self
            solo.tracks = [tracks[t]]
            solo.withoutMixer()
            solo.tracks[0].gainDB = 0
            solo.tracks[0].isMuted = false
            solo.tracks[0].inserts = []
            return PlanCompiler.compile(solo, pool: pool)
        }
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        var urls: [URL] = []
        var met = false
        for margin in Limiter.margins {
            for u in urls { try? FileManager.default.removeItem(at: u) }
            urls = targets.map { _ in media.appending(path: "\(UUID().uuidString.prefix(8)) limit.wav") }
            for u in urls { MediaRegister.made(u, kind: "limit", in: media) }
            let writers = try urls.map { try WAVWriter(url: $0, options: .init(encoding: .float32, channels: ch, sampleRate: sampleRate)) }
            var limiter = try Limiter.Processor(settings, channels: ch, sampleRate: sampleRate, marginDB: margin)
            var after = Limiter.PeakMeter(channels: ch, sampleRate: sampleRate)
            var written = 0
            // The gains come out behind what has been listened to; each batch is put on the same frames of every track.
            func put(_ gains: [Float]) throws {
                var at = 0
                while at < gains.count {
                    let n = min(block, gains.count - at)
                    let from = r.lowerBound + Frame(written)
                    func scaled(_ raw: [Float]) -> [Float] {
                        var x = raw
                        for i in 0..<n where gains[at + i] < 1 { for c in 0..<ch { x[i * ch + c] *= gains[at + i] } }
                        return x
                    }
                    for (i, solo) in solos.enumerated() { try writers[i].write(scaled(solo.render(from: from, frames: n))) }
                    after.process(scaled(mix.render(from: from, frames: n)))
                    written += n
                    at += n
                }
            }
            done = 0
            while done < total {
                let n = min(block, total - done)
                try put(limiter.gains(mix.render(from: r.lowerBound + Frame(done), frames: n)))
                done += n
            }
            try put(limiter.finishGains())
            for w in writers { try w.finish() }
            guard written == total else { throw LimiterError.ceilingNotMet(Said("limiter.limiter_lost_count_audio", "The limiter lost count of the audio (%1$@ of %2$@ frames). Nothing was changed.", "\(written)", "\(total)")) }
            report.truePeakAfterDB = after.peakDB
            report.reductionMaxDB = limiter.stats.reductionMaxDB
            report.limitedSeconds = Double(limiter.stats.limitedFrames) / sampleRate
            report.marginDB = margin
            if after.peakDB <= settings.ceilingDB { met = true; break }
        }
        guard met else {
            for u in urls { try? FileManager.default.removeItem(at: u) }
            throw LimiterError.ceilingNotMet(Said("limiter.ceilingNotMet.unchanged", "The limiter couldn't keep the true peak under %1$@ dBTP (it came to %2$@). Try a longer lookahead. Nothing was changed.", values: [Said.n(settings.ceilingDB, 1), Said.n(report.truePeakAfterDB, 2)]))
        }

        var p = self
        let words = placedWords(in: r)
        for (i, t) in targets.enumerated() {
            let src = SourceRef(name: "\(tracks[t].name) (limited)", path: urls[i].path, info: try AudioFileReader.info(at: urls[i]))
                .withRepairs(repairsCarried(by: tracks[t]))
            p.sources.append(src)
            p.tracks[t].clips = p.tracks[t].clips.flatMap { c -> [Clip] in
                var parts: [Clip] = []
                let (left, rest) = c.split(at: r.lowerBound)
                if let left { parts.append(left) }
                if let rest { let (_, right) = rest.split(at: r.upperBound); if let right { parts.append(right) } }
                return parts
            }
            p.tracks[t].clips.append(Clip(sourceID: src.id, start: r.lowerBound, length: Frame(r.count)))
            p.tracks[t].clips.sort { $0.start < $1.start }
            let mine = words.filter { $0.track == t }.map { w -> Word in
                var w2 = w.word
                w2.start = w.start - r.lowerBound
                w2.end = w.end - r.lowerBound
                return w2
            }
            if !mine.isEmpty { p.setTranscript(SourceTranscript(sourceID: src.id, language: transcripts.first?.language ?? "und", engine: "carried", words: mine)) }
            p.addCarriedTurns(turnsForBounce(track: t, range: r), to: src.id)
        }
        p.pruneSources()
        return (p, report)
    }
}
