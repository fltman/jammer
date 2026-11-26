import Foundation
import Testing
@testable import JammerCore

/// The timeline's zones: what a press grabs and which pointer says so, from one source.
@Suite("Handle zones")
struct HandleZoneTests {
    let a = UUID(), b = UUID(), m = UUID()
    var layout: HandleZones.Layout {
        // Ruler 24 pt, two lanes of 100 pt. Lane 0: a clip 100–400 with a fade in to 160 and none out; lane 1: one 50–300.
        HandleZones.Layout(rulerHeight: 24, laneHeight: 100,
                           lanes: [[.init(id: a, start: 100, end: 400, fadeInEnd: 160, fadeOutStart: 400)],
                                   [.init(id: b, start: 50, end: 300, fadeInEnd: 50, fadeOutStart: 300)]],
                           selection: (start: 200, end: 250), markers: [.init(id: m, x: 500, width: 40)])
    }

    @Test("Each zone and its pointer: ruler arrow, marker hand, edges and fade handles ↔, a lane's I-beam")
    func zones() {
        let l = layout
        func z(_ x: Double, _ y: Double) -> HandleZones.Zone { HandleZones.zone(at: x, y, in: l) }
        #expect(z(10, 5) == .ruler && z(10, 5).pointer == .arrow)
        #expect(z(510, 30) == .marker(m) && z(510, 30).pointer == .openHand)
        #expect(z(161, 28) == .fadeIn(clip: a) && z(394, 28) == .fadeOut(clip: a))
        // A clip with no fade keeps its handles a handle's width inside its edges (never on the window's edge).
        #expect(z(56, 128) == .fadeIn(clip: b) && z(50, 128) != .fadeIn(clip: b))
        #expect(z(202, 60) == .selectionStart && z(248, 110) == .selectionEnd && z(202, 60).pointer == .resizeLeftRight)
        #expect(z(102, 110) == .trimStart(clip: a) && z(398, 110) == .trimEnd(clip: a))
        // The upper half of a lane keeps its plain selection drag over a clip edge.
        #expect(z(102, 60) == .lane(0) && z(102, 60).pointer == .iBeam)
        #expect(z(52, 190) == .trimStart(clip: b) && z(150, 190) == .lane(1))
        #expect(z(10, 300) == .none)
    }

    @Test("A narrow clip keeps its middle: the trim grips reach outside it, each still 8 pt wide (COMFORT 75)")
    func narrowClip() {
        let n = UUID()
        // A clip 8 pt wide in lane 1 (100–108), lower half.
        var l = layout
        l.lanes[1] = [.init(id: n, start: 100, end: 108, fadeInEnd: 100, fadeOutStart: 108)]
        func z(_ x: Double) -> HandleZones.Zone { HandleZones.zone(at: x, 190, in: l) }
        // Its middle half (102–106) is the lane, not a trim.
        for x in stride(from: 102.5, through: 105.5, by: 0.5) { #expect(z(x) == .lane(1)) }
        // Each grip: 8 pt or more, from outside the clip to a quarter in.
        let starts = stride(from: 90.0, through: 110, by: 0.25).filter { z($0) == .trimStart(clip: n) }
        let ends = stride(from: 95.0, through: 120, by: 0.25).filter { z($0) == .trimEnd(clip: n) }
        #expect((starts.last ?? 0) - (starts.first ?? 0) >= 8 && (starts.last ?? 0) <= 102)
        #expect((ends.last ?? 0) - (ends.first ?? 0) >= 8 && (ends.first ?? 200) >= 106)
        // A wide clip is as before: 4 pt each side of its edge.
        #expect(HandleZones.zone(at: 52, 190, in: layout) == .trimStart(clip: b) && HandleZones.zone(at: 46, 190, in: layout) == .trimStart(clip: b))
        #expect(HandleZones.zone(at: 55, 190, in: layout) == .lane(1))
    }

    @Test("Scrolled lanes: a press finds the lane drawn under it, and the edge rows and what is scrolled away grab nothing")
    func scrolled() {
        var l = layout
        // Two lanes of 48 pt in 60 pt: edge rows of 14, 32 pt seen, scrolled 40 pt (lane 1's top at 24 + 14 + 48 − 40 = 46).
        l.scrolling = LaneLayout(tracks: 2, rulerHeight: 24, areaHeight: 60, scrollY: 40)
        l.laneHeight = 48
        func z(_ x: Double, _ y: Double) -> HandleZones.Zone { HandleZones.zone(at: x, y, in: l) }
        #expect(z(56, 50) == .fadeIn(clip: b))
        #expect(z(150, 60) == .lane(1))
        // Lane 0 is scrolled under the top edge row: its handles can't be grabbed there.
        #expect(z(161, 30) == .none)
        #expect(z(150, 71) == .none)
        // Marker flags still hang under the ruler.
        #expect(z(510, 30) == .marker(m))
    }

    @Test("The hit area of a grip is at least 8 pt wide whatever is drawn; a fade handle wins over a selection edge")
    func priorities() {
        var l = layout
        #expect(HandleZones.grip * 2 >= 8)
        l.selection = (start: 160, end: 250)
        #expect(HandleZones.zone(at: 160, 28, in: l) == .fadeIn(clip: a))
        #expect(HandleZones.zone(at: 160, 60, in: l) == .selectionStart)
    }

    @Test("Snapping takes the nearest target within reach, or none")
    func snapping() {
        #expect(HandleZones.snap(103, to: [100, 400, 108]) == 100)
        #expect(HandleZones.snap(120, to: [100, 400]) == nil)
    }
}
