import Foundation
import Testing
@testable import JammerCore

@Suite("The flashing rule: nothing flashes more than three times a second")
struct FlashingTests {
    /// A square wave between two brightnesses, `hz` cycles a second, sampled 120 times a second for `seconds`.
    func square(_ hz: Double, _ low: Double, _ high: Double, seconds: Double = 3) -> [Double] {
        (0..<Int(seconds * 120)).map { i in (Double(i) / 120 * hz).truncatingRemainder(dividingBy: 1) < 0.5 ? high : low }
    }

    @Test("The counter: a 10 Hz and a 2 Hz light-dark square read as such; a meter's small movement is no flash")
    func counter() {
        #expect(FlashCounter.maxPerSecond(square(10, 0.05, 0.9), rate: 120) == 10)
        #expect(FlashCounter.maxPerSecond(square(2, 0.05, 0.9), rate: 120) == 2)
        #expect(FlashCounter.maxPerSecond(square(10, 0.50, 0.55), rate: 120) == 0, "a change under a tenth")
        #expect(FlashCounter.maxPerSecond(square(10, 0.85, 0.99), rate: 120) == 0, "both sides bright")
        #expect(FlashCounter.maxPerSecond([Double](repeating: 0.3, count: 240), rate: 120) == 0)
    }

    /// Plays 10 s at 48 kHz in 60 Hz ticks and follows by `rule`; returns the pages' times and whether the playhead was
    /// on screen at every tick.
    func play(width: Double, fpp: Double, reduceMotion: Bool, old: Bool = false) -> (pages: [Double], paused: Bool, alwaysShown: Bool) {
        let rate = 48_000.0
        var start = 0.0, last: Double?, pages: [Double] = [], paused = false, shown = true
        for tick in 0..<600 {
            let now = Double(tick) / 60, playhead = now * rate
            let d = old ? FollowPolicy.unlimited(start: start, playhead: playhead, width: width, framesPerPoint: fpp)
                        : FollowPolicy.next(start: start, playhead: playhead, width: width, framesPerPoint: fpp, sampleRate: rate,
                                            lastPage: last, now: now, reduceMotion: reduceMotion)
            switch d {
            case .page(let s): start = s; last = now; pages.append(now)
            case .paused: paused = true
            case .stay: break
            }
            let x = (playhead - start) / fpp
            if !(x >= 0 && x <= width) { shown = false }
        }
        return (pages, paused, shown)
    }

    func mostInASecond(_ times: [Double]) -> Int {
        var most = 0, first = 0
        for (i, t) in times.enumerated() {
            while times[first] <= t - 1 { first += 1 }
            most = max(most, i - first + 1)
        }
        return most
    }

    @Test("Before: following paged every other tick at a close zoom, thirty pictures a second over the whole timeline")
    func oldRuleSeen() {
        let r = play(width: 1_000, fpp: 1, reduceMotion: false, old: true)
        #expect(mostInASecond(r.pages) >= 29)
    }

    @Test("Following, at every zoom and width: at most two pages a second (one with Reduce Motion); where that can't keep up it pauses, and otherwise the playhead never leaves the view",
          arguments: [false, true])
    func follows(reduceMotion: Bool) {
        let limit = reduceMotion ? 1 : 2
        for width in [400.0, 1_000, 3_000] {
            for fpp in [0.05, 0.2, 1, 5, 20, 30, 40, 60, 100, 500, 1_000] {
                let r = play(width: width, fpp: fpp, reduceMotion: reduceMotion)
                let needed = FollowPolicy.pagesPerSecond(width: width, framesPerPoint: fpp, sampleRate: 48_000)
                #expect(mostInASecond(r.pages) <= limit, "width \(width), fpp \(fpp): \(mostInASecond(r.pages)) pages in a second")
                if needed > Double(limit) {
                    #expect(r.paused && r.pages.isEmpty, "width \(width), fpp \(fpp): paused, not paging")
                } else {
                    #expect(!r.paused && r.alwaysShown, "width \(width), fpp \(fpp): the playhead stays in view")
                }
                // A page replaces the picture: at the most a light-dark change per page.
                var lum: [Double] = [], bright = true, k = 0
                for i in 0..<1_200 {
                    let t = Double(i) / 120
                    while k < r.pages.count, r.pages[k] <= t { bright.toggle(); k += 1 }
                    lum.append(bright ? 0.9 : 0.05)
                }
                #expect(FlashCounter.maxPerSecond(lum, rate: 120) <= 3)
            }
        }
    }

    /// Pages `pagesPerSecond` for 3 s; each new view's exact picture comes `delay` s after it is asked for, one at a
    /// time, the latest view only. Returns the timeline's brightness at 120 Hz: the block envelope is filled and
    /// bright, the exact line thin.
    func pictures(pagesPerSecond: Double, delay: Double, policy: Bool) -> [Double] {
        let coarse = 0.035 + 0.8 * 0.9, exact = 0.035 + 0.8 * 0.15
        var shownExact = false, shownKey = -1, inFlight: (key: Int, done: Double)?, wanted: Int?
        var lum: [Double] = []
        let step = 0.001
        var nextPage = 0.0, key = 0
        for i in 0..<3_000 {
            let t = Double(i) * step
            if t >= nextPage {
                key += 1
                if !policy || WaveformBufferPolicy.drawsCoarse(needsExact: true, shownIsExact: shownExact, sameShape: true) { shownExact = false }
                shownKey = key
                if inFlight == nil { inFlight = (key, t + delay) } else { wanted = key }
                nextPage += 1 / pagesPerSecond
            }
            if let f = inFlight, t >= f.done {
                if f.key == shownKey { shownExact = true }
                inFlight = wanted.map { ($0, t + delay) }
                wanted = nil
            }
            if i % 8 == 0 { lum.append(shownExact ? exact : coarse) }   // 125 samples a second
        }
        return lum
    }

    @Test("Zoomed in past the peaks, a new view keeps the last exact picture until its own is ready: no bright envelope between pages",
          arguments: [0.005, 0.02, 0.04])
    func keepsExact(delay: Double) {
        for rate in [2.0, 20, 60] {
            let before = FlashCounter.maxPerSecond(pictures(pagesPerSecond: rate, delay: delay, policy: false), rate: 125)
            let after = FlashCounter.maxPerSecond(pictures(pagesPerSecond: rate, delay: delay, policy: true), rate: 125)
            if rate > 3, delay < 1 / rate { #expect(before > 3, "the measurement sees the old way at \(rate) pages a second") }
            #expect(after <= 1, "\(rate) pages a second, \(delay * 1_000) ms: \(after)")
        }
        #expect(WaveformBufferPolicy.drawsCoarse(needsExact: true, shownIsExact: true, sameShape: false), "another size: drawn anew")
        #expect(WaveformBufferPolicy.drawsCoarse(needsExact: false, shownIsExact: true, sameShape: true), "zoomed out: the peaks are exact enough")
    }
}

@Suite("The transcript's lit word")
struct LitWordTests {
    @Test("Fast speech, six words a second with 50 ms between them, sampled 60 times a second: the light never goes out in the middle, each word lights once; a pause of a second puts it out")
    func fastSpeech() {
        let rate: Frame = 48_000, word = rate / 6, gap = rate / 20
        var starts: [Frame] = [], ends: [Frame] = []
        var t: Frame = 0
        for i in 0..<30 {
            if i == 15 { t += rate }   // a pause of a second
            starts.append(t); ends.append(t + word - gap); t += word
        }
        let bridge = rate / 3
        var lit: Int?
        var anyLit: [Double] = [], changes = 0
        for n in 0..<Int(Double(t) / Double(rate) * 60) {
            let f = Frame(Double(n) / 60 * Double(rate))
            let next = LitWord.index(at: f, starts: starts, ends: ends, lit: lit, bridge: bridge)
            if next != lit { changes += 1 }
            lit = next
            anyLit.append(next == nil ? 0.05 : 0.9)
        }
        // The light as a whole: on through the first fifteen words, out in the pause, on through the rest.
        #expect(FlashCounter.maxPerSecond(anyLit, rate: 60) <= 1, "the light over the words doesn't blink")
        #expect(changes <= 30 + 2, "each word lit once (and out once in the pause): \(changes) changes")
        #expect(LitWord.index(at: ends[14] + rate / 2, starts: starts, ends: ends, lit: 14, bridge: bridge) == nil, "out in the pause")
        #expect(LitWord.index(at: starts[3], starts: starts, ends: ends, lit: 2, bridge: bridge) == 3)
    }
}
