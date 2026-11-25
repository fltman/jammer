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
        #expect(z(161, 28) == .fadeIn(clip: a) && z(399, 28) == .fadeOut(clip: a))
        #expect(z(202, 60) == .selectionStart && z(248, 110) == .selectionEnd && z(202, 60).pointer == .resizeLeftRight)
        #expect(z(102, 110) == .trimStart(clip: a) && z(398, 110) == .trimEnd(clip: a))
        // The upper half of a lane keeps its plain selection drag over a clip edge.
        #expect(z(102, 60) == .lane(0) && z(102, 60).pointer == .iBeam)
        #expect(z(52, 190) == .trimStart(clip: b) && z(150, 190) == .lane(1))
        #expect(z(10, 300) == .none)
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
