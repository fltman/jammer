import AppKit
import JammerCore

/// The automation lanes of the tracks, drawn over the waveform (View › Automation). Display only: the
/// view takes no clicks. Each line is the curve the engine is given for the track (`Project.shownLane`),
/// so a member of a VCA group shows the group's lane in its own, and a mute shows its ramps; what the
/// engine adds on top (the fader) is said in the lane's caption, not drawn into the line.
///
/// For VoiceOver the view is a group with one element a lane, and under it the lane's points that are
/// in view (at most `maxPointElements`): a lane may have 10 000 points, and a tree with all of them
/// takes seconds to read.
final class AutomationLanesView: NSView {
    static let maxPointElements = 200
    static let maxDots = 400

    let session: EditorSession
    let viewport: Viewport
    /// Which kind of lane is shown, on every track that has one. nil: none.
    var shown: AutomationLane.Param? { didSet { needsDisplay = true; elements = nil } }

    init(session: EditorSession, viewport: Viewport) {
        self.session = session
        self.viewport = viewport
        super.init(frame: .zero)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func invalidate() { needsDisplay = true; elements = nil }

    private var project: Project { session.project }
    private var laneHeight: CGFloat { (bounds.height - TimelineView.rulerHeight) / CGFloat(max(1, project.tracks.count)) }
    /// The part of a track's row the values are drawn in: its whole height but a margin.
    private func area(_ track: Int) -> NSRect {
        NSRect(x: 0, y: TimelineView.rulerHeight + CGFloat(track) * laneHeight + 6, width: bounds.width, height: max(1, laneHeight - 12))
    }
    private func y(_ value: Double, _ param: AutomationLane.Param, in r: NSRect) -> CGFloat {
        r.maxY - CGFloat(Automation.height(of: value, param)) * r.height
    }
    private var lanes: [(track: Int, lane: ShownLane)] {
        guard let shown else { return [] }
        return project.tracks.enumerated().compactMap { i, t in project.shownLane(shown, of: t.id).map { (i, $0) } }
    }
    private var view: ClosedRange<Frame> {
        let a = Frame(viewport.frame(atX: 0).rounded(.down)), b = Frame(viewport.frame(atX: bounds.width).rounded(.up))
        return a...max(a, b)
    }

    // MARK: Words

    static func valueText(_ v: Double, _ param: AutomationLane.Param) -> String {
        switch param {
        case .gain, .send: return L10n.text("automation.value.db", String(format: "%+.1f", v).replacingOccurrences(of: "-", with: "−"))
        case .pan:
            if abs(v) < 0.005 { return L10n.text("automation.value.centre") }
            let percent = String(Int((abs(v) * 100).rounded()))
            return v < 0 ? L10n.text("automation.value.left", percent) : L10n.text("automation.value.right", percent)
        case .mute: return v >= 0.5 ? L10n.text("automation.value.muted") : L10n.text("automation.value.heard")
        }
    }
    /// What the lane is, and what comes on top of its line.
    func caption(_ lane: ShownLane) -> String {
        let group = lane.group.flatMap { project.vca($0)?.name } ?? ""
        var text: String
        switch lane.param {
        case .gain, .send:
            let fader = Self.valueText(lane.onTopDB, .gain)
            if lane.group != nil, lane.own { text = L10n.text("automation.caption.level.withGroup", group, fader) }
            else if lane.group != nil { text = L10n.text("automation.caption.level.groupOnly", group, fader) }
            else { text = L10n.text("automation.caption.level", fader) }
        case .pan: text = L10n.text("automation.caption.pan")
        case .mute:
            if lane.group != nil, lane.own { text = L10n.text("automation.caption.mute.withGroup", group) }
            else if lane.group != nil { text = L10n.text("automation.caption.mute.groupOnly", group) }
            else { text = L10n.text("automation.caption.mute") }
        }
        if !lane.plays { text = L10n.text("automation.caption.off", text) }
        return text
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        for (i, lane) in lanes {
            let r = area(i)
            let colour = lane.plays ? NSColor.systemOrange : NSColor(white: 0.7, alpha: 1)
            // Where the fader alone would be (0 dB added), or the centre.
            if lane.param != .mute {
                NSColor(white: 1, alpha: 0.18).setFill()
                NSRect(x: 0, y: y(0, lane.param, in: r).rounded(), width: bounds.width, height: 1).fill()
            }
            // The line, read from the compiled curve every second point across: a straight line in dB is
            // not a straight line on this scale, and a steep ramp must not be missed.
            let path = NSBezierPath()
            var x: CGFloat = 0
            while x <= bounds.width + 2 {
                let v = lane.value(at: Frame(viewport.frame(atX: x).rounded()))
                if lane.param == .mute {
                    if v < 1 {
                        NSColor.systemRed.withAlphaComponent(0.38 * CGFloat(1 - v) * (lane.plays ? 1 : 0.4)).setFill()
                        NSRect(x: x, y: r.minY, width: 2, height: r.height).fill()
                    }
                }
                let p = NSPoint(x: x, y: y(v, lane.param, in: r))
                if path.isEmpty { path.move(to: p) } else { path.line(to: p) }
                x += 2
            }
            colour.setStroke()
            path.lineWidth = 1.5
            if !lane.plays { path.setLineDash([4, 3], count: 2, phase: 0) }
            path.stroke()
            // The corners in view.
            let points = lane.points(in: view, limit: Self.maxDots)
            // Only where they can be told apart: closer than 8 points to each other they would be a thick line.
            if points.count <= Self.maxDots, CGFloat(points.count) * 8 <= bounds.width {
                colour.setFill()
                for p in points.shown {
                    let at = NSPoint(x: viewport.x(of: Double(p.frame)), y: y(lane.value(at: p.frame), lane.param, in: r))
                    NSBezierPath(ovalIn: NSRect(x: at.x - 3, y: at.y - 3, width: 6, height: 6)).fill()
                }
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: colour,
                                                        .backgroundColor: NSColor(white: 0, alpha: 0.55)]
            // At the bottom of the row, clear of the track's name and the markers' flags at its top.
            (" \(caption(lane)) " as NSString).draw(at: NSPoint(x: 8, y: r.maxY - 12), withAttributes: attrs)
        }
    }

    // MARK: VoiceOver

    private var elements: [NSAccessibilityElement]?
    private var elementsFor: [Double] = []

    override func isAccessibilityElement() -> Bool { shown != nil }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { L10n.text("automation.ax.group") }
    override func accessibilityIdentifier() -> String { "timeline.automation" }
    override func accessibilityChildren() -> [Any]? {
        let key = [Double(session.version), viewport.start, viewport.framesPerPoint, Double(bounds.width), Double(bounds.height)]
        if let elements, key == elementsFor { return elements }
        elementsFor = key
        let rate = project.sampleRate
        let made: [NSAccessibilityElement] = lanes.map { i, lane in
            let r = area(i)
            let inView = lane.points(in: view, limit: Self.maxPointElements)
            let e = LaneElement()
            e.setAccessibilityParent(self)
            e.setAccessibilityRole(.list)
            e.setAccessibilityIdentifier("timeline.automation.lane.\(i)")
            let name = project.tracks[i].name
            switch lane.param {
            case .gain, .send: e.setAccessibilityLabel(L10n.text("automation.ax.lane.gain", name))
            case .pan: e.setAccessibilityLabel(L10n.text("automation.ax.lane.pan", name))
            case .mute: e.setAccessibilityLabel(L10n.text("automation.ax.lane.mute", name))
            }
            e.setAccessibilityValue([caption(lane), L10n.count("automation.ax.points", lane.points.count),
                                     L10n.count("automation.ax.inView", inView.count)].joined(separator: L10n.text("mixer.automation.separator")))
            e.setAccessibilityFrameInParentSpace(NSRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height))
            e.setAccessibilityChildren(inView.shown.indices.map { k in
                let p = lane.points[k]
                let c = PointElement()
                c.setAccessibilityParent(e)
                c.setAccessibilityRole(.staticText)
                c.setAccessibilityIdentifier("timeline.automation.point")
                c.setAccessibilityLabel(L10n.text("automation.ax.point", String(k + 1), String(lane.points.count)))
                c.setAccessibilityValue(L10n.text("automation.ax.point.value", formatTime(Double(p.frame) / rate), Self.valueText(p.value, lane.param)))
                let at = NSPoint(x: viewport.x(of: Double(p.frame)), y: y(lane.value(at: p.frame), lane.param, in: r))
                // In the lane's own space, from its bottom left.
                c.setAccessibilityFrameInParentSpace(NSRect(x: at.x - 4, y: r.maxY - at.y - 4, width: 8, height: 8))
                return c
            })
            return e
        }
        elements = made
        return made
    }
}

private final class LaneElement: NSAccessibilityElement {
    override func accessibilityRoleDescription() -> String? { L10n.text("automation.ax.lane.role") }
}
private final class PointElement: NSAccessibilityElement {
    override func accessibilityRoleDescription() -> String? { L10n.text("automation.ax.point.role") }
}
