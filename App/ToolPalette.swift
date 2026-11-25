import AppKit
import JammerAgent
import SwiftUI

/// The tool palette (the comfort block, step 2; Glimmer's pattern): a narrow column beside the timeline, one button
/// per tool with its symbol, its name and letter as the help tag, the current one lit. The letters pick the same
/// tools while the timeline has the keys, and View › Tool lists them.
struct ToolPalette: View {
    @State private var hovered: String?
    @Bindable var session: EditorSession
    let choose: (String) -> Void

    var body: some View {
        VStack(spacing: 4) {
            // Lasso and brush only in a build that has them (Operations.spectralFreeform).
            ForEach(Commands.tools.filter { Operations.spectralFreeform || !["lasso", "brush"].contains($0.id) }, id: \.id) { t in
                let on = session.tool == t.id
                let name = L10n.text(t.title)
                Button { choose(t.id) } label: {
                    Image(systemName: t.symbol)
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 28, height: 26)
                        .foregroundStyle(on ? Theme.neonColor : .secondary)
                        .background(on ? Theme.neonColor.opacity(0.16) : hovered == t.id ? Color.white.opacity(0.08) : .clear, in: .rect(cornerRadius: 6))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                // The tool under the pointer lights a little (COMFORT 21, 46).
                .onHover { inside in hovered = inside ? t.id : (hovered == t.id ? nil : hovered) }
                .help(L10n.text("tool.help", name, t.letter.uppercased()))
                .accessibilityLabel(name)
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("tool.\(t.id)")
                if t.id == "gain" || t.id == "brush" { Divider().frame(width: 20).padding(.vertical, 2) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .frame(width: 36)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("tool.palette.ax"))
    }
}
