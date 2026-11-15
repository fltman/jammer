import AppKit
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
                    .shadow(color: Theme.neonColor.opacity(0.5), radius: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "Jämmer").font(.largeTitle.bold())
                        .shadow(color: Theme.neonColor.opacity(0.6), radius: 10)
                    Text("An audio editor for the Mac that agents can drive too.")
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("For your agent").font(.headline)
                Text("Paste this into Claude or another AI agent. It fetches the guide from Jämmer on this Mac and can then open, measure, edit and export audio in your open windows.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let prompt = server.agentPrompt {
                    HStack(alignment: .top, spacing: 8) {
                        Text(verbatim: prompt)
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.05), in: .rect(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.neonColor.opacity(0.55)))
                            .accessibilityLabel("Text for your agent")
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(prompt, forType: .string)
                            copied = true
                            Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                        } label: {
                            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .frame(minWidth: 70)
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.neonColor)
                        .foregroundStyle(.black)
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                    }
                } else if let failure = server.failure {
                    Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            HStack {
                Toggle("Show at launch", isOn: $showAtLaunch)
                Spacer()
                Button("Close") { dismiss() }
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

@MainActor
enum AgentSplash {
    private static var window: NSWindow?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = Theme.ink
        w.isReleasedWhenClosed = false
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
