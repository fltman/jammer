import Testing
@testable import JammerCore

@Suite("A slider's press: reset by double-click or ⌥-click, a tenth as far with ⌥-drag (COMFORT 65)")
struct SliderGestureTests {
    @Test("What each press does")
    func actions() {
        #expect(SliderGesture.action(clickCount: 2, option: false, moved: false) == .reset)
        #expect(SliderGesture.action(clickCount: 2, option: true, moved: true) == .reset)
        #expect(SliderGesture.action(clickCount: 1, option: true, moved: false) == .reset, "⌥-click that doesn't move")
        #expect(SliderGesture.action(clickCount: 1, option: true, moved: true) == .fineDrag)
        #expect(SliderGesture.action(clickCount: 1, option: false, moved: true) == .drag)
    }

    @Test("A ⌥-drag moves a tenth as far, and never past the ends")
    func values() {
        // A level slider: −60…12 dB over 150 points, 0.48 dB a point; with ⌥, 0.048.
        #expect(abs(SliderGesture.value(from: 0, dx: 10, width: 150, range: -60...12, fine: false) - 4.8) < 1e-9)
        #expect(abs(SliderGesture.value(from: 0, dx: 10, width: 150, range: -60...12, fine: true) - 0.48) < 1e-9)
        #expect(SliderGesture.value(from: 11, dx: 500, width: 150, range: -60...12, fine: true) == 12)
        #expect(SliderGesture.value(from: -59, dx: -500, width: 150, range: -60...12, fine: false) == -60)
    }
}
