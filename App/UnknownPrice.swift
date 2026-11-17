import AppKit
import SwiftUI

/// Allowing a paid request is not allowing any price (the-apps/SIBLINGS.md, "Okänt pris"). Where Jämmer
/// has no price for a service, the window asks once per service, keeps the answer where it can be taken
/// back (Settings › Paid Services), and says that the price is unknown every time all the same. An
/// agent's request carries `allowUnknownPrice` every time; nothing here answers for an agent.
@MainActor
enum UnknownPrice {
    private static let key = "paid.unknownPriceAccepted"
    private static var stored: [String: String] { UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }

    /// The services the user has said may be used without a known price: id and the name shown.
    static var accepted: [(id: String, name: String)] { stored.map { ($0.key, $0.value) }.sorted { $0.name < $1.name } }
    static func isAccepted(_ service: String) -> Bool { stored[service] != nil }
    static func accept(_ service: String, name: String) {
        var s = stored
        s[service] = name
        UserDefaults.standard.set(s, forKey: key)
    }
    static func takeBack(_ service: String) {
        var s = stored
        s[service] = nil
        UserDefaults.standard.set(s, forKey: key)
    }
}

/// What a sheet before a paid request with no known price carries: a box to tick the first time (Send
/// stays grey until it is), and afterwards the same fact as a line.
@MainActor
final class UnknownPriceBox: NSObject {
    let view: NSView
    private let service: String, name: String
    private let box: NSButton?
    private weak var send: NSButton?

    init(service: String, name: String, width: CGFloat = 380) {
        self.service = service
        self.name = name
        if UnknownPrice.isAccepted(service) {
            let line = NSTextField(wrappingLabelWithString: L10n.text("paid.unknownPrice.accepted", name))
            line.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            line.preferredMaxLayoutWidth = width
            line.frame.size = line.sizeThatFits(NSSize(width: width, height: 400))
            line.setAccessibilityIdentifier("paid.unknownPrice.line")
            view = line
            box = nil
        } else {
            let b = NSButton(checkboxWithTitle: L10n.text("paid.unknownPrice.tick", name), target: nil, action: nil)
            b.setAccessibilityIdentifier("paid.unknownPrice")
            b.sizeToFit()
            view = b
            box = b
        }
        super.init()
        box?.target = self
        box?.action = #selector(changed)
    }

    /// Puts `views` one under the other as the alert's accessory view, with their left edge under the
    /// left edge of the alert's text. (An alert places its accessory view by its own rules, which differ
    /// with the view's width; so the difference is measured when the alert is shown.)
    static func place(_ views: [NSView], in alert: NSAlert) {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        let height = views.reduce(0) { $0 + $1.frame.height } + CGFloat(views.count - 1) * 10
        // Room to move in: the measured inset is at most this.
        stack.frame = NSRect(x: 0, y: 0, width: 44 + (views.map(\.frame.width).max() ?? 0), height: height)
        alert.accessoryView = stack
        // Measured once the alert is on the screen: where it puts the view is only settled then.
        DispatchQueue.main.async {
            func find(_ v: NSView) -> NSTextField? {
                if let f = v as? NSTextField, f.stringValue == alert.informativeText { return f }
                for s in v.subviews { if let f = find(s) { return f } }
                return nil
            }
            guard stack.window != nil, let content = alert.window.contentView, let text = find(content) else { return }
            let want = text.convert(text.bounds, to: nil).minX, have = stack.convert(stack.bounds, to: nil).minX
            stack.edgeInsets = NSEdgeInsets(top: 0, left: min(44, max(0, want - have)), bottom: 0, right: 0)
        }
    }

    /// Keeps `button` disabled until the box is ticked (or was, an earlier time).
    func gate(_ button: NSButton) {
        send = button
        button.isEnabled = box.map { $0.state == .on } ?? true
    }
    /// The request is going: a tick made now is kept for the service.
    func sent() { if box?.state == .on { UnknownPrice.accept(service, name: name) } }

    @objc private func changed() { send?.isEnabled = box?.state == .on }
}

/// Settings › Paid Services: where an answer about an unknown price is taken back.
struct PaidSettings: View {
    @State private var accepted = UnknownPrice.accepted

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("paid.settings.about")).fixedSize(horizontal: false, vertical: true)
            if accepted.isEmpty {
                Text(L10n.text("paid.settings.none")).foregroundStyle(.secondary).accessibilityIdentifier("paid.settings.none")
            }
            ForEach(accepted, id: \.id) { s in
                HStack {
                    Text(L10n.text("paid.settings.row", s.name))
                    Spacer()
                    Button(L10n.text("paid.settings.takeBack")) {
                        UnknownPrice.takeBack(s.id)
                        accepted = UnknownPrice.accepted
                    }
                    .accessibilityIdentifier("paid.settings.takeBack.\(s.id)")
                }
            }
            Spacer()
        }
        .padding(20)
        .frame(width: 520)
        .frame(maxHeight: .infinity, alignment: .top)
        // The window is kept between showings, and an answer may be given while it is open.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let now = UnknownPrice.accepted
            if now.map(\.id) != accepted.map(\.id) { accepted = now }
        }
    }
}
