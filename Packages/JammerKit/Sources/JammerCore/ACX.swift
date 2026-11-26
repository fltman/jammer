import Foundation

/// One line of a delivery check: what is asked, what was measured, and whether that meets it.
public struct DeliveryRequirement: Sendable, Equatable {
    public var name: String
    /// The requirement in the publisher's own words (quoted as published, in English, in either language).
    public var required: String
    public var measuredSaid: Said
    /// nil: not something a measurement of this one file can decide.
    public var pass: Bool?
    /// How it was measured, or what decided it.
    public var noteSaid: Said?
    public var measured: String { measuredSaid.text }
    public var note: String? { noteSaid?.text }

    public init(name: String, required: String, measured: Said, pass: Bool?, note: Said? = nil) {
        self.name = name; self.required = required; self.measuredSaid = measured; self.pass = pass; self.noteSaid = note
    }

    public var json: [String: Any] {
        var d: [String: Any] = ["name": name, "required": required, "measured": measured, "pass": pass.map { $0 as Any } ?? NSNull()]
        if let note { d["note"] = note }
        return d
    }
}

/// A file measured against ACX's audio submission requirements as ACX publishes them. This says what was
/// measured against which requirement; it is never an approval, which only ACX gives.
///
/// The requirements are quoted from the article "ACX Audio Submission Requirements" at `source`
/// (article date 15 April 2026), read on 16 November 2026. When ACX changes them, this changes with a
/// new reading and a new date; the numbers below are not to be edited from memory.
public enum ACX {
    public static let source = "https://help.acx.com/s/article/acx-audio-submission-requirements"
    public static let articleDate = "2026-04-15"
    public static let readOn = "2026-11-16"
    public static var wording: String { wordingSaid.text }
    public static var wordingSaid: Said { Said("acx.wording", "Measured against ACX's published requirements as read on %@. Only ACX approves a file.", readOn) }

    public static let rmsRange = -23.0 ... -18.0
    public static let peakMax = -3.0
    public static let noiseFloorMax = -60.0
    public static let minBitRate = 192_000
    public static let sampleRate = 44_100.0
    public static let maxSeconds = 120.0 * 60
    public static let roomToneMax = 5.0

    public struct Measured: Sendable {
        /// The document's mix (its `rms`, `samplePeak` and `truePeak` are used).
        public var mix: LoudnessResult
        /// RMS of the pauses, dBFS, and over how many seconds of pause; nil when no pause was found.
        public var noiseFloor: Double?
        public var noiseSeconds = 0.0
        public var channels: Int
        public var sampleRate: Double
        public var seconds: Double
        /// Seconds at the start and at the end that stay under Jämmer's pause level (−45 dBFS).
        public var head: Double
        public var tail: Double
        /// The same mix encoded as the file that would be handed in (MP3, constant bit rate) and decoded
        /// again, with the bit rate it was encoded at; nil when no such file could be made.
        public var encoded: LoudnessResult?
        public var encodedBitRate: Int?
        /// The rate that file was written at (converted from the document's when they differ).
        public var encodedSampleRate: Double?
        /// Why no encoded file was measured.
        public var encodedReason: Said?

        public init(mix: LoudnessResult, noiseFloor: Double?, noiseSeconds: Double = 0, channels: Int, sampleRate: Double, seconds: Double,
                    head: Double, tail: Double, encoded: LoudnessResult? = nil, encodedBitRate: Int? = nil, encodedSampleRate: Double? = nil, encodedReason: Said? = nil) {
            self.encodedSampleRate = encodedSampleRate ?? (encoded != nil ? sampleRate : nil)
            self.mix = mix; self.noiseFloor = noiseFloor; self.noiseSeconds = noiseSeconds; self.channels = channels; self.sampleRate = sampleRate
            self.seconds = seconds; self.head = head; self.tail = tail; self.encoded = encoded; self.encodedBitRate = encodedBitRate; self.encodedReason = encodedReason
        }
    }

    static func db(_ v: Double?) -> Said {
        guard let v, v.isFinite else { return Said("acx.silence", "silence") }
        return Said("acx.db", "%@ dB", values: [Said.n(v, 1)])
    }

    public static func requirements(_ m: Measured) -> [DeliveryRequirement] {
        var out: [DeliveryRequirement] = []
        // The file that is handed in is the encoded one, so that is what counts when there is one.
        let judged = m.encoded ?? m.mix
        let on = m.encoded != nil ? Said("acx.on.mp3", "the MP3 as it decodes")
            : Said("acx.on.mix", "the mix before encoding (%@)", inner: m.encodedReason ?? Said("acx.on.noReason", "no encoded file was measured"))

        let rms = judged.rms
        out.append(.init(name: "rms", required: "Each file needs to fall between the specific volume range of -23dB and -18dB RMS",
                         measured: db(rms), pass: rms.map { rmsRange.contains(($0 * 10).rounded() / 10) } ?? false,
                         note: Said("acx.rms.note", "ACX doesn't say how RMS is to be measured. Here: all samples of the whole file, both channels together, unweighted, relative to full scale; on %@.", inner: on)))

        // "Peak" is read as the sample peak, and the true peak is held to the same figure: a file whose
        // samples pass but whose peaks between the samples don't can still clip in a player.
        let sample = judged.samplePeak, tp = judged.truePeak
        let peakPass = sample <= peakMax && tp <= peakMax
        let peakWhy = peakPass ? Said("acx.peak.both", "Both are at or under −3.")
            : sample > peakMax ? Said("acx.peak.sample", "The sample peak is over −3.")
            : Said("acx.peak.true", "The sample peak passes; the true peak (between the samples) is over −3, and that decided it.")
        out.append(.init(name: "peak", required: "Each file must have peak values no higher than -3dB",
                         measured: Said("acx.peak.measured", "sample peak %1$@, true peak %2$@", inner: [db(sample), db(tp)]), pass: peakPass,
                         note: Said("acx.peak.note", "%1$@ ACX says \"peak\"; Jämmer asks both of the sample peak and of the true peak. On %2$@.", inner: [peakWhy, on])))

        out.append(.init(name: "noiseFloor", required: "Each file must have a noise floor no higher than -60dB RMS",
                         measured: m.noiseFloor.map { Said("acx.noise.measured", "%1$@ dB over %2$@ s of pauses", values: [Said.n($0, 1), Said.n(m.noiseSeconds, 1)]) }
                             ?? Said("acx.noise.none", "no pause found to measure it in"),
                         pass: m.noiseFloor.map { $0 <= noiseFloorMax },
                         note: Said("acx.noise.note", "ACX doesn't say how the noise floor is measured. Here: the RMS of the quietest stretches between the speech (the pauses), on the mix.")))

        let fileRate = m.encodedSampleRate ?? m.sampleRate
        let formatOK = m.encoded != nil && (m.encodedBitRate ?? 0) >= minBitRate && fileRate == sampleRate
        let kbps = "\((m.encodedBitRate ?? 0) / 1_000)"
        out.append(.init(name: "format", required: "Each file must be a 192 kbps or higher CBR, 44.1kHz MP3",
                         measured: m.encoded != nil ? Said("acx.format.mp3", "MP3, %1$@ kbps constant bit rate, %2$@ kHz", values: ["\(kbps)", Said.n(fileRate / 1_000, 1)])
                                                    : Said("acx.format.document", "the document is %@ kHz", values: [Said.n(m.sampleRate / 1_000, 1)]),
                         pass: formatOK,
                         note: m.encoded == nil ? m.encodedReason
                             : fileRate != m.sampleRate ? Said("acx.format.converted", "Encoded here to measure it; export it the same way: MP3, %1$@ kbps, sample rate %2$@ kHz (the document is %3$@ kHz and is converted).", values: ["\(kbps)", Said.n(fileRate / 1_000, 1), Said.n(m.sampleRate / 1_000, 1)])
                             : Said("acx.format.same", "Encoded here to measure it; export it the same way: MP3, %@ kbps.", kbps)))

        out.append(.init(name: "channels", required: "All files must be in the same channel format (all mono or all stereo)",
                         measured: m.channels == 1 ? Said("acx.channels.mono", "mono") : m.channels == 2 ? Said("acx.channels.stereo", "stereo")
                             : Said("acx.channels.many", "%@ channels", "\(m.channels)"),
                         pass: m.channels <= 2 ? nil : false, note: Said("acx.channels.note", "This is about all the files of a book together; one file alone can't show it.")))

        out.append(.init(name: "length", required: "Each file must be no longer than 120 minutes",
                         measured: Said("acx.length", "%1$@ min %2$@ s", "\(Int(m.seconds) / 60)", "\(Int(m.seconds) % 60)"), pass: m.seconds <= maxSeconds))

        let ends = Said("acx.roomTone.note", "Measured as the stretch at each end that stays under −45 dBFS.")
        let short: Said? = m.head < 1 && m.tail < 1 ? Said("acx.roomTone.shortBoth", "Measured as the stretch at each end that stays under −45 dBFS. Under the recommended 1 second at both ends.")
            : m.head < 1 ? Said("acx.roomTone.shortStart", "Measured as the stretch at each end that stays under −45 dBFS. Under the recommended 1 second at the start.")
            : m.tail < 1 ? Said("acx.roomTone.shortEnd", "Measured as the stretch at each end that stays under −45 dBFS. Under the recommended 1 second at the end.") : nil
        out.append(.init(name: "roomTone", required: "Room tone spacing must not exceed 5 seconds (between 1 and 5 seconds at the beginning and end of each file is recommended)",
                         measured: Said("acx.roomTone.measured", "%1$@ s at the start, %2$@ s at the end", values: [Said.n(m.head, 1), Said.n(m.tail, 1)]), pass: m.head <= roomToneMax && m.tail <= roomToneMax,
                         note: short ?? ends))

        out.append(.init(name: "narration", required: "Your submitted audiobook must be narrated by a human unless otherwise authorized",
                         measured: Said("acx.narration.measured", "not something Jämmer measures"), pass: nil,
                         note: Said("acx.narration.note", "ACX also asks for one chapter or section per file with its header read out, separate opening and closing credits, and a retail sample of 5 minutes or less. See the article.")))
        return out
    }
}

/// What bringing a file within ACX's limits did (Audio › Match ACX Requirements, `acx_match`).
public struct ACXMatch: Sendable, Equatable {
    /// Already within RMS and peaks: nothing was changed.
    public var unchanged = false
    public var gainDB = 0.0
    public var rmsBefore = 0.0, rmsAfter = 0.0
    public var samplePeakAfter = 0.0, truePeakAfter = 0.0
    public var limited = false
    public var reductionMaxDB = 0.0
    /// The noise floor as it is after the gain (a gain lifts it by as much); never changed here. nil: not measured.
    public var noiseFloorAfter: Double?
    public var noiseFloorTooHigh: Bool { noiseFloorAfter.map { $0 > ACX.noiseFloorMax } ?? false }
}

extension ACX {
    /// Where an RMS outside the range is brought: the middle of it.
    public static let rmsTarget = -20.0
    /// What the limiter holds the peaks at: under −3 with room for an MP3 encoder, which lifts peaks a little.
    public static let limiterCeiling = -3.5

    /// Within ACX's loudness and peak limits as judged (RMS to a tenth of a dB, sample and true peak).
    public static func within(_ m: LoudnessResult) -> Bool {
        guard let rms = m.rms else { return false }
        return rmsRange.contains((rms * 10).rounded() / 10) && m.samplePeak <= peakMax && m.truePeak <= peakMax
    }
}

extension Project {
    /// Brings `range` within ACX's loudness and peaks, as one change (the coordinator, 2026-11-26): the RMS into
    /// −23…−18 dB (to the middle when outside it), the peaks at or under −3 dB, by the limiter where a gain alone
    /// can't (at −3.5 dBTP, with the gain corrected for what the limiter takes, up to three times). A file already
    /// within both is left as it is. The noise floor is only measured and said (`noiseFloorBefore`, lifted by the
    /// gain), never touched: over −60 dB the answer points to Reduce Noise, a choice of its own. nil: silent.
    public func matchingACX(range r: Range<Frame>, noiseFloorBefore: Double?, pool: SourcePool?, media: URL?,
                            measure: (Project, Range<Frame>) -> LoudnessResult) throws -> (Project, ACXMatch)? {
        let m = measure(self, r)
        guard let rms = m.rms, rms.isFinite else { return nil }
        var out = ACXMatch()
        out.rmsBefore = rms
        if ACX.within(m) {
            out.unchanged = true
            out.rmsAfter = rms; out.samplePeakAfter = m.samplePeak; out.truePeakAfter = m.truePeak
            out.noiseFloorAfter = noiseFloorBefore
            return (self, out)
        }
        let rmsOK = ACX.rmsRange.contains((rms * 10).rounded() / 10)
        var gain = rmsOK ? 0 : ACX.rmsTarget - rms
        // A gain alone, when the peaks leave room for it.
        if max(m.truePeak, m.samplePeak) + gain <= ACX.limiterCeiling {
            var p = self
            try p.changeGain(r, by: (gain * 100).rounded() / 100)
            let after = measure(p, r)
            out.gainDB = (gain * 100).rounded() / 100
            out.rmsAfter = after.rms ?? rms + gain; out.samplePeakAfter = after.samplePeak; out.truePeakAfter = after.truePeak
            out.noiseFloorAfter = noiseFloorBefore.map { $0 + out.gainDB }
            return (p, out)
        }
        // The peaks are in the way: the limiter holds them, and the gain makes up what it takes.
        guard let pool, let media else { throw ACXMatchError.needsRender }
        let target = rmsOK ? rms : ACX.rmsTarget
        var best: (Project, ACXMatch)?
        var written: [URL] = []
        for _ in 0..<3 {
            var p = self
            if gain != 0 { try p.changeGain(r, by: (gain * 100).rounded() / 100) }
            let (limited, report) = try p.limiting(Limiter(ceilingDB: ACX.limiterCeiling), range: r, pool: pool, media: media)
            let after = measure(limited, r)
            guard let reached = after.rms else { break }
            var now = out
            now.gainDB = (gain * 100).rounded() / 100
            now.rmsAfter = reached; now.samplePeakAfter = after.samplePeak; now.truePeakAfter = after.truePeak
            now.limited = true; now.reductionMaxDB = report.reductionMaxDB
            now.noiseFloorAfter = noiseFloorBefore.map { $0 + now.gainDB }
            // The earlier try's files are not played by anything: take them away.
            let mine = Set(limited.sources.map(\.path)).subtracting(sources.map(\.path))
            for u in written where !mine.contains(u.path) { try? FileManager.default.removeItem(at: u) }
            written = mine.map { URL(fileURLWithPath: $0) }
            best = (limited, now)
            if ACX.rmsRange.contains((reached * 10).rounded() / 10) && abs(target - reached) <= 0.5 { break }
            gain += target - reached
        }
        return best
    }
}

public enum ACXMatchError: Error, LocalizedError, Equatable, KeyedFailure {
    case needsRender
    public var errorDescription: String? { said.text }
    public var keyed: KeyedMessage? { said.keyed }
    private var said: Said { Said("error.acx.needsRender", "The peaks need the limiter, which needs the app to render audio.") }
}
