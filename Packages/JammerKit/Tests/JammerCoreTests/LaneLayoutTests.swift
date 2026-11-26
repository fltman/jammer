import Testing
@testable import JammerCore

@Suite("Where the lanes lie: a least height, and scrolling when the tracks don't fit")
struct LaneLayoutTests {
    let ruler = 26.0

    @Test("A few tracks share the height as before; many keep their least height and scroll")
    func heights() {
        let few = LaneLayout(tracks: 4, rulerHeight: ruler, areaHeight: 600)
        #expect(few.laneHeight == 150 && !few.overflows && few.edge == 0)
        #expect(few.lanesTop == ruler && few.lanesBottom == ruler + 600)
        let many = LaneLayout(tracks: 24, rulerHeight: ruler, areaHeight: 600)
        #expect(many.laneHeight == LaneLayout.minimum && many.overflows)
        #expect(many.edge == LaneLayout.edgeRow && many.visibleHeight == 600 - 2 * LaneLayout.edgeRow)
        #expect(many.maxScroll == 24 * 48 - many.visibleHeight)
        // At every height and zoom, a lane is never under its least height, and the lanes fill what is seen.
        for tracks in [1, 3, 12, 24, 60] {
            for area in stride(from: 100.0, through: 1_400, by: 37) {
                for zoom in [0.5, 0.8, 1, 2, 4] {
                    let l = LaneLayout(tracks: tracks, rulerHeight: ruler, areaHeight: area, zoom: zoom)
                    #expect(l.laneHeight >= LaneLayout.minimum * zoom - 1e-9)
                    #expect(l.contentHeight >= l.visibleHeight - 1e-9)
                }
            }
        }
    }

    @Test("Scrolling stays within the content, and a point finds the lane drawn under it")
    func scrollingAndHits() {
        let l = LaneLayout(tracks: 24, rulerHeight: ruler, areaHeight: 600)
        #expect(l.scrolled(to: -50).scrollY == 0)
        #expect(l.scrolled(to: 1e6).scrollY == l.maxScroll)
        for y in stride(from: 0.0, through: l.maxScroll, by: 13) {
            let s = l.scrolled(to: y)
            for t in s.visibleLanes {
                let mid = s.laneTop(t) + s.laneHeight / 2
                if mid >= s.lanesTop, mid < s.lanesBottom { #expect(s.lane(atY: mid) == t) }
            }
            // The ruler and the edge rows are no lane.
            #expect(s.lane(atY: ruler - 1) == nil)
            #expect(s.lane(atY: s.lanesTop - 1) == nil)
            #expect(s.lane(atY: s.lanesBottom) == nil)
        }
        // Below the last lane of a short document: nothing.
        let few = LaneLayout(tracks: 2, rulerHeight: ruler, areaHeight: 600)
        #expect(few.lane(atY: ruler + 599) == 1)
        #expect(few.lane(atY: ruler + 600) == nil)
    }

    @Test("A track that gets the focus or the selection is brought into view, with as little scrolling as can be")
    func reveal() {
        let l = LaneLayout(tracks: 24, rulerHeight: ruler, areaHeight: 600)
        // Seen already: nothing moves.
        #expect(l.revealing(2).scrollY == 0)
        // Below (Tab, ↓ among the headers, the agent's select_track, a new track at the bottom): its bottom edge at the bottom.
        let down = l.revealing(20)
        #expect(down.isWhollyVisible(20))
        #expect(abs(down.laneTop(20) + down.laneHeight - down.lanesBottom) < 1e-9)
        // Above: its top at the top.
        let up = down.revealing(3)
        #expect(up.isWhollyVisible(3) && abs(up.laneTop(3) - up.lanesTop) < 1e-9)
        // Every track, from anywhere.
        for from in stride(from: 0.0, through: l.maxScroll, by: 100) {
            for t in 0..<24 { #expect(l.scrolled(to: from).revealing(t).isWhollyVisible(t)) }
        }
        // A new track added at the bottom: the layout of 25 revealing the last.
        let added = LaneLayout(tracks: 25, rulerHeight: ruler, areaHeight: 600, scrollY: l.scrollY).revealing(24)
        #expect(added.isWhollyVisible(24))
        // Out of range: nothing.
        #expect(l.revealing(99) == l && l.revealing(-1) == l)
    }

    @Test("Track zoom keeps the lane under the pointer where it is; Fit shows every track when it can")
    func zoom() {
        let l = LaneLayout(tracks: 24, rulerHeight: ruler, areaHeight: 600).scrolled(to: 300)
        let anchor = l.lanesTop + 200
        let lane = l.lane(atY: anchor)
        let taller = l.zoomed(by: 1.5, anchorY: anchor)
        #expect(taller.zoom == 1.5 && taller.lane(atY: anchor) == lane)
        let shorter = taller.zoomed(by: 1 / 1.5, anchorY: anchor)
        #expect(abs(shorter.scrollY - l.scrollY) < 1e-6)
        #expect(l.zoomed(by: 100).zoom == LaneLayout.zoomRange.upperBound)
        #expect(l.zoomed(by: 0.001).zoom == LaneLayout.zoomRange.lowerBound)
        let fit = l.fitted()
        #expect(!fit.overflows && fit.scrollY == 0 && fit.visibleLanes == 0..<24)
        // Too many to fit even at the least zoom: the least zoom, scrolling.
        let crowd = LaneLayout(tracks: 80, rulerHeight: ruler, areaHeight: 600).fitted()
        #expect(crowd.zoom == LaneLayout.zoomRange.lowerBound && crowd.overflows)
        // Few tracks: Fit never makes lanes smaller than the default.
        #expect(LaneLayout(tracks: 3, rulerHeight: ruler, areaHeight: 600, zoom: 3).fitted().zoom == 1)
    }

    @Test("The hidden tracks' mark: only tracks the selection reaches, above and below what is seen")
    func hidden() {
        let l = LaneLayout(tracks: 24, rulerHeight: ruler, areaHeight: 600).scrolled(to: 48 * 6)
        let seen = l.visibleLanes
        #expect(seen.lowerBound == 6)
        let h = l.hidden([0, 2, 7, 8, 22, 23])
        #expect(h.above == [0, 2] && h.below == [22, 23])
        #expect(l.hidden([7, 8]).above.isEmpty && l.hidden([7, 8]).below.isEmpty)
        // Nearest first for a click: the last above, the first below.
        #expect(h.above.last == 2 && h.below.first == 22)
        let all = LaneLayout(tracks: 4, rulerHeight: ruler, areaHeight: 600).hidden([0, 1, 2, 3])
        #expect(all.above.isEmpty && all.below.isEmpty)
    }
}
