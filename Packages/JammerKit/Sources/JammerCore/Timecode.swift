import Foundation

/// SMPTE timecode: a place on the timeline as hours, minutes, seconds and picture frames, at the picture's
/// frame rate, counted from the timecode the timeline starts at (a film's sound often starts at 01:00:00:00).
///
/// The rates are the ones film and television use. At 29.97 and 59.94 there are two ways of counting:
/// non-drop (every frame number used, so the clock runs 3.6 s an hour slow against real time) and
/// drop-frame (frame numbers 0 and 1, or 0 to 3 at 59.94, are skipped at the start of every minute that
/// isn't a tenth minute, so the clock keeps real time; written with a semicolon before the frames).
/// 23.976 has no drop-frame counting in the standard and gets none here.
public struct Timecode: Sendable, Equatable, Codable {
    public enum Rate: String, Sendable, CaseIterable, Codable {
        case fps23976 = "23.976", fps24 = "24", fps25 = "25", fps2997 = "29.97", fps2997drop = "29.97df", fps30 = "30"
        case fps50 = "50", fps5994 = "59.94", fps5994drop = "59.94df", fps60 = "60"

        /// Frame numbers in a second of timecode.
        public var base: Int {
            switch self {
            case .fps23976, .fps24: 24
            case .fps25: 25
            case .fps2997, .fps2997drop, .fps30: 30
            case .fps50: 50
            case .fps5994, .fps5994drop, .fps60: 60
            }
        }
        /// Picture frames a second of real time, as a fraction (the NTSC rates are 1000/1001 of the whole number).
        public var perSecond: (num: Int, den: Int) {
            switch self {
            case .fps23976: (24_000, 1_001)
            case .fps2997, .fps2997drop: (30_000, 1_001)
            case .fps5994, .fps5994drop: (60_000, 1_001)
            default: (base, 1)
            }
        }
        public var dropsFrames: Bool { self == .fps2997drop || self == .fps5994drop }
        /// Frame numbers skipped at the start of a minute that isn't a tenth minute.
        var dropped: Int { dropsFrames ? base / 15 : 0 }
    }

    public var hours: Int, minutes: Int, seconds: Int, frames: Int
    public var rate: Rate

    public init(hours: Int, minutes: Int, seconds: Int, frames: Int, rate: Rate) {
        self.hours = hours; self.minutes = minutes; self.seconds = seconds; self.frames = frames; self.rate = rate
    }

    /// Whether the numbers are a timecode that exists at the rate (a dropped frame number doesn't).
    public var isValid: Bool {
        guard (0..<24).contains(hours), (0..<60).contains(minutes), (0..<60).contains(seconds), (0..<rate.base).contains(frames) else { return false }
        if rate.dropsFrames, seconds == 0, minutes % 10 != 0, frames < rate.dropped { return false }
        return true
    }

    /// How many picture frames after 00:00:00:00 this timecode is.
    public var pictureFrames: Int {
        let base = rate.base
        var n = ((hours * 60 + minutes) * 60 + seconds) * base + frames
        if rate.dropsFrames {
            let totalMinutes = hours * 60 + minutes
            n -= rate.dropped * (totalMinutes - totalMinutes / 10)
        }
        return n
    }

    /// The timecode of the picture frame `n` frames after 00:00:00:00 (it wraps at 24 hours).
    public init(pictureFrames n: Int, rate: Rate) {
        let base = rate.base
        var n = n
        let day = rate.dropsFrames ? (24 * 60 * 60 * base - rate.dropped * (24 * 60 - 24 * 6)) : 24 * 60 * 60 * base
        n = ((n % day) + day) % day
        if rate.dropsFrames {
            // Ten minutes of drop-frame hold 10 × 60 × base − 9 × dropped frames; the first minute of them is whole.
            let d = rate.dropped, perMinute = 60 * base - d, perTen = 10 * 60 * base - 9 * d
            let tens = n / perTen, rest = n % perTen
            n += 9 * d * tens
            if rest >= 60 * base { n += d * (1 + (rest - 60 * base) / perMinute) }
        }
        self.init(hours: n / (3_600 * base), minutes: n / (60 * base) % 60, seconds: n / base % 60, frames: n % base, rate: rate)
    }

    /// "01:00:10:12", or "01:00:10;12" where frames are dropped.
    public var text: String {
        String(format: "%02d:%02d:%02d%@%02d", hours, minutes, seconds, rate.dropsFrames ? ";" : ":", frames)
    }

    /// Reads "hh:mm:ss:ff" (a semicolon or a full stop before the frames is taken too). nil when it isn't
    /// a timecode that exists at the rate.
    public init?(_ text: String, rate: Rate) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(whereSeparator: { ":;.".contains($0) }).map(String.init)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.count <= 2 && $0.allSatisfy(\.isNumber) }) else { return nil }
        let n = parts.compactMap(Int.init)
        guard n.count == 4 else { return nil }
        self.init(hours: n[0], minutes: n[1], seconds: n[2], frames: n[3], rate: rate)
        guard isValid else { return nil }
    }
}

/// A document's timecode: the picture's rate, and the timecode at the start of the timeline.
public struct TimecodeSettings: Sendable, Equatable, Codable, Hashable {
    public var rate: Timecode.Rate
    /// The timecode of the timeline's first frame, as picture frames after 00:00:00:00.
    public var startFrames: Int
    public init(rate: Timecode.Rate, startFrames: Int = 0) {
        self.rate = rate
        self.startFrames = startFrames
    }
    public var start: Timecode { Timecode(pictureFrames: startFrames, rate: rate) }

    /// The timecode at an audio frame of the timeline: the picture frame the audio frame falls in.
    public func timecode(at frame: Frame, sampleRate: Double) -> Timecode {
        let r = rate.perSecond
        // The picture frame the audio frame falls in: audio frames × (num/den) / sampleRate, rounded down.
        // (A hair is added first: 1 920 audio frames at 25 a second must be picture frame 1, not 0.999….)
        let picture = max(0, Int(floor(Double(frame) * Double(r.num) / (Double(r.den) * sampleRate) + 1e-9)))
        return Timecode(pictureFrames: startFrames + picture, rate: rate)
    }
    /// The audio frame at which a timecode's picture frame begins; nil when the timecode is before the timeline's start.
    public func frame(of timecode: Timecode, sampleRate: Double) -> Frame? {
        let picture = timecode.pictureFrames - startFrames
        guard picture >= 0 else { return nil }
        let r = rate.perSecond
        return Frame((Double(picture) * Double(r.den) * sampleRate / Double(r.num)).rounded(.up))
    }
}
