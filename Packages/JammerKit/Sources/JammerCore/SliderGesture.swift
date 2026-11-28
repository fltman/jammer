/// What a press on a slider does (COMFORT 65, the comfort sweep of 2026-11-25): a double-click, or a ⌥-click that
/// doesn't move, puts it back at its default as one named step; a drag with ⌥ moves it a tenth as far, for the last
/// fraction of a decibel; anything else is the slider's own drag.
public enum SliderGesture {
    public enum Action: Sendable, Equatable { case reset, drag, fineDrag }
    /// How much of the pointer's movement a ⌥-drag gives.
    public static let fineFactor = 0.1

    public static func action(clickCount: Int, option: Bool, moved: Bool) -> Action {
        if clickCount >= 2 { return .reset }
        if option { return moved ? .fineDrag : .reset }
        return .drag
    }

    /// The value after the pointer moved `dx` points along a slider `width` points wide over `range`, from `start`;
    /// a tenth of that with `fine`. Kept within the range.
    public static func value(from start: Double, dx: Double, width: Double, range: ClosedRange<Double>, fine: Bool) -> Double {
        let perPoint = (range.upperBound - range.lowerBound) / max(1, width)
        let v = start + dx * perPoint * (fine ? fineFactor : 1)
        return min(range.upperBound, max(range.lowerBound, v))
    }
}
