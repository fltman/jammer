import Foundation
import Testing
@testable import JammerCore

@Suite("States in a window: error, warning, information")
struct StateStyleTests {
    @Test("Every kind has its own symbol; an error is never the triangle; each symbol's colour is at least 3:1 on the window's ground; no state's colour can be taken for the accent or for another state's")
    func kinds() {
        let all = StateKind.allCases
        #expect(Set(all.map(\.symbol)).count == all.count)
        #expect(StateKind.error.symbol.contains("octagon") && !StateKind.error.symbol.contains("triangle") && StateKind.warning.symbol.contains("triangle"))
        for k in all { #expect(StateKind.contrast(k.colour, StateKind.ground) >= 3, "\(k)") }
        // Hues: 30 degrees or more from the accent, and from each other where two kinds have a hue at all.
        let accent = StateKind.hue(StateKind.accent)!
        func apart(_ a: Double, _ b: Double) -> Double { let d = abs(a - b); return min(d, 360 - d) }
        var hues: [(StateKind, Double)] = []
        for k in all { if let h = StateKind.hue(k.colour) { #expect(apart(h, accent) >= 30, "\(k) against the accent"); hues.append((k, h)) } }
        for (i, a) in hues.enumerated() { for b in hues[(i + 1)...] { #expect(apart(a.1, b.1) >= 30, "\(a.0) against \(b.0)") } }
        // Information is neutral: it has no hue to mistake for anything.
        #expect(StateKind.hue(StateKind.info.colour) == nil)
        // What VoiceOver says first: an error and a warning say which they are.
        #expect(StateKind.error.spoken == "Error:" && StateKind.warning.spoken == "Warning:" && StateKind.info.spoken == nil)
        // The automation lanes' orange (the system's, about 1.0, 0.62, 0.04 on a dark window) is not the warning’s yellow, though it is near it: 10 degrees apart or more (12 as it stands).
        #expect(apart(StateKind.hue((1.0, 0.62, 0.04))!, StateKind.hue(StateKind.warning.colour)!) >= 10)
    }
}
