import Testing
@testable import JammerCore

@Suite("What the timeline draws again")
struct TimelineRedrawTests {
    @Test("The playhead moving alone draws nothing again; a change of content draws once, a page with it included")
    func plans() {
        #expect(TimelineRedraw.plan(.playhead, follow: .stay) == .init(movePlayhead: true, refreshes: 0))
        #expect(TimelineRedraw.plan(.playhead, follow: .paused) == .init(movePlayhead: true, refreshes: 0))
        #expect(TimelineRedraw.plan(.playhead, follow: .page(start: 10)) == .init(movePlayhead: true, refreshes: 1))
        #expect(TimelineRedraw.plan(.content, follow: .stay) == .init(movePlayhead: true, refreshes: 1))
        #expect(TimelineRedraw.plan(.content, follow: .page(start: 10)) == .init(movePlayhead: true, refreshes: 1))
    }

    /// Ten seconds of playing at 60 ticks a second, as the timer does, through the same following the timeline uses.
    func play(width: Double, framesPerPoint fpp: Double, seconds: Double = 10, reduceMotion: Bool = false) -> (ticks: Int, pages: Int, refreshes: Int) {
        let rate = 48_000.0
        var start = 0.0, lastPage: Double?, ticks = 0, pages = 0, refreshes = 0
        for i in 1...Int(seconds * 60) {
            let now = Double(i) / 60, playhead = now * rate
            let decision = FollowPolicy.next(start: start, playhead: playhead, width: width, framesPerPoint: fpp, sampleRate: rate,
                                             lastPage: lastPage, now: now, reduceMotion: reduceMotion)
            if case .page(let s) = decision { start = s; lastPage = now; pages += 1 }
            refreshes += TimelineRedraw.plan(.playhead, follow: decision).refreshes
            ticks += 1
        }
        return (ticks, pages, refreshes)
    }

    @Test("While playing, the timeline is drawn again once per page turned and at no other tick")
    func onePerPage() {
        // 2 s across 1 000 points: a page every 1.6 s.
        let a = play(width: 1_000, framesPerPoint: 96)
        #expect(a.ticks == 600)
        #expect(a.pages >= 5 && a.pages <= 7)
        #expect(a.refreshes == a.pages)
        // Fitted to an hour: the playhead never leaves the view, nothing is drawn again in ten seconds.
        let fit = play(width: 1_000, framesPerPoint: 48_000 * 3_600 / 1_000)
        #expect(fit.pages == 0 && fit.refreshes == 0)
        // Too close to follow: paused, nothing drawn again.
        let close = play(width: 1_000, framesPerPoint: 4)
        #expect(close.pages == 0 && close.refreshes == 0)
        // At the limit, with Reduce Motion: never more than one a second.
        let reduce = play(width: 1_000, framesPerPoint: 60, reduceMotion: true)
        #expect(reduce.refreshes == reduce.pages && reduce.refreshes <= 10)
    }
}
