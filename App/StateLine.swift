import JammerCore
import SwiftUI

/// A line that says what state something is in: the kind's symbol in the kind's colour, then the text in
/// the label's own colour (the-apps/SIBLINGS.md, "Tillstånd i fönstret"). The kinds are told apart by the
/// symbol, not by colour alone, and VoiceOver hears which kind it is first. No view colours a state by hand.
struct StateLine: View {
    let kind: StateKind
    let text: String
    var font: Font = .caption

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: kind.symbol).foregroundStyle(kind.color).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(font)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(kind.spokenSaid.map { "\(L10n.message($0.keyed)) \(text)" } ?? text)
    }
}

extension StateKind {
    var color: Color { Color(.sRGB, red: colour.r, green: colour.g, blue: colour.b, opacity: 1) }
}
