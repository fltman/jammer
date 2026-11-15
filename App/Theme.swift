import AppKit
import SwiftUI

/// The Neon look shared with the series: a turquoise glow on near-black.
enum Theme {
    /// #2ef2d8
    static let neon = NSColor(srgbRed: 0x2E / 255, green: 0xF2 / 255, blue: 0xD8 / 255, alpha: 1)
    static let ink = NSColor(srgbRed: 0.035, green: 0.045, blue: 0.055, alpha: 1)
    static let lane = NSColor(srgbRed: 0.06, green: 0.075, blue: 0.085, alpha: 1)
    static let grid = NSColor(white: 1, alpha: 0.08)
    static let text = NSColor(white: 1, alpha: 0.75)
    static let marker = NSColor(srgbRed: 1, green: 0.78, blue: 0.3, alpha: 1)
    static let playhead = NSColor(srgbRed: 1, green: 0.35, blue: 0.45, alpha: 1)

    static var neonColor: Color { Color(nsColor: neon) }
    static var inkColor: Color { Color(nsColor: ink) }
}

/// Seconds as h:mm:ss.mmm (or m:ss.mmm under an hour).
func formatTime(_ seconds: Double, millis: Bool = true) -> String {
    // Round to whole milliseconds first, so 3.4 s shows as 0:03.400, not 0:03.399.
    let total = Int((max(0, seconds) * 1_000).rounded())
    let ms = total % 1_000, s = total / 1_000
    let h = s / 3_600, m = (s / 60) % 60, sec = s % 60
    let base = h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    return millis ? base + String(format: ".%03d", ms) : base
}
