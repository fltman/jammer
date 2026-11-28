import AppKit
import JammerControls
import JammerCore
import SwiftUI

/// A slider that goes back to its default with a double-click or a ⌥-click, and moves a tenth as far with ⌥ held
/// while dragging (COMFORT 65; FineSlider in JammerControls, tried there). Its label and its value in words are set
/// on the slider itself, for VoiceOver, which also steps it. The reset goes through `onEditingChanged` like a drag:
/// begun, the value set, ended, so the caller makes its one named step of it.
struct ResettableSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let reset: Double
    let label: String
    let valueText: String
    var onEditingChanged: (Bool) -> Void = { _ in }

    init(value: Binding<Double>, in range: ClosedRange<Double>, reset: Double, label: String, valueText: String,
         onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _value = value; self.range = range; self.reset = reset; self.label = label; self.valueText = valueText
        self.onEditingChanged = onEditingChanged
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
        s.setAccessibilityLabel(label)
        s.valueText = valueText
        s.editing = { [weak c] on in c?.tracking = on; c?.parent.onEditingChanged(on) }
        s.changed = { [weak c] v in c?.parent.value = v }
    }
}
