import Foundation

/// The flashing rule (SIBLINGS: nothing flashes more than three times a second; WCAG 2.3.1): what tests measure a
/// picture's brightness against, and the rules that keep the timeline under it.

/// Counts flashes in a brightness series sampled evenly: a flash is a pair of opposite changes of at least a tenth
/// of full brightness, the darker side below 0.8 (WCAG's general flash). Small movements (a meter's bar rising and
/// falling a little) are not flashes.
public enum FlashCounter {
    /// The most flashes in any one second of `luminance` (0…1), sampled `rate` times a second.
    public static func maxPerSecond(_ luminance: [Double], rate: Double) -> Int {
        let times = transitions(luminance).map { Double($0) / rate }
        var most = 0, first = 0
        for (i, t) in times.enumerated() {
            while times[first] <= t - 1 { first += 1 }
            most = max(most, (i - first + 1) / 2)
        }
        return most
    }

    /// The sample indices where the brightness turns: up or down by at least 0.1 from the last extreme, with the
    /// darker of the two below 0.8.
    static func transitions(_ v: [Double]) -> [Int] {
        guard var extreme = v.first else { return [] }
        var rising: Bool?
        var found: [Int] = []
        for (i, x) in v.enumerated().dropFirst() {
            let up = x - extreme >= 0.1, down = extreme - x >= 0.1
            if (up || down), min(x, extreme) < 0.8, rising != up {
                // A turn: counted once the change is big enough the other way from where it went before.
                found.append(i)
                rising = up
                extreme = x
            } else if let r = rising, (r && x > extreme) || (!r && x < extreme) {
                extreme = x
            }
        }
        return found
    }
}

/// When the timeline jumps a page to keep the playhead in view while playing. Each page replaces the whole picture,
/// so pages are a flash: at most two a second, one with Reduce Motion. Zoomed in so far that following would need
/// more, the view stops following (and says so) until it is zoomed out or playing stops.
public enum FollowPolicy {
    public enum Decision: Equatable, Sendable {
        case stay
        /// Jump so the view starts here (the playhead a tenth of the width in).
        case page(start: Double)
        /// Following would page too often at this zoom: the view stays.
        case paused
    }

    /// The pages a second following needs: each page moves eight tenths of a width.
    public static func pagesPerSecond(width: Double, framesPerPoint: Double, sampleRate: Double) -> Double {
        sampleRate / max(1e-9, 0.8 * width * framesPerPoint)
    }

    public static func limit(reduceMotion: Bool) -> Double { reduceMotion ? 1 : 2 }

    /// - Parameters: positions in frames; `now` and `lastPage` in seconds on any steady clock.
    public static func next(start: Double, playhead: Double, width: Double, framesPerPoint fpp: Double, sampleRate: Double,
                            lastPage: Double?, now: Double, reduceMotion: Bool) -> Decision {
        let x = (playhead - start) / fpp
        if x >= 0, x <= width * 0.9 { return .stay }
        let limit = limit(reduceMotion: reduceMotion)
        if pagesPerSecond(width: width, framesPerPoint: fpp, sampleRate: sampleRate) > limit { return .paused }
        if let lastPage, now - lastPage < 1 / limit { return .stay }
        return .page(start: playhead - width * 0.1 * fpp)
    }

    /// The rule before 2026-11-26: a page whenever the playhead left nine tenths of the view (kept for the test that
    /// shows the counter sees what it did).
    public static func unlimited(start: Double, playhead: Double, width: Double, framesPerPoint fpp: Double) -> Decision {
        let x = (playhead - start) / fpp
        return x > width * 0.9 || x < 0 ? .page(start: playhead - width * 0.1 * fpp) : .stay
    }
}

/// What the waveform shows while a new view's columns are made (the performance pass, 2026-11-26): the picture it has,
/// drawn onto the new view's geometry, until the new one is ready. Making the columns in the draw call cost 56–66 ms
/// for 24 tracks, about four frames lost at every step of a zoom; and the block-level envelope drawn between exact
/// pictures was filled and bright where the exact line is thin, a flash at every page. The columns are only made in
/// the draw when there is no picture yet, or the view changed size.
public enum WaveformRemap {
    /// Whether the draw has to make the columns itself (nothing to show, or a picture of another size).
    public static func computesInDraw(hasPicture: Bool, sameShape: Bool) -> Bool { !(hasPicture && sameShape) }

    /// The new view's pixel column x shows the picture's column `offset + x · scale`: worked out in double precision
    /// (an hour's frame numbers lose frames in a Float) and handed to the shader as two numbers.
    public static func mapping(viewStart: Double, viewFramesPerColumn: Double, shownStart: Double, shownFramesPerColumn: Double) -> (offset: Float, scale: Float) {
        guard shownFramesPerColumn > 0 else { return (0, 1) }
        return (Float((viewStart - shownStart) / shownFramesPerColumn), Float(viewFramesPerColumn / shownFramesPerColumn))
    }
}

/// The word lit in the transcript while playing. In the short gaps between words in fast speech the light stays on the
/// word just said, rather than going out and on again four to six times a second; in a longer pause it goes out.
public enum LitWord {
    /// The index of the word to light at `frame`, given the words' starts and ends (sorted), what is lit now, and
    /// the longest gap bridged (frames).
    public static func index(at frame: Frame, starts: [Frame], ends: [Frame], lit: Int?, bridge: Frame) -> Int? {
        var lo = 0, hi = ends.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ends[mid] <= frame { lo = mid + 1 } else { hi = mid }
        }
        if lo < starts.count, starts[lo] <= frame { return lo }
        // In a gap: the word before it stays lit if it is the one lit, and the gap is still short.
        if let lit, lit == lo - 1, lit >= 0, lit < ends.count, frame - ends[lit] < bridge { return lit }
        return nil
    }
}
