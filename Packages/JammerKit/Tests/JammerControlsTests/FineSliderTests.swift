import AppKit
import Foundation
import Testing
@testable import JammerControls

/// The window's sliders as VoiceOver meets them, for every kind the window uses (read from the ResettableSlider calls in
/// App/, so a new one is held to this too): a label, its value in words, increment and decrement by one step, each
/// one begun-set-ended step, and the reset inside its range.
@MainActor
@Suite("Sliders for VoiceOver: label, value, increment and decrement, for each use in the window")
struct FineSliderTests {
    struct Use { let file: String; let range: ClosedRange<Double>; let reset: Double; let labelled: Bool; let valued: Bool }

    /// Every `ResettableSlider(` in App/: its range, its reset, and whether it gives a label and a value.
    static func uses() throws -> [Use] {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../../App").standardizedFileURL
        var out: [Use] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: app.path) where name.hasSuffix(".swift") && name != "ResettableSlider.swift" {
            let text = try String(contentsOf: app.appending(path: name), encoding: .utf8)
            for part in text.components(separatedBy: "ResettableSlider(").dropFirst() {
                let call = String(part.prefix(600))
                guard let m = call.firstMatch(of: /in: (-?\d+(?:\.\d+)?)\.\.\.(-?\d+(?:\.\d+)?), reset: (-?\d+(?:\.\d+)?)/),
                      let lo = Double(m.1), let hi = Double(m.2), let reset = Double(m.3) else {
                    out.append(Use(file: name, range: 0...0, reset: 1, labelled: false, valued: false)); continue
                }
                out.append(Use(file: name, range: lo...hi, reset: reset, labelled: call.contains("label: "), valued: call.contains("valueText: ")))
            }
        }
        return out
    }

    @Test("Every slider in the window is given a label and a value in words, and resets inside its range")
    func everyUse() throws {
        let uses = try Self.uses()
        #expect(uses.count >= 9, "the mixer's and the headers' sliders: \(uses.count)")
        for u in uses {
            #expect(u.labelled && u.valued, "a ResettableSlider in \(u.file) without label: or valueText:")
            #expect(u.range.contains(u.reset), "\(u.file): reset \(u.reset) outside \(u.range)")
        }
    }

    @Test("Each kind: label and value set on the slider, increment and decrement one step each way, at the ends held")
    func voiceOver() throws {
        let kinds = Set(try Self.uses().map { [$0.range.lowerBound, $0.range.upperBound, $0.reset] }).map { (range: $0[0]...$0[1], reset: $0[2]) }
        for k in kinds {
            let s = FineSlider(value: k.reset, minValue: k.range.lowerBound, maxValue: k.range.upperBound, target: nil, action: nil)
            s.setAccessibilityLabel("Level of Speech")
            s.valueText = "0.0 dB"
            var events: [String] = [], last: Double?
            s.editing = { events.append($0 ? "begin" : "end") }
            s.changed = { last = $0 }
            #expect(s.accessibilityLabel() == "Level of Speech" && s.accessibilityValueDescription() == "0.0 dB")
            #expect(s.accessibilityPerformIncrement())
            #expect(abs((last ?? .nan) - min(k.range.upperBound, k.reset + s.stepSize)) < 1e-9 && events == ["begin", "end"], "\(k.range): one step up")
            events = []
            #expect(s.accessibilityPerformDecrement())
            #expect(abs((last ?? .nan) - k.reset) < 1e-9 && events == ["begin", "end"], "\(k.range): one step down")
            s.doubleValue = k.range.upperBound
            _ = s.accessibilityPerformIncrement()
            #expect(s.doubleValue == k.range.upperBound, "held at the top")
            s.isEnabled = false
            #expect(!s.accessibilityPerformIncrement(), "a disabled slider (pan under automation) does nothing")
        }
        // A level's step is half a decibel.
        let level = FineSlider(value: 0, minValue: -60, maxValue: 12, target: nil, action: nil)
        #expect(level.stepSize == 0.5)
    }
}
