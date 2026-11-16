import AppKit
import SwiftUI

/// The soft light behind the app's icon, breathing slowly (the series' shared look). Only the light
/// moves; whatever is drawn over it stands still.
///
/// It is a Core Animation layer with two animations that the window server runs by itself, so the app
/// does no work per frame. And it runs only while it can be seen and nothing more important is going
/// on: not when the window is hidden, minimised or covered, not when the app is in the background, not
/// while any document plays (the transport must never wait for decoration), and never with Reduce
/// Motion on; then the light stands still at its normal strength.
struct PulsingGlow: NSViewRepresentable {
    var color: NSColor = Theme.neon
    func makeNSView(context: Context) -> GlowView { GlowView(color: color) }
    func updateNSView(_ view: GlowView, context: Context) {}

    /// Posted when playback starts or stops in any document.
    static let transportChanged = Notification.Name("JammerTransportChanged")
    /// One breath, out and in, in seconds.
    static let breath = 4.0
    static let still: Float = 0.8

    final class GlowView: NSView {
        private let glow = CAGradientLayer()
        private var observers: [NSObjectProtocol] = []
        private(set) var isBreathing = false

        init(color: NSColor) {
            super.init(frame: .zero)
            wantsLayer = true
            glow.type = .radial
            glow.colors = [color.withAlphaComponent(0.55).cgColor, color.withAlphaComponent(0.18).cgColor, color.withAlphaComponent(0).cgColor]
            glow.locations = [0, 0.55, 1]
            glow.startPoint = CGPoint(x: 0.5, y: 0.5)
            glow.endPoint = CGPoint(x: 1, y: 1)
            glow.opacity = PulsingGlow.still
            layer?.addSublayer(glow)
            // Nothing here for an assistive technology: no element, no value that changes.
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glow.frame = bounds
            CATransaction.commit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for o in observers { NotificationCenter.default.removeObserver(o); NSWorkspace.shared.notificationCenter.removeObserver(o) }
            observers = []
            guard let window else { stop(); return }
            let center = NotificationCenter.default
            let again: (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.decide() } }
            observers = [
                center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main, using: again),
                center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: again),
                center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: again),
                center.addObserver(forName: PulsingGlow.transportChanged, object: nil, queue: .main, using: again),
                NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main, using: again),
            ]
            decide()
        }

        private func decide() {
            let seen = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
            let playing = AgentRegistry.shared.sessions.contains { $0.isPlaying }
            let wanted = seen && NSApp.isActive && !playing && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if wanted { start() } else { stop() }
        }

        private func start() {
            guard !isBreathing else { return }
            isBreathing = true
            func breathing(_ key: String, from: Double, to: Double) -> CABasicAnimation {
                let a = CABasicAnimation(keyPath: key)
                a.fromValue = from
                a.toValue = to
                a.duration = PulsingGlow.breath / 2
                a.autoreverses = true
                a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                return a
            }
            // Strength between 60 % and 100 %, and the radius breathing lightly with it.
            glow.add(breathing("opacity", from: 0.6, to: 1), forKey: "breath.opacity")
            glow.add(breathing("transform.scale", from: 0.94, to: 1), forKey: "breath.scale")
        }

        private func stop() {
            guard isBreathing else { return }
            isBreathing = false
            glow.removeAllAnimations()
            glow.opacity = PulsingGlow.still
        }
    }
}
