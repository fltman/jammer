import AppKit
import JammerCore
import SwiftUI

/// A slider that goes back to its default with a double-click or a ⌥-click, and moves a tenth as far with ⌥ held
/// while dragging (COMFORT 65, the comfort sweep of 2026-11-25; SliderGesture decides). The reset goes through
/// `onEditingChanged` like a drag: begun, the value set, ended, so the caller makes its one named step of it.
struct ResettableSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let reset: Double
    var onEditingChanged: (Bool) -> Void = { _ in }

    init(value: Binding<Double>, in range: ClosedRange<Double>, reset: Double, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _value = value; self.range = range; self.reset = reset; self.onEditingChanged = onEditingChanged
    }

    final class Coordinator: NSObject {
        var parent: ResettableSlider
        var tracking = false
        init(_ parent: ResettableSlider) { self.parent = parent }
        @objc func moved(_ slider: NSSlider) { parent.value = slider.doubleValue }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FineSlider {
        let s = FineSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: context.coordinator,
                           action: #selector(Coordinator.moved(_:)))
        s.isContinuous = true
        return s
    }

    func updateNSView(_ s: FineSlider, context: Context) {
        let c = context.coordinator
        c.parent = self
        s.controlSize = context.environment.controlSize == .mini ? .mini : context.environment.controlSize == .small ? .small : .regular
        s.minValue = range.lowerBound
        s.maxValue = range.upperBound
        if !c.tracking { s.doubleValue = value }
        s.resetValue = reset
        s.isEnabled = context.environment.isEnabled
        s.editing = { [weak c] on in c?.tracking = on; c?.parent.onEditingChanged(on) }
        s.changed = { [weak c] v in c?.parent.value = v }
    }
}

/// The slider underneath: a double-click or a still ⌥-click resets, a ⌥-drag is fine, the rest is NSSlider's own.
final class FineSlider: NSSlider {
    var resetValue = 0.0
    var editing: (Bool) -> Void = { _ in }
    var changed: (Double) -> Void = { _ in }

    override func mouseDown(with event: NSEvent) {
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

    private func put(_ v: Double) {
        editing(true)
        doubleValue = v
        changed(v)
        editing(false)
    }
}
