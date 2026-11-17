import AppKit
import JammerAgent
import JammerCore

/// The automation lanes of the tracks, drawn over the waveform (View › Automation), and worked on by
/// hand: one lane has the focus (the shown kind, on the track last clicked or stepped to), and its
/// points are added, dragged, stepped and removed here. The view sits under the timeline's own layer and
/// takes no clicks itself; that layer offers it each click and key first (`mouseDown(_:at:)`, `key(_:)`),
/// and it takes only those that are about a point, so the timeline works as before with lanes shown.
/// Every change is one `set_automation` or `clear_automation` step: one undo step, with the step's checks.
///
/// Each line is the curve the engine is given for the track (`Project.shownLane`),
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
    var shown: AutomationLane.Param? { didSet { selected = nil; drag = nil; pending = nil; hover = nil; needsDisplay = true; elements = nil } }
    /// The track whose lane is worked on, and the point of its own lane that is selected.
    private(set) var focus = 0
    private(set) var selected: Int?
    /// A point being dragged: the lane as it would be, the point's index, and whether it has moved.
    private var drag: (lane: AutomationLane, index: Int, moved: Bool)?
    /// The lane as just sent, drawn until the document has it (so the line doesn't jump back for a moment).
    private var pending: AutomationLane?
    /// The label at the pointer: where, and what it says.
    private var hover: (at: NSPoint, text: String)?

    init(session: EditorSession, viewport: Viewport) {
        self.session = session
        self.viewport = viewport
        super.init(frame: .zero)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func invalidate() {
        if drag == nil { pending = nil }
        focus = min(focus, max(0, project.tracks.count - 1))
        if let s = selected, s >= (ownLane?.points.count ?? 0) { selected = nil }
        needsDisplay = true
        elements = nil
    }

    /// The document, with the lane being dragged or just sent in place of the stored one.
    private var shownProject: Project {
        guard let lane = drag?.lane ?? pending else { return session.project }
        var p = session.project
        try? p.setAutomation(strip: lane.strip, param: lane.param, points: lane.points)
        return p
    }
    private var focusedTrack: Track? { project.tracks[safe: focus] }
    /// The focused track's own lane of the shown kind, as stored (or as dragged).
    private var ownLane: AutomationLane? {
        guard let shown, let t = focusedTrack else { return nil }
        if let l = drag?.lane ?? pending, l.strip == t.id, l.param == shown { return l }
        return project.lane(strip: t.id, param: shown)
    }
    /// The same, or an empty one to put the first point in.
    private func laneToChange() -> AutomationLane? {
        guard let shown, let t = focusedTrack else { return nil }
        return ownLane ?? AutomationLane(strip: t.id, param: shown, shape: shown == .mute ? .hold : .linear, points: [])
    }
    /// Where a point of the own lane is drawn. A mute's point sits at the top when the track is heard from there, at the bottom when muted.
    private func place(_ p: AutomationPoint, _ param: AutomationLane.Param, in r: NSRect) -> NSPoint {
        NSPoint(x: viewport.x(of: Double(p.frame)), y: y(param == .mute ? 1 - p.value : p.value, param, in: r))
    }

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
        let p = shownProject
        return p.tracks.enumerated().compactMap { i, t in p.shownLane(shown, of: t.id).map { (i, $0) } }
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
        guard let shown else { return }
        let all = lanes
        // The focused track: a bar at its left edge, and where a first point would go when it has no lane.
        if project.tracks.indices.contains(focus) {
            let r = area(focus)
            NSColor.systemOrange.setFill()
            NSRect(x: 0, y: r.minY - 6, width: 3, height: r.height + 12).fill()
            if !all.contains(where: { $0.track == focus }) {
                NSColor.systemOrange.withAlphaComponent(0.35).setFill()
                NSRect(x: 0, y: y(shown == .mute ? 1 : 0, shown, in: r).rounded(), width: bounds.width, height: 1).fill()
                drawCaption(L10n.text("automation.caption.empty"), track: focus, colour: NSColor.systemOrange.withAlphaComponent(0.8))
            }
        }
        for (i, lane) in all {
            let r = area(i)
            let focused = i == focus
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
            path.lineWidth = focused ? 2.5 : 1.5
            if !lane.plays { path.setLineDash([4, 3], count: 2, phase: 0) }
            path.stroke()
            if focused, let own = ownLane {
                // The lane's own points are what is moved. Where a group's lane is in the heard line, the
                // own lane is drawn thin beside it, with the points on it.
                if lane.group != nil, lane.plays {
                    let thin = NSBezierPath()
                    var x: CGFloat = 0
                    while x <= bounds.width + 2 {
                        let p = NSPoint(x: x, y: y(own.valueOrRest(at: Frame(viewport.frame(atX: x).rounded())), lane.param, in: r))
                        if thin.isEmpty { thin.move(to: p) } else { thin.line(to: p) }
                        x += 2
                    }
                    colour.withAlphaComponent(0.55).setStroke()
                    thin.lineWidth = 1
                    thin.stroke()
                }
                let range = view
                for (k, p) in own.points.enumerated() where range.contains(p.frame) {
                    let at = place(p, lane.param, in: r)
                    let box = NSRect(x: at.x - 4.5, y: at.y - 4.5, width: 9, height: 9)
                    (k == selected ? NSColor.white : colour).setFill()
                    NSBezierPath(ovalIn: box).fill()
                    NSColor.black.withAlphaComponent(0.6).setStroke()
                    NSBezierPath(ovalIn: box).stroke()
                    if k == selected {
                        colour.setStroke()
                        let ring = NSBezierPath(ovalIn: box.insetBy(dx: -3, dy: -3))
                        ring.lineWidth = 2
                        ring.stroke()
                    }
                }
            } else {
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
            }
            drawCaption(caption(lane), track: i, colour: colour)
        }
        if let hover {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.white]
            let text = hover.text as NSString
            let size = text.size(withAttributes: attrs)
            var at = NSPoint(x: hover.at.x + 12, y: hover.at.y - size.height - 10)
            at.x = min(at.x, bounds.width - size.width - 10)
            at.y = max(TimelineView.rulerHeight + 2, at.y)
            NSColor(white: 0, alpha: 0.85).setFill()
            NSBezierPath(roundedRect: NSRect(x: at.x - 5, y: at.y - 2, width: size.width + 10, height: size.height + 4), xRadius: 4, yRadius: 4).fill()
            text.draw(at: at, withAttributes: attrs)
        }
    }

    static let nameFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    /// The caption has a place of its own: on a plate, on the line of the track's name and after it.
    private func drawCaption(_ text: String, track: Int, colour: NSColor) {
        let top = TimelineView.rulerHeight + CGFloat(track) * laneHeight
        let name = (project.tracks[track].name as NSString).size(withAttributes: [.font: Self.nameFont]).width
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: colour]
        let size = (text as NSString).size(withAttributes: attrs)
        let at = NSPoint(x: 8 + name + 14, y: top + 23)
        NSColor(white: 0, alpha: 0.8).setFill()
        NSBezierPath(roundedRect: NSRect(x: at.x - 5, y: at.y - 2, width: size.width + 10, height: size.height + 4), xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(at: at, withAttributes: attrs)
    }

    // MARK: By hand

    private func track(atY py: CGFloat) -> Int? {
        guard py >= TimelineView.rulerHeight, !project.tracks.isEmpty else { return nil }
        return min(project.tracks.count - 1, Int((py - TimelineView.rulerHeight) / laneHeight))
    }
    private func send(_ lane: AutomationLane, saying: String? = nil) {
        pending = lane
        let name = lane.strip.uuidString, rate = project.sampleRate
        if lane.points.isEmpty {
            pending = nil
            session.perform("clear_automation", ["strip": .string(name), "param": .string(lane.param.rawValue)], saying: saying)
        } else {
            session.perform("set_automation", ["strip": .string(name), "param": .string(lane.param.rawValue),
                                               "points": .array(lane.points.map { .array([.number(Double($0.frame) / rate), .number($0.value)]) })], saying: saying)
        }
        needsDisplay = true
        elements = nil
    }
    /// What a point is called and worth: the status line's text when it is selected or moved, and VoiceOver's.
    private func describe(_ lane: AutomationLane, _ i: Int) -> String {
        let p = lane.points[i]
        return L10n.text("automation.point.status", String(i + 1), String(lane.points.count), formatTime(Double(p.frame) / project.sampleRate), Self.valueText(p.value, lane.param))
    }
    private func select(_ i: Int?, seek: Bool = false) {
        selected = i
        if let i, let lane = ownLane, lane.points.indices.contains(i) {
            if seek { session.seek(lane.points[i].frame) }
            let text = describe(lane, i)
            session.status = text
            NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        needsDisplay = true
        elements = nil
    }
    /// What is said at the pointer: the time and the lane's value there, and for a level what is heard with the group's lane and the fader.
    private func label(_ lane: AutomationLane, frame: Frame, value: Double) -> String {
        let time = formatTime(Double(frame) / project.sampleRate)
        if lane.param == .gain, let t = focusedTrack, let shownLane = shownProject.shownLane(.gain, of: t.id), shownLane.plays {
            return L10n.text("automation.label.heard", time, Self.valueText(value, .gain), Self.valueText(shownLane.value(at: frame) + shownLane.onTopDB, .gain))
        }
        return L10n.text("automation.label", time, Self.valueText(value, lane.param))
    }
    /// A time near something worth landing on (the playhead, a marker, a clip's edge on the track, the selection's ends), within 6 points on the screen.
    private func snapped(_ frame: Frame) -> Frame {
        var to: [Frame] = [session.playhead]
        for m in project.markers { to.append(m.position); if m.length > 0 { to.append(m.position + m.length) } }
        for c in focusedTrack?.clips ?? [] { to.append(c.start); to.append(c.end) }
        if let s = session.selection { to.append(s.lowerBound); to.append(s.upperBound) }
        let reach = 6 * viewport.framesPerPoint
        let best = to.min { abs($0 - frame) < abs($1 - frame) }
        return best.map { abs(Double($0 - frame)) <= reach ? $0 : frame } ?? frame
    }

    /// A click in the timeline, offered here first. True: it was about a point, and the timeline leaves it alone.
    func mouseDown(_ event: NSEvent, at p: NSPoint) -> Bool {
        guard let shown, let t = track(atY: p.y) else { return false }
        if t != focus { focus = t; selected = nil; needsDisplay = true; elements = nil }
        let r = area(t)
        if let own = ownLane, let k = own.points.indices.min(by: { hypot(place(own.points[$0], shown, in: r).x - p.x, place(own.points[$0], shown, in: r).y - p.y)
                                                                    < hypot(place(own.points[$1], shown, in: r).x - p.x, place(own.points[$1], shown, in: r).y - p.y) }),
           hypot(place(own.points[k], shown, in: r).x - p.x, place(own.points[k], shown, in: r).y - p.y) <= 8 {
            select(k)
            drag = (own, k, false)
            return true
        }
        guard event.modifierFlags.contains(.option), event.clickCount == 1, let lane = laneToChange() else {
            if selected != nil { selected = nil; needsDisplay = true; elements = nil }
            return false
        }
        // ⌥-click: a point at the pointer's time. On the line (within 6 points of it) it takes the line's value,
        // so adding it changes nothing that is heard; elsewhere in the row it takes the pointer's height.
        // A mute's new point is the other state from there on.
        let frame = min(max(0, Frame(viewport.frame(atX: p.x).rounded())), project.length)
        let rest = lane.valueOrRest(at: frame)
        let value: Double
        if shown == .mute { value = rest >= 0.5 ? 0 : 1 }
        else if abs(y(rest, shown, in: r) - p.y) <= 6 { value = rest }
        else { value = Automation.value(atHeight: Double((r.maxY - p.y) / r.height), shown) }
        guard let added = lane.adding(frame: frame, value: value) else { NSSound.beep(); return true }
        selected = added.index
        send(added.lane, saying: describe(added.lane, added.index))
        return true
    }
    func mouseDragged(_ event: NSEvent, at p: NSPoint) -> Bool {
        guard let shown, var d = drag else { return false }
        let r = area(focus), old = d.lane.points[d.index], flags = event.modifierFlags
        var frame = Frame(viewport.frame(atX: p.x).rounded())
        var value = Automation.value(atHeight: Double((r.maxY - p.y) / r.height), shown)
        if !flags.contains(.control) {
            frame = snapped(frame)
            // 0 dB, or the centre, within 4 points.
            if shown != .mute, abs(y(0, shown, in: r) - p.y) <= 4 { value = 0 }
        }
        if flags.contains(.shift) { frame = old.frame }          // ⇧: the value only
        if flags.contains(.command) || shown == .mute { value = old.value }   // ⌘: the time only; a mute is moved sideways
        d.lane = d.lane.moving(d.index, frame: frame, value: value, limit: project.length)
        d.moved = d.moved || d.lane.points[d.index] != old
        drag = d
        let now = d.lane.points[d.index]
        hover = (place(now, shown, in: r), label(d.lane, frame: now.frame, value: now.value))
        needsDisplay = true
        return true
    }
    func mouseUp(_ event: NSEvent, at p: NSPoint) -> Bool {
        guard let shown, let d = drag else { return false }
        drag = nil
        hover = nil
        if d.moved {
            send(d.lane, saying: describe(d.lane, d.index))
        } else if shown == .mute {
            // A click on a mute's point flips it.
            var lane = d.lane
            lane.points[d.index].value = lane.points[d.index].value >= 0.5 ? 0 : 1
            send(lane, saying: describe(lane, d.index))
        }
        needsDisplay = true
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseExited(with event: NSEvent) { if drag == nil, hover != nil { hover = nil; needsDisplay = true } }
    /// The value at the pointer, while it is on the focused lane's line.
    override func mouseMoved(with event: NSEvent) {
        guard let shown, drag == nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        var now: (NSPoint, String)?
        if track(atY: p.y) == focus, let lane = laneToChange(), shown != .mute {
            let frame = min(max(0, Frame(viewport.frame(atX: p.x).rounded())), project.length)
            let v = lane.valueOrRest(at: frame)
            if abs(y(v, shown, in: area(focus)) - p.y) <= 6 { now = (p, label(lane, frame: frame, value: v)) }
        }
        if (now == nil) != (hover == nil) || now?.1 != hover?.text { needsDisplay = true }
        hover = now.map { ($0.0, $0.1) }
    }

    /// A key in the timeline, offered here first. True: it was about a lane or a point.
    func key(_ event: NSEvent) -> Bool {
        guard let shown, !project.tracks.isEmpty else { return false }
        let flags = event.modifierFlags.intersection([.option, .shift, .command, .control])
        let rate = project.sampleRate
        switch (event.keyCode, flags) {
        case (125, [.option]), (126, [.option]):     // ⌥↓ ⌥↑: the lane of the next or the previous track
            focus = min(project.tracks.count - 1, max(0, focus + (event.keyCode == 125 ? 1 : -1)))
            selected = nil
            session.status = L10n.text("automation.focus.status", project.tracks[focus].name)
            needsDisplay = true
            elements = nil
            return true
        case (124, [.option]), (123, [.option]):     // ⌥→ ⌥←: the next or the previous point
            guard let lane = ownLane, !lane.points.isEmpty else { NSSound.beep(); return true }
            let forward = event.keyCode == 124
            let next: Int?
            if let s = selected { next = forward ? s + 1 : s - 1 }
            else { next = forward ? lane.points.firstIndex { $0.frame > session.playhead } : lane.points.lastIndex { $0.frame < session.playhead } }
            guard let k = next, lane.points.indices.contains(k) else { NSSound.beep(); return true }
            select(k, seek: true)
            return true
        case (36, [.option]):                        // ⌥Return: a point at the playhead, at the line's value there
            guard let lane = laneToChange() else { return true }
            let rest = lane.valueOrRest(at: session.playhead)
            guard let added = lane.adding(frame: session.playhead, value: shown == .mute ? (rest >= 0.5 ? 0 : 1) : rest) else { NSSound.beep(); return true }
            selected = added.index
            send(added.lane, saying: describe(added.lane, added.index))
            return true
        default: break
        }
        guard let k = selected, let lane = ownLane, lane.points.indices.contains(k) else { return false }
        let p = lane.points[k]
        func move(frame: Frame = p.frame, value: Double = p.value) {
            let moved = lane.moving(k, frame: frame, value: value, limit: project.length)
            guard moved != lane else { NSSound.beep(); return }
            send(moved, saying: describe(moved, k))
        }
        let up = event.keyCode == 126
        switch (event.keyCode, flags) {
        case (126, []), (125, []):                   // ↑ ↓: 0.5 dB, 5 %; a mute flips
            move(value: Automation.stepped(p.value, by: (shown == .pan ? -0.05 : 0.5) * (up ? 1 : -1), grain: shown == .pan ? 0.01 : 0.1, shown))
        case (126, [.shift]), (125, [.shift]):       // ⇧: 0.1 dB, 1 %
            move(value: Automation.stepped(p.value, by: (shown == .pan ? -0.01 : 0.1) * (up ? 1 : -1), grain: shown == .pan ? 0.01 : 0.1, shown))
        case (126, [.option, .shift]), (125, [.option, .shift]):   // ⌥⇧: 3 dB, 25 %
            move(value: Automation.stepped(p.value, by: (shown == .pan ? -0.25 : 3) * (up ? 1 : -1), grain: shown == .pan ? 0.01 : 0.1, shown))
        case (124, [.option, .shift]), (123, [.option, .shift]):   // ⌥⇧→ ⌥⇧←: 10 ms
            move(frame: p.frame + Frame((0.01 * rate).rounded()) * (event.keyCode == 124 ? 1 : -1))
        case (124, [.option, .command]), (123, [.option, .command]):   // ⌘⌥→ ⌘⌥←: one frame
            move(frame: p.frame + (event.keyCode == 124 ? 1 : -1))
        case (51, []), (117, []):                    // Delete: the point; the lane's last point takes the lane with it, and the status line says so
            var less = lane
            less.points.remove(at: k)
            // The point before it is selected next (or the first), so the keys alone can go on to an empty lane.
            selected = less.points.isEmpty ? nil : max(0, k - 1)
            let name = project.tracks[focus].name
            let gone: String
            switch shown {
            case .gain, .send: gone = L10n.text("automation.removed.gain", name)
            case .pan: gone = L10n.text("automation.removed.pan", name)
            case .mute: gone = L10n.text("automation.removed.mute", name)
            }
            send(less, saying: less.points.isEmpty ? gone : L10n.text("automation.point.removed", L10n.count("automation.ax.points", less.points.count)))
        case (53, []):                               // Escape: nothing selected; the keys are the timeline's again
            selected = nil
            needsDisplay = true
            elements = nil
        default: return false
        }
        return true
    }

    // MARK: VoiceOver

    private var elements: [NSAccessibilityElement]?
    private var elementsFor: [Double] = []

    override func isAccessibilityElement() -> Bool { shown != nil }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { L10n.text("automation.ax.group") }
    override func accessibilityIdentifier() -> String { "timeline.automation" }
    override func accessibilityChildren() -> [Any]? {
        let key = [Double(session.version), viewport.start, viewport.framesPerPoint, Double(bounds.width), Double(bounds.height), Double(focus), Double(selected ?? -1)]
        if let elements, key == elementsFor { return elements }
        elementsFor = key
        let rate = project.sampleRate
        let made: [NSAccessibilityElement] = lanes.map { i, lane in
            let r = area(i)
            // The focused track's own points are the ones that can be moved; they are what is named there.
            let own = i == focus ? ownLane : nil
            let named = own.map { o in var l = lane; l.points = o.points; return l } ?? lane
            let inView = named.points(in: view, limit: Self.maxPointElements)
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
            e.setAccessibilityValue([caption(lane), L10n.count("automation.ax.points", named.points.count),
                                     L10n.count("automation.ax.inView", inView.count)].joined(separator: L10n.text("mixer.automation.separator")))
            e.setAccessibilityFrameInParentSpace(NSRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height))
            e.setAccessibilityChildren(inView.shown.indices.map { k in
                let p = named.points[k]
                let c = PointElement()
                c.setAccessibilityParent(e)
                c.setAccessibilityRole(.staticText)
                c.setAccessibilityIdentifier("timeline.automation.point")
                c.setAccessibilityLabel(L10n.text("automation.ax.point", String(k + 1), String(named.points.count)))
                c.setAccessibilitySelected(own != nil && k == selected)
                c.setAccessibilityValue(L10n.text("automation.ax.point.value", formatTime(Double(p.frame) / rate), Self.valueText(p.value, lane.param)))
                let at = own != nil ? place(p, lane.param, in: r) : NSPoint(x: viewport.x(of: Double(p.frame)), y: y(lane.value(at: p.frame), lane.param, in: r))
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
