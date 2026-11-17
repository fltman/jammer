import AppKit
import JammerCore
import SwiftUI

/// Shown at launch: the line to hand to an AI agent so it can learn Jämmer's
/// local API. Also under Help › Agent Access.
struct AgentSplashView: View {
    static let showAtLaunchKey = "agent.splashAtLaunch"
    let dismiss: () -> Void
    @State private var server = AgentServer.shared
    @State private var copied = false
    @AppStorage(Self.showAtLaunchKey) private var showAtLaunch = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    // The light behind the icon breathes; the icon stands still.
                    .background(PulsingGlow().frame(width: 132, height: 132).allowsHitTesting(false))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "Jämmer").font(.largeTitle.bold())
                        .shadow(color: Theme.neonColor.opacity(0.6), radius: 10)
                    Text(L10n.text("splash.tagline"))
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("splash.agent.heading")).font(.headline)
                Text(L10n.text("splash.agent.text"))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let prompt = server.agentPrompt {
                    HStack(alignment: .top, spacing: 8) {
                        // The name is on the group around the text, never on the selectable text itself:
                        // selectable text with a label of its own sends SwiftUI into endless recursion as
                        // soon as an assistive technology reads it (found in Glimmer and Flimmer, 2026-11-16).
                        Group {
                        Text(verbatim: prompt)
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.05), in: .rect(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.neonColor.opacity(0.55)))
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(verbatim: L10n.text("splash.agent.ax", prompt)))
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(prompt, forType: .string)
                            copied = true
                            Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                        } label: {
                            Label(copied ? L10n.text("splash.copied") : L10n.text("splash.copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                                .frame(minWidth: 70)
                        }
                        // Dark text on the neon: about 14:1, where white gives 1.4:1.
                        .buttonStyle(NeonButtonStyle())
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                    }
                } else if let failure = server.failure {
                    StateLine(kind: .error, text: failure, font: .body)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            HStack {
                Toggle(L10n.text("splash.showAtLaunch"), isOn: $showAtLaunch)
                Spacer()
                Button(L10n.text("button.close")) { dismiss() }
                    .buttonStyle(NeonButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 580)
        .background(Theme.inkColor)
        .tint(Theme.neonColor)
        .environment(\.colorScheme, .dark)
    }
}

/// A filled neon button with near-black text (the system prominent style draws white).
struct NeonButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Theme.inkColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.neonColor.opacity(configuration.isPressed ? 0.75 : 1), in: .rect(cornerRadius: 7))
            .contentShape(.rect(cornerRadius: 7))
    }
}

/// Closes on Esc like a sheet.
private final class SplashPanel: NSPanel {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor
enum AgentSplash {
    private static var window: NSWindow?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let w = SplashPanel(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        // Not drawn, but what the window is called to VoiceOver and in the Window menu.
        w.title = L10n.text("splash.window.title")
        w.isMovableByWindowBackground = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = Theme.ink
        w.isReleasedWhenClosed = false
        w.onCancel = { AgentSplash.close() }
        w.contentView = NSHostingView(rootView: AgentSplashView { AgentSplash.close() })
        w.setContentSize(w.contentView!.fittingSize)
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    static func close() {
        window?.close()
        window = nil
    }
}
