import Foundation

/// One line of a delivery check: what is asked, what was measured, and whether that meets it.
public struct DeliveryRequirement: Sendable, Equatable {
    public var name: String
    /// The requirement in the publisher's own words.
    public var required: String
    public var measured: String
    /// nil: not something a measurement of this one file can decide.
    public var pass: Bool?
    /// How it was measured, or what decided it.
    public var note: String?

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
    public static var wording: String { "Measured against ACX's published requirements as read on \(readOn). Only ACX approves a file." }

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
        public var encodedReason: String?

        public init(mix: LoudnessResult, noiseFloor: Double?, noiseSeconds: Double = 0, channels: Int, sampleRate: Double, seconds: Double,
                    head: Double, tail: Double, encoded: LoudnessResult? = nil, encodedBitRate: Int? = nil, encodedSampleRate: Double? = nil, encodedReason: String? = nil) {
            self.encodedSampleRate = encodedSampleRate ?? (encoded != nil ? sampleRate : nil)
            self.mix = mix; self.noiseFloor = noiseFloor; self.noiseSeconds = noiseSeconds; self.channels = channels; self.sampleRate = sampleRate
            self.seconds = seconds; self.head = head; self.tail = tail; self.encoded = encoded; self.encodedBitRate = encodedBitRate; self.encodedReason = encodedReason
        }
    }

    static func db(_ v: Double?) -> String { v.map { $0.isFinite ? String(format: "%.1f dB", $0) : "silence" } ?? "silence" }

    public static func requirements(_ m: Measured) -> [DeliveryRequirement] {
        var out: [DeliveryRequirement] = []
        // The file that is handed in is the encoded one, so that is what counts when there is one.
        let judged = m.encoded ?? m.mix
        let on = m.encoded != nil ? "the MP3 as it decodes" : "the mix before encoding (\(m.encodedReason ?? "no encoded file was measured"))"

        let rms = judged.rms
        out.append(.init(name: "rms", required: "Each file needs to fall between the specific volume range of -23dB and -18dB RMS",
                         measured: db(rms), pass: rms.map { rmsRange.contains(($0 * 10).rounded() / 10) } ?? false,
                         note: "ACX doesn't say how RMS is to be measured. Here: all samples of the whole file, both channels together, unweighted, relative to full scale; on \(on)."))

        // "Peak" is read as the sample peak, and the true peak is held to the same figure: a file whose
        // samples pass but whose peaks between the samples don't can still clip in a player.
        let sample = judged.samplePeak, tp = judged.truePeak
        let peakPass = sample <= peakMax && tp <= peakMax
        out.append(.init(name: "peak", required: "Each file must have peak values no higher than -3dB",
                         measured: "sample peak \(db(sample)), true peak \(db(tp))", pass: peakPass,
                         note: (peakPass ? "Both are at or under −3." : sample > peakMax ? "The sample peak is over −3." : "The sample peak passes; the true peak (between the samples) is over −3, and that decided it.")
                             + " ACX says \"peak\"; Jämmer asks both of the sample peak and of the true peak. On \(on)."))

        out.append(.init(name: "noiseFloor", required: "Each file must have a noise floor no higher than -60dB RMS",
                         measured: m.noiseFloor.map { String(format: "%.1f dB over %.1f s of pauses", $0, m.noiseSeconds) } ?? "no pause found to measure it in",
                         pass: m.noiseFloor.map { $0 <= noiseFloorMax },
                         note: "ACX doesn't say how the noise floor is measured. Here: the RMS of the quietest stretches between the speech (the pauses), on the mix."))

        let fileRate = m.encodedSampleRate ?? m.sampleRate
        let formatOK = m.encoded != nil && (m.encodedBitRate ?? 0) >= minBitRate && fileRate == sampleRate
        out.append(.init(name: "format", required: "Each file must be a 192 kbps or higher CBR, 44.1kHz MP3",
                         measured: m.encoded != nil ? "MP3, \((m.encodedBitRate ?? 0) / 1_000) kbps constant bit rate, \(String(format: "%.1f", fileRate / 1_000)) kHz"
                                                    : "the document is \(String(format: "%.1f", m.sampleRate / 1_000)) kHz",
                         pass: formatOK,
                         note: m.encoded != nil ? "Encoded here to measure it; export it the same way: MP3, \((m.encodedBitRate ?? 0) / 1_000) kbps"
                             + (fileRate != m.sampleRate ? String(format: ", sample rate %.1f kHz (the document is %.1f kHz and is converted).", fileRate / 1_000, m.sampleRate / 1_000) : ".")
                             : m.encodedReason))

        out.append(.init(name: "channels", required: "All files must be in the same channel format (all mono or all stereo)",
                         measured: m.channels == 1 ? "mono" : m.channels == 2 ? "stereo" : "\(m.channels) channels",
                         pass: m.channels <= 2 ? nil : false, note: "This is about all the files of a book together; one file alone can't show it."))

        out.append(.init(name: "length", required: "Each file must be no longer than 120 minutes",
                         measured: String(format: "%d min %d s", Int(m.seconds) / 60, Int(m.seconds) % 60), pass: m.seconds <= maxSeconds))

        out.append(.init(name: "roomTone", required: "Room tone spacing must not exceed 5 seconds (between 1 and 5 seconds at the beginning and end of each file is recommended)",
                         measured: String(format: "%.1f s at the start, %.1f s at the end", m.head, m.tail), pass: m.head <= roomToneMax && m.tail <= roomToneMax,
                         note: "Measured as the stretch at each end that stays under −45 dBFS."
                             + (m.head < 1 || m.tail < 1 ? " Under the recommended 1 second at \(m.head < 1 && m.tail < 1 ? "both ends" : m.head < 1 ? "the start" : "the end")." : "")))

        out.append(.init(name: "narration", required: "Your submitted audiobook must be narrated by a human unless otherwise authorized",
                         measured: "not something Jämmer measures", pass: nil,
                         note: "ACX also asks for one chapter or section per file with its header read out, separate opening and closing credits, and a retail sample of 5 minutes or less. See the article."))
        return out
    }
}
