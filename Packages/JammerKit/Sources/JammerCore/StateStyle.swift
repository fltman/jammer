import Foundation

/// What a line in a window is: something that didn't go, something with a consequence, something to
/// know, something that went well, something going on (the-apps/SIBLINGS.md, "Tillstånd i fönstret").
/// One kind gives the symbol, the colour of the symbol and the word VoiceOver says first, so that the
/// kinds can be told apart without colour, and a symbol means one thing in the whole app. The text beside
/// the symbol is in the label's own colour; the colour is on the symbol.
public enum StateKind: String, Sendable, CaseIterable {
    case error, warning, info, success, progress

    /// The SF Symbol. An error is a cross in a filled square: never a round or eight-sided plate (at 12 to
    /// 16 points an octagon can't be told from the circle that carries the tick for "done", and to a
    /// red-green colour-blind eye the two have one colour), and never the triangle, which is the warning's.
    public var symbol: String {
        switch self {
        case .error: "xmark.square.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle"
        case .success: "checkmark.circle.fill"
        case .progress: "circle.dotted"
        }
    }
    /// Said first by VoiceOver, where the kind matters to what follows (an upplysning needs no word).
    public var spoken: String? { spokenSaid?.text }
    /// The same, by key, for a window in either language.
    public var spokenSaid: Said? {
        switch self {
        case .error: Said("state.spoken.error", "Error:")
        case .warning: Said("state.spoken.warning", "Warning:")
        case .success: Said("state.spoken.success", "Done:")
        case .progress: Said("state.spoken.progress", "In progress:")
        case .info: nil
        }
    }
    /// The symbol's colour (sRGB) on Jämmer's dark windows. Neutral for information.
    public var colour: (r: Double, g: Double, b: Double) {
        switch self {
        case .error: (1.00, 0.42, 0.40)
        case .warning: (1.00, 0.84, 0.22)
        case .info, .progress: (0.78, 0.80, 0.82)
        case .success: (0.40, 0.86, 0.48)
        }
    }

    /// Jämmer's window ground and its accent, which no state's colour may be mistaken for.
    public static let ground = (r: 0.035, g: 0.045, b: 0.055)
    public static let accent = (r: 0x2E / 255.0, g: 0xF2 / 255.0, b: 0xD8 / 255.0)

    /// Contrast of two colours as WCAG counts it (1 to 21).
    public static func contrast(_ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double)) -> Double {
        func lum(_ c: (r: Double, g: Double, b: Double)) -> Double {
            func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
        }
        let (x, y) = (lum(a), lum(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
    /// The hue of a colour in degrees, or nil for a grey.
    public static func hue(_ c: (r: Double, g: Double, b: Double)) -> Double? {
        let hi = max(c.r, c.g, c.b), lo = min(c.r, c.g, c.b), d = hi - lo
        guard d > 0.08 else { return nil }
        var h = hi == c.r ? (c.g - c.b) / d : hi == c.g ? 2 + (c.b - c.r) / d : 4 + (c.r - c.g) / d
        h *= 60
        return h < 0 ? h + 360 : h
    }
}
