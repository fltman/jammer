import Accelerate
import Foundation

/// Applying a repair to the project: the clips in a range get new sources that hold
/// the processed audio (float WAVs in the media folder). The original files are never
/// touched, and undo is the previous project value, like every other edit.
extension Restoration {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case dehum, declip, declick, denoise, dereverb
        /// Taking all the reverberation out sounds unnatural, so that one starts lower.
        public var defaultAmount: Float { self == .dereverb ? 0.7 : 1 }
    }

    /// Reverb reduction is plugged in the same way (the JammerDereverb module), so a build
    /// can leave it out. nil: not available.
    nonisolated(unsafe) public static var dereverber: (@Sendable (_ samples: [Float], _ sampleRate: Double, _ amount: Float) -> [Float])?
    /// The repairs this build can run.
    public static var availableKinds: [Kind] {
        Kind.allCases.filter { ($0 != .dereverb || dereverber != nil) }
    }

    /// Noise reduction is plugged in by the app (DeepFilterNet through libDF, which the
    /// core doesn't link): one channel in, the same length out, aligned. nil: not available.
    nonisolated(unsafe) public static var denoiser: (@Sendable (_ samples: [Float], _ sampleRate: Double, _ amount: Float) -> [Float])?

    public struct Settings: Sendable, Equatable {
        public var kind: Kind
        /// 0…1, blend between the original and the full repair.
        public var amount: Float
        /// De-hum: the mains frequency; nil finds it (50 or 60 Hz, refined).
        public var humFrequency: Double?
        /// De-click: higher finds quieter clicks.
        public var sensitivity: Double

        public init(kind: Kind, amount: Float = 1, humFrequency: Double? = nil, sensitivity: Double = 1) {
            self.kind = kind
            self.amount = amount
            self.humFrequency = humFrequency
            self.sensitivity = sensitivity
        }
    }

    public struct ApplyReport: Sendable, Equatable {
        public var clips = 0
        public var humFrequency: Double?
        public var clippedRuns = 0
        public var clicks = 0
    }

    public enum ApplyError: Error, LocalizedError, Equatable {
        case nothingInRange
        case noHum
        case unreadable(String)
        case notAvailable

        public var errorDescription: String? {
            switch self {
            case .nothingInRange: "There's no audio in that range."
            case .noHum: "No mains hum found (50 or 60 Hz). Give the frequency to remove it anyway."
            case .unreadable(let n): "Can't read \(n)."
            case .notAvailable: "That repair isn't available in this build."
            }
        }
        /// The same message by its key in the app's string catalogue (see `KeyedMessage`).
        public var keyed: KeyedMessage? {
            switch self {
            case .nothingInRange: KeyedMessage("error.apply.nothingInRange")
            case .noHum: KeyedMessage("error.apply.noHum")
            case .unreadable(let n): KeyedMessage("error.apply.unreadable", ["\(n)"])
            case .notAvailable: KeyedMessage("error.apply.notAvailable")
            }
        }
    }

    /// Repairs the clips inside `range` (everything when nil). New files go in `media`.
    /// `progress` gets 0…1; returning false cancels (CancellationError).
    public static func apply(_ settings: Settings, to project: Project, range: Range<Frame>? = nil, tracks: Set<UUID>? = nil,
                             pool: SourcePool, media: URL, progress: (Double) -> Bool = { _ in true }) throws -> (Project, ApplyReport) {
        var p = project
        let r = range ?? 0..<p.length
        guard !r.isEmpty else { throw ApplyError.nothingInRange }
        p.split(at: r.lowerBound)
        p.split(at: r.upperBound)
        let targets = p.tracks.indices.filter { tracks?.contains(p.tracks[$0].id) ?? true }.flatMap { t in
            p.tracks[t].clips.indices.compactMap { c in r.contains(p.tracks[t].clips[c].start) ? (t, c) : nil }
        }
        guard !targets.isEmpty else { throw ApplyError.nothingInRange }
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        var report = ApplyReport()
        let totalFrames = Double(targets.reduce(Frame(0)) { $0 + p.tracks[$1.0].clips[$1.1].length })
        var doneFrames = 0.0
        for (t, c) in targets {
            let clip = p.tracks[t].clips[c]
            guard let src = p.source(clip.sourceID) else { continue }
            let url = media.appending(path: "\(UUID().uuidString.prefix(8)) \(settings.kind.rawValue).wav")
            // Noted as made by Jämmer: only such a file can ever be offered for removal (MediaStorage).
            MediaRegister.made(url, kind: settings.kind.rawValue, in: media)
            let segment = clip.sourceStart..<(clip.sourceStart + clip.length)
            let r = try render(settings, source: src, segment: segment, pool: pool, to: url) { f in
                progress((doneFrames + f * Double(clip.length)) / max(1, totalFrames))
            }
            doneFrames += Double(clip.length)
            report.clips += 1
            report.humFrequency = report.humFrequency ?? r.humFrequency
            report.clippedRuns += r.clippedRuns
            report.clicks += r.clicks
            let info = try AudioFileReader.info(at: url)
            let newSource = SourceRef(name: "\(src.name) (\(settings.kind.rawValue))", path: url.path, info: info, originalPath: src.originalPath ?? src.path)
                .withRepairs((src.repairs ?? []) + [settings.kind.rawValue])
            p.sources.append(newSource)
            // The words heard in that stretch move to the new file, same ids.
            if let tr = p.transcripts.first(where: { $0.sourceID == src.id }) {
                let words = tr.words.filter { $0.end > segment.lowerBound && $0.start < segment.upperBound }.map { w -> Word in
                    var w = w
                    w.start = max(0, w.start - segment.lowerBound)
                    w.end = min(clip.length, w.end - segment.lowerBound)
                    return w
                }
                p.transcripts.append(SourceTranscript(sourceID: newSource.id, language: tr.language, engine: tr.engine, words: words, speakers: tr.speakers))
            }
            // So do the speaker turns.
            p.addCarriedTurns(p.turns(of: src.id, in: segment, length: clip.length), to: newSource.id)
            p.tracks[t].clips[c].sourceID = newSource.id
            p.tracks[t].clips[c].sourceStart = 0
        }
        p.pruneSources()
        return (p, report)
    }

    /// Processes `segment` of a source, all channels, into a float WAV at `url`.
    static func render(_ settings: Settings, source: SourceRef, segment: Range<Frame>, pool: SourcePool, to url: URL,
                       progress: (Double) -> Bool) throws -> ApplyReport {
        let channels = source.info.channels
        let sr = source.info.sampleRate
        let writer = try WAVWriter(url: url, options: .init(encoding: .float32, channels: channels, sampleRate: sr))
        var report = ApplyReport()
        // Clicks and clipping need context on both sides; hum filters carry state.
        let window = Frame(sr * 10)
        // Denoising starts each window with a fresh model, so it gets a second to settle.
        let margin: Frame = switch settings.kind {
        case .dehum: 0
        case .denoise: Frame(sr)
        case .dereverb: Frame(sr)   // the prediction needs the sound that came before
        default: Frame(sr * 0.25)
        }
        let denoise = Restoration.denoiser, dereverb = Restoration.dereverber
        if settings.kind == .denoise, denoise == nil { throw ApplyError.notAvailable }
        if settings.kind == .dereverb, dereverb == nil { throw ApplyError.notAvailable }
        let total = source.info.frames
        func read(_ range: Range<Frame>) throws -> [[Float]] {
            let raw = pool.read(source, from: range.lowerBound, count: range.count)
            guard raw.count == range.count * channels else { throw ApplyError.unreadable(source.name) }
            return (0..<channels).map { ch in stride(from: ch, to: raw.count, by: channels).map { raw[$0] } }
        }
        var dehum: [Dehum] = []
        if settings.kind == .dehum {
            let probe = try read(segment.lowerBound..<min(segment.upperBound, segment.lowerBound + Frame(sr * 20)))
            let mix = (0..<probe[0].count).map { i in probe.reduce(Float(0)) { $0 + $1[i] } / Float(channels) }
            guard let f = settings.humFrequency ?? detectHum(mix, sampleRate: sr)?.frequency else { throw ApplyError.noHum }
            report.humFrequency = f
            dehum = (0..<channels).map { _ in Dehum(frequency: f, sampleRate: sr) }
            // Let the notches settle on the audio just before the stretch, when there is some.
            let pre = max(0, segment.lowerBound - Frame(sr))
            if pre < segment.lowerBound {
                let warm = try read(pre..<segment.lowerBound)
                for ch in 0..<channels { _ = dehum[ch].process(warm[ch]) }
            }
        }
        var clipLevel: Float?
        if settings.kind == .declip {
            // One level for the whole stretch, so every window agrees on what "clipped" means.
            var peak: Float = 0
            var at = segment.lowerBound
            while at < segment.upperBound {
                let n = Int(min(window, segment.upperBound - at))
                let raw = pool.read(source, from: at, count: n)
                var m: Float = 0
                vDSP_maxmgv(raw, 1, &m, vDSP_Length(raw.count))
                peak = max(peak, m)
                at += Frame(n)
            }
            clipLevel = peak
        }
        var at = segment.lowerBound
        while at < segment.upperBound {
            let end = min(segment.upperBound, at + window)
            let lo = max(0, at - margin), hi = min(total, end + margin)
            let chans = try read(lo..<hi)
            var out: [[Float]] = []
            for ch in 0..<channels {
                let x = chans[ch]
                let y: [Float]
                switch settings.kind {
                case .dehum:
                    y = dehum[ch].process(x, amount: settings.amount)
                case .declip:
                    let (o, r) = declip(x, amount: settings.amount, level: clipLevel)
                    y = o
                    report.clippedRuns += r.runs
                case .denoise:
                    y = settings.amount == 0 ? x : denoise!(x, sr, settings.amount)
                case .dereverb:
                    y = settings.amount == 0 ? x : dereverb!(x, sr, settings.amount)
                case .declick:
                    let (o, r) = declick(x, amount: settings.amount, sensitivity: settings.sensitivity)
                    y = o
                    // Count clicks whose start lies in this window's own part.
                    report.clicks += r.clicks.filter { $0.lowerBound >= Int(at - lo) && $0.lowerBound < Int(end - lo) }.count
                }
                out.append(Array(y[Int(at - lo)..<Int(end - lo)]))
            }
            let n = out[0].count
            var interleaved = [Float](repeating: 0, count: n * channels)
            for ch in 0..<channels { for i in 0..<n { interleaved[i * channels + ch] = out[ch][i] } }
            try writer.write(interleaved)
            at = end
            if !progress(Double(at - segment.lowerBound) / Double(max(1, segment.count))) {
                try? writer.finish()
                try? FileManager.default.removeItem(at: url)
                throw CancellationError()
            }
        }
        try writer.finish()
        return report
    }
}


// MARK: - Looking before repairing

extension Restoration {
    /// What the detectors find in a stretch of the timeline, without changing anything.
    public struct Analysis: Sendable, Equatable {
        public var hum: HumEstimate?
        public var clippedRuns: Int
        public var clippedSamples: Int
        public var clipLevel: Float
        public var clicks: Int
        /// Reverberation time in seconds, roughly, when the audio has enough decays to tell.
        public var rt60: Double?
        /// Why there is no reverberation time, when the reason is the audio and not the lack of pauses:
        /// "after_noise_reduction" for sound that has been through `denoise` or `dehum`, whose own
        /// tails after each word read as a room (docs/RESTORATION.md).
        public var reverbUnknown: String?
        /// The level in the pauses, when there are pauses to measure it in.
        public var noiseFloor: NoiseFloor?
        /// Seconds actually examined (long ranges are sampled).
        public var examined: Double
        public var sampled: Bool
        /// Enough reverberation that Reduce Reverb has something to do.
        public var reverberant: Bool { (rt60 ?? 0) >= Restoration.reverbThreshold }
    }
    /// Close-miked speech in a damped room estimates under this; a bare room well over.
    public static let reverbThreshold = 0.3

    /// The timeline mixed to mono over `range`, for the given tracks only.
    public static func mix(_ project: Project, range: Range<Frame>, tracks: Set<UUID>?, pool: SourcePool) -> [Float] {
        var p = project
        if let tracks { p.tracks.removeAll { !tracks.contains($0.id) } }
        let plan = PlanCompiler.compile(p, pool: pool)
        let ch = project.channels
        let raw = plan.render(from: range.lowerBound, frames: range.count)
        return (0..<range.count).map { i in (0..<ch).reduce(Float(0)) { $0 + raw[i * ch + $1] } / Float(ch) }
    }

    /// Runs the detectors. Ranges longer than `budget` seconds are sampled in
    /// evenly spread windows so this stays quick enough to call synchronously.
    public static func analyze(_ project: Project, range: Range<Frame>, tracks: Set<UUID>? = nil, pool: SourcePool,
                               budget: Double = 60) -> Analysis {
        let sr = project.sampleRate
        let budgetFrames = Frame(sr * budget)
        var windows: [Range<Frame>] = [range]
        if Frame(range.count) > budgetFrames {
            let n = 10, w = budgetFrames / Frame(n)
            let step = (Frame(range.count) - w) / Frame(n - 1)
            windows = (0..<n).map { range.lowerBound + Frame($0) * step }.map { $0..<($0 + w) }
        }
        var a = Analysis(hum: nil, clippedRuns: 0, clippedSamples: 0, clipLevel: 0, clicks: 0, examined: 0, sampled: windows.count > 1)
        var humMix: [Float] = []
        var peak: Float = 0
        var mixes: [[Float]] = []
        for w in windows {
            let m = mix(project, range: w, tracks: tracks, pool: pool)
            mixes.append(m)
            if humMix.count < Int(sr * 20) { humMix += m.prefix(Int(sr * 20) - humMix.count) }
            peak = max(peak, m.map(abs).max() ?? 0)
            a.examined += Double(w.count) / sr
        }
        a.hum = detectHum(humMix, sampleRate: sr)
        a.clipLevel = peak
        for m in mixes {
            let runs = clippedRuns(m, level: peak).runs
            a.clippedRuns += runs.count
            a.clippedSamples += runs.reduce(0) { $0 + $1.count }
            a.clicks += detectClicks(m).count
        }
        // The middle of what the windows say; a window without enough decays says nothing.
        let times = mixes.compactMap { estimateRT60($0, sampleRate: sr) }.sorted()
        a.rt60 = times.isEmpty ? nil : times[times.count / 2]
        let repaired = project.tracks.filter { tracks?.contains($0.id) ?? true }.flatMap(\.clips)
            .filter { $0.start < range.upperBound && $0.start + $0.length > range.lowerBound }
            .contains { clip in (project.source(clip.sourceID)?.repairs ?? []).contains { $0 == Kind.denoise.rawValue || $0 == Kind.dehum.rawValue } }
        if repaired {
            a.rt60 = nil
            a.reverbUnknown = "after_noise_reduction"
        }
        // The same for the noise floor, over the pause time of all the windows that had pauses.
        let floors = mixes.compactMap { noiseFloor($0, sampleRate: sr) }.sorted { $0.level < $1.level }
        a.noiseFloor = floors.isEmpty ? nil : NoiseFloor(level: floors[floors.count / 2].level, seconds: floors.reduce(0) { $0 + $1.seconds })
        return a
    }

    /// The repaired audio of `range` (interleaved, project channels) without changing
    /// the project: for A/B listening and for agents. Files go to a temporary folder.
    public static func preview(_ settings: Settings, project: Project, range: Range<Frame>, tracks: Set<UUID>?,
                               pool: SourcePool) throws -> (project: Project, audio: [Float]) {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "jammer-preview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (repaired, _) = try apply(settings, to: project, range: range, tracks: tracks, pool: pool, media: tmp)
        // Render before the files go away; the pool keeps them open by id.
        let plan = PlanCompiler.compile(repaired, pool: pool)
        return (repaired, plan.render(from: range.lowerBound, frames: range.count))
    }
}

extension Restoration.ApplyError: KeyedFailure {}
