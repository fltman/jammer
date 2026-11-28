import AppKit
import JammerCore

/// The slider under the window's ResettableSlider (COMFORT 65): a double-click or a still ⌥-click puts it back at its
/// default, a ⌥-drag moves it a tenth as far (SliderGesture decides), and what VoiceOver hears and does is set on the
/// slider itself: its label, its value in words, and increment and decrement by `step`, each one step through
/// `editing` and `changed` as a drag is (a SwiftUI modifier on the view around it isn't sure to reach it).
public final class FineSlider: NSSlider {
    public var resetValue = 0.0
    /// The step of VoiceOver's increment and decrement (and of the arrow keys): a 144th of the range unless given.
    public var step: Double?
    public var editing: (Bool) -> Void = { _ in }
    public var changed: (Double) -> Void = { _ in }
    /// The value in words, as the window says it ("−3.5 dB", "Left 20 %").
    public var valueText: String = "" { didSet { setAccessibilityValueDescription(valueText) } }

    public var stepSize: Double { step ?? (maxValue - minValue) / 144 }

    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let option = event.modifierFlags.contains(.option)
        if SliderGesture.action(clickCount: event.clickCount, option: option, moved: false) == .reset, !option {
            put(resetValue)
            return
        }
        guard option else {
            editing(true)
            super.mouseDown(with: event)   // tracks until the button is let go, sending the action as it moves
            editing(false)
            return
        }
        // ⌥: a drag moves a tenth as far; let go without moving, and it resets.
        let startX = convert(event.locationInWindow, from: nil).x, start = doubleValue
        var moved = false
        editing(true)
        while let e = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), e.type == .leftMouseDragged {
            let dx = Double(convert(e.locationInWindow, from: nil).x - startX)
            if abs(dx) >= 2 { moved = true }
            guard moved else { continue }
            doubleValue = SliderGesture.value(from: start, dx: dx, width: Double(bounds.width), range: minValue...maxValue, fine: true)
            changed(doubleValue)
        }
        if SliderGesture.action(clickCount: 1, option: true, moved: moved) == .reset { doubleValue = resetValue; changed(resetValue) }
        editing(false)
    }

    public override func accessibilityPerformIncrement() -> Bool { guard isEnabled else { return false }; put(min(maxValue, doubleValue + stepSize)); return true }
    public override func accessibilityPerformDecrement() -> Bool { guard isEnabled else { return false }; put(max(minValue, doubleValue - stepSize)); return true }
    public override func moveRight(_ sender: Any?) { _ = accessibilityPerformIncrement() }
    public override func moveLeft(_ sender: Any?) { _ = accessibilityPerformDecrement() }
    public override func moveUp(_ sender: Any?) { _ = accessibilityPerformIncrement() }
    public override func moveDown(_ sender: Any?) { _ = accessibilityPerformDecrement() }

    /// One step: begun, the value set, ended (a reset, an increment).
    public func put(_ v: Double) {
        editing(true)
        doubleValue = v
        changed(v)
        editing(false)
    }
}
