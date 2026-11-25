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

    /// What the view's rows are: the tracks (over the waveform, under the timeline's own layer), or the
    /// strips that have no waveform (buses, VCA groups and the master, in thin rows of their own under the tracks).
    enum Rows { case tracks, strips }
    struct Row { let id: UUID; let name: String; let clips: [Clip] }

    let session: EditorSession
    let viewport: Viewport
    let rows: Rows
    /// Whether this view's focused lane is the one the keys work on (one of the two views is).
    var isActive = true { didSet { if !isActive { selected = nil; drag = nil; hover = nil }; needsDisplay = true; elements = nil } }
    /// Called when a click made this view the one worked in.
    var onActivate: () -> Void = {}
    /// Which kind of lane is shown, on every row that has one. nil: none.
    var shown: AutomationLane.Param? { didSet { selected = nil; drag = nil; pending = nil; hover = nil; needsDisplay = true; elements = nil } }
    /// The track whose lane is worked on, and the point of its own lane that is selected.
    private(set) var focus = 0
    private(set) var selected: Int? { didSet { if selected == nil { others = [] } } }
    /// The points selected besides that one. They move, step and go together, as one piece.
    private var others: Set<Int> = []
    private var chosen: Set<Int> { selected.map { others.union([$0]) } ?? [] }
    /// A stretch being dragged out with ⌥⇧ to select the points in it: where it began and where the pointer is.
    private var marquee: (from: CGFloat, to: CGFloat)?
    /// Esc during a drag or a marquee: everything is as before it, and its mouse-up does nothing (COMFORT 41).
    private var cancelled = false
    /// A point pressed with ⇧ and not yet moved: let go like that, it joins or leaves the selected ones.
    private var toggleOnUp: Int?
    /// A point being dragged: the lane as it would be, the point's index, and whether it has moved.
    private var drag: (lane: AutomationLane, index: Int, moved: Bool, origin: AutomationLane)?
    /// The lane as just sent, drawn until the document has it (so the line doesn't jump back for a moment).
    private var pending: AutomationLane?
    /// Arrow-key nudges held back while the key is down: shown at once, sent as one step when it comes up (COMFORT 12:
    /// holding ↑ is one undo step, not one per repeat).
    private var heldNudge: (lane: AutomationLane, saying: String?)?
    /// The label at the pointer: where, and what it says.
    private var hover: (at: NSPoint, text: String)?

    init(session: EditorSession, viewport: Viewport, rows: Rows = .tracks) {
        self.session = session
        self.viewport = viewport
        self.rows = rows
        super.init(frame: .zero)
        isActive = rows == .tracks
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    /// Over the tracks the timeline's own layer takes the clicks and offers them here; the strips' rows take their own.
    override func hitTest(_ point: NSPoint) -> NSView? { rows == .tracks ? nil : super.hitTest(point) }
    override func mouseDown(with event: NSEvent) {
        onActivate()
        let p = convert(event.locationInWindow, from: nil)
        if mouseDown(event, at: p) { return }
        // Elsewhere in a row: the playhead, as in the timeline.
        session.seek(Frame(max(0, min(Double(project.length), viewport.frame(atX: p.x))).rounded()))
    }
    override func mouseDragged(with event: NSEvent) { _ = mouseDragged(event, at: convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) { _ = mouseUp(event, at: convert(event.locationInWindow, from: nil)) }

    /// The rows, top to bottom. Among the strips only those that can have a lane of the shown kind:
    /// a VCA group has a level and a mute, the master a level.
    var rowList: [Row] {
        let p = session.project
        if rows == .tracks { return p.tracks.map { Row(id: $0.id, name: $0.name, clips: $0.clips) } }
        guard let shown else { return [] }
        if shown == .send { return p.buses.filter { !$0.sends.isEmpty }.map { Row(id: $0.id, name: $0.name, clips: []) } }
        var out = p.buses.map { Row(id: $0.id, name: $0.name, clips: []) }
        if shown == .gain || shown == .mute { out += p.vcas.map { Row(id: $0.id, name: $0.name, clips: []) } }
        if shown == .gain { out.append(Row(id: Master.id, name: L10n.text("automation.row.master"), clips: [])) }
        return out
    }
    private var topInset: CGFloat { rows == .tracks ? TimelineView.rulerHeight : 0 }
    private var margin: CGFloat { rows == .tracks ? 6 : 3 }

    func invalidate() {
        if drag == nil, heldNudge == nil { pending = nil }
        focus = min(focus, max(0, rowList.count - 1))
        let count = ownLane?.points.count ?? 0
        if let s = selected, s >= count { selected = nil }
        others = others.filter { $0 < count }
        needsDisplay = true
        elements = nil
    }

    /// The document, with the lane being dragged or just sent in place of the stored one.
    private var shownProject: Project {
        guard let lane = drag?.lane ?? pending else { return session.project }
        var p = session.project
        try? p.setAutomation(strip: lane.strip, param: lane.param, to: lane.to, points: lane.points)
        return p
    }
    private var focusedTrack: Row? { rowList[safe: focus] }
    /// Send lanes: which of a strip's sends is shown, where it has more than one (⌥Tab goes to the next). By the bus it goes to.
    private var sendShown: [UUID: UUID] = [:]
    /// Plugin parameter lanes: which of a strip's is shown (⌥Tab goes to the next), by its plugin and parameter.
    private var pluginShown: [UUID: AutomationLane] = [:]
    /// The plugin parameter lane shown on a strip: the one chosen, or its first.
    private func pluginTarget(_ strip: UUID) -> AutomationLane? {
        guard shown == .plugin else { return nil }
        let all = project.lanes(of: strip).filter { $0.param == .plugin }
        return all.first { $0.insert == pluginShown[strip]?.insert && $0.parameter == pluginShown[strip]?.parameter } ?? all.first
    }
    /// A plugin parameter's range, as the running plugin gives it (0 to 1 when it isn't running).
    private func pluginRange(_ lane: AutomationLane?) -> ClosedRange<Double> {
        guard let lane, let insert = lane.insert, let unit = session.inserts.instance(insert),
              let p = unit.parameters.first(where: { $0.identifier == lane.parameter }), p.max > p.min else { return 0...1 }
        return Double(p.min)...Double(p.max)
    }
    /// The name a running plugin gives a lane's parameter, and the plugin's name on the strip.
    private func pluginNames(_ lane: AutomationLane) -> (parameter: String, plugin: String) {
        let insert = project.inserts(of: lane.strip).first { $0.id == lane.insert }
        let name = lane.insert.flatMap { session.inserts.instance($0) }?.parameters.first { $0.identifier == lane.parameter }?.name
        return (name ?? lane.parameter ?? "", insert?.name ?? "")
    }
    /// The row an area belongs to.
    private func row(of r: NSRect) -> Int { Int(((r.midY - topInset) / laneHeight).rounded(.down)) }
    /// Where a value sits in a row's height: a plugin's parameter by its own range, every other kind by its scale.
    private func height(_ value: Double, _ param: AutomationLane.Param, in r: NSRect) -> Double {
        guard param == .plugin else { return Automation.height(of: value, param) }
        let g = pluginRange(rowList[safe: row(of: r)].flatMap { pluginTarget($0.id) })
        return (min(g.upperBound, max(g.lowerBound, value)) - g.lowerBound) / (g.upperBound - g.lowerBound)
    }
    private func valueAt(height h: Double, _ param: AutomationLane.Param, in r: NSRect) -> Double {
        guard param == .plugin else { return Automation.value(atHeight: h, param) }
        let g = pluginRange(rowList[safe: row(of: r)].flatMap { pluginTarget($0.id) })
        return g.lowerBound + min(1, max(0, h)) * (g.upperBound - g.lowerBound)
    }
    private func sends(of strip: UUID) -> [Send] {
        project.tracks.first { $0.id == strip }?.sends ?? project.buses.first { $0.id == strip }?.sends ?? []
    }
    /// The bus the shown send of a strip goes to, when send lanes are shown and the strip has a send.
    private func target(_ strip: UUID) -> UUID? {
        guard shown == .send else { return nil }
        let all = sends(of: strip)
        return all.first { $0.to == sendShown[strip] }?.to ?? all.first?.to
    }
    /// The focused track's own lane of the shown kind, as stored (or as dragged).
    private var ownLane: AutomationLane? {
        guard let shown, let t = focusedTrack else { return nil }
        let to = target(t.id)
        if shown == .send, to == nil { return nil }
        let pl = pluginTarget(t.id)
        if shown == .plugin, pl == nil { return nil }
        if let l = drag?.lane ?? pending, l.strip == t.id, l.param == shown, l.to == to, l.insert == pl?.insert, l.parameter == pl?.parameter { return l }
        return project.lane(strip: t.id, param: shown, to: to, insert: pl?.insert, parameter: pl?.parameter)
    }
    /// The same, or an empty one to put the first point in.
    private func laneToChange() -> AutomationLane? {
        guard let shown, let t = focusedTrack else { return nil }
        let to = target(t.id)
        if shown == .send, to == nil { return nil }     // no send, nothing to automate
        // A plugin's parameter lane is made by a step (which parameter can't be told by a click); here it is drawn and changed.
        if shown == .plugin { return ownLane }
        return ownLane ?? AutomationLane(strip: t.id, param: shown, to: to, shape: shown == .mute ? .hold : .linear, points: [])
    }
    /// Where a point of the own lane is drawn. A mute's point sits at the top when the track is heard from there, at the bottom when muted.
    private func place(_ p: AutomationPoint, _ param: AutomationLane.Param, in r: NSRect) -> NSPoint {
        NSPoint(x: viewport.x(of: Double(p.frame)), y: y(param == .mute ? 1 - p.value : p.value, param, in: r))
    }

    private var project: Project { session.project }
    private var laneHeight: CGFloat { (bounds.height - topInset) / CGFloat(max(1, rowList.count)) }
    /// The part of a track's row the values are drawn in: its whole height but a margin.
    private func area(_ track: Int) -> NSRect {
        NSRect(x: 0, y: topInset + CGFloat(track) * laneHeight + margin, width: bounds.width, height: max(1, laneHeight - 2 * margin))
    }
    private func y(_ value: Double, _ param: AutomationLane.Param, in r: NSRect) -> CGFloat {
        r.maxY - CGFloat(height(value, param, in: r)) * r.height
    }
    private var lanes: [(track: Int, lane: ShownLane)] {
        guard let shown else { return [] }
        let p = shownProject
        return rowList.enumerated().compactMap { i, t in
            let pl = pluginTarget(t.id)
            return p.shownLane(shown, of: t.id, to: target(t.id), insert: pl?.insert, parameter: pl?.parameter).map { (i, $0) }
        }
    }
    private var view: ClosedRange<Frame> {
        let a = Frame(viewport.frame(atX: 0).rounded(.down)), b = Frame(viewport.frame(atX: bounds.width).rounded(.up))
        return a...max(a, b)
    }

    // MARK: Words

    static func valueText(_ v: Double, _ param: AutomationLane.Param) -> String {
        switch param {
        case .gain, .send: return L10n.text("automation.value.db", L10n.number(v, 1, sign: true).replacingOccurrences(of: "-", with: "−"))
        case .pan:
            if abs(v) < 0.005 { return L10n.text("automation.value.centre") }
            let percent = String(Int((abs(v) * 100).rounded()))
            return v < 0 ? L10n.text("automation.value.left", percent) : L10n.text("automation.value.right", percent)
        case .mute: return v >= 0.5 ? L10n.text("automation.value.muted") : L10n.text("automation.value.heard")
        case .plugin: return v.formatted(.number.precision(.fractionLength(0...2)))
        case .azimuth: return MixerStrip.placeText(SurroundPosition(azimuth: abs(v) > 180 ? v - (v > 0 ? 360 : -360) : v))
        case .elevation: return L10n.text("mixer.place.elevation", L10n.number(v, 0))
        case .yaw, .pitch, .roll:
            var r = FieldRotation()
            if param == .yaw { r.yaw = abs(v) > 180 ? v - (v > 0 ? 360 : -360) : v } else if param == .pitch { r.pitch = v } else { r.roll = v }
            return MixerStrip.fieldText(r)
        }
    }
    /// What the lane is, and what comes on top of its line.
    func caption(_ lane: ShownLane) -> String {
        let group = lane.group.flatMap { project.vca($0)?.name } ?? ""
        var text: String
        switch lane.param {
        case .plugin:
            if let l = pluginTarget(lane.strip) { let n = pluginNames(l); text = L10n.text("automation.caption.plugin", n.parameter, n.plugin) } else { text = "" }
        case .send:
            text = sendCaption(lane.strip, lane: true)
        case .gain:
            let fader = Self.valueText(lane.onTopDB, .gain)
            if lane.group != nil, lane.own { text = L10n.text("automation.caption.level.withGroup", group, fader) }
            else if lane.group != nil { text = L10n.text("automation.caption.level.groupOnly", group, fader) }
            else { text = L10n.text("automation.caption.level", fader) }
        case .pan: text = L10n.text("automation.caption.pan")
        case .azimuth: text = L10n.text("automation.caption.azimuth")
        case .elevation: text = L10n.text("automation.caption.elevation")
        case .yaw: text = L10n.text("automation.caption.yaw")
        case .pitch: text = L10n.text("automation.caption.pitch")
        case .roll: text = L10n.text("automation.caption.roll")
        case .mute:
            if lane.group != nil, lane.own { text = L10n.text("automation.caption.mute.withGroup", group) }
            else if lane.group != nil { text = L10n.text("automation.caption.mute.groupOnly", group) }
            else { text = L10n.text("automation.caption.mute") }
        }
        if !lane.plays { text = L10n.text("automation.caption.off", text) }
        return text
    }

    /// A send's caption: where it goes and its own level, which the lane is added to; and, with more than one send, which of them this is.
    private func sendCaption(_ strip: UUID, lane: Bool) -> String {
        let all = sends(of: strip)
        guard let to = target(strip), let i = all.firstIndex(where: { $0.to == to }) else { return L10n.text("automation.caption.send.none") }
        let bus = project.buses.first { $0.id == to }?.name ?? ""
        var text = lane ? L10n.text("automation.caption.send", bus, Self.valueText(all[i].gainDB, .gain)) : L10n.text("automation.caption.send.empty", bus)
        if all.count > 1 { text = L10n.text("automation.caption.send.which", text, String(i + 1), String(all.count)) }
        return text
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let shown else { return }
        let all = lanes, list = rowList
        if rows == .strips {
            // Rows of their own: a ground, a line between them, each strip's name, and the playhead carried on down.
            Theme.lane.setFill()
            bounds.fill()
            for (i, row) in list.enumerated() {
                let top = CGFloat(i) * laneHeight
                NSColor(white: 1, alpha: 0.12).setFill()
                NSRect(x: 0, y: top, width: bounds.width, height: 1).fill()
                (row.name as NSString).draw(at: NSPoint(x: 8, y: top + 3), withAttributes: [.font: Self.nameFont, .foregroundColor: NSColor.white])
            }
            Theme.playhead.setFill()
            NSRect(x: viewport.x(of: Double(session.playhead)), y: 0, width: 1.5, height: bounds.height).fill()
        }
        // The focused row: a bar at its left edge, and where a first point would go when it has no lane.
        if isActive, list.indices.contains(focus) {
            let r = area(focus)
            NSColor.systemOrange.setFill()
            NSRect(x: 0, y: r.minY - margin, width: 3, height: r.height + 2 * margin).fill()
            if !all.contains(where: { $0.track == focus }) {
                NSColor.systemOrange.withAlphaComponent(0.35).setFill()
                NSRect(x: 0, y: y(shown == .mute ? 1 : 0, shown, in: r).rounded(), width: bounds.width, height: 1).fill()
                drawCaption(shown == .send ? sendCaption(list[focus].id, lane: false)
                            : shown == .plugin ? L10n.text("automation.caption.plugin.empty") : L10n.text("automation.caption.empty"),
                            track: focus, colour: NSColor.systemOrange.withAlphaComponent(0.8))
            }
        }
        for (i, lane) in all {
            let r = area(i)
            let focused = isActive && i == focus
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
                    (chosen.contains(k) ? NSColor.white : colour).setFill()
                    NSBezierPath(ovalIn: box).fill()
                    NSColor.black.withAlphaComponent(0.6).setStroke()
                    NSBezierPath(ovalIn: box).stroke()
                    if chosen.contains(k) {
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
        if let m = marquee, project.tracks.indices.contains(focus) || rowList.indices.contains(focus) {
            let r = area(focus)
            let box = NSRect(x: min(m.from, m.to), y: r.minY, width: abs(m.to - m.from), height: r.height)
            NSColor.white.withAlphaComponent(0.12).setFill()
            box.fill()
            NSColor.white.withAlphaComponent(0.5).setStroke()
            NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
        // The label: at the pointer, or else at the selected point (so a point stepped to with the keys says what it is worth).
        var said = hover
        if said == nil, isActive, let k = selected, let own = ownLane, own.points.indices.contains(k) {
            said = (place(own.points[k], shown, in: area(focus)), label(own, frame: own.points[k].frame, value: own.points[k].value))
        }
        if let hover = said {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.white]
            let text = hover.text as NSString
            let size = text.size(withAttributes: attrs)
            // Over the tracks the label sits above the point; in a thin row of its own it sits under it, clear of the row's caption.
            var at = NSPoint(x: hover.at.x + 12, y: rows == .tracks ? hover.at.y - size.height - 10 : hover.at.y + 8)
            at.x = min(at.x, bounds.width - size.width - 10)
            at.y = max(topInset + 2, at.y)
            NSColor(white: 0, alpha: 0.85).setFill()
            NSBezierPath(roundedRect: NSRect(x: at.x - 5, y: at.y - 2, width: size.width + 10, height: size.height + 4), xRadius: 4, yRadius: 4).fill()
            text.draw(at: at, withAttributes: attrs)
        }
    }

    static let nameFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    /// The caption has a place of its own: on a plate, on the line of the track's name and after it.
    private func drawCaption(_ text: String, track: Int, colour: NSColor) {
        let top = topInset + CGFloat(track) * laneHeight
        let name = (rowList[track].name as NSString).size(withAttributes: [.font: Self.nameFont]).width
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: colour]
        let size = (text as NSString).size(withAttributes: attrs)
        let at = NSPoint(x: 8 + name + 14, y: top + (rows == .tracks ? 23 : 4))
        NSColor(white: 0, alpha: 0.8).setFill()
        NSBezierPath(roundedRect: NSRect(x: at.x - 5, y: at.y - 2, width: size.width + 10, height: size.height + 4), xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(at: at, withAttributes: attrs)
    }

    // MARK: By hand

    /// Takes the focus from the other view: on its first row, or its last.
    func enter(atEnd: Bool) {
        isActive = true
        focus = atEnd ? max(0, rowList.count - 1) : 0
        if let row = rowList[safe: focus] { session.status = L10n.text("automation.focus.status", row.name) }
    }

    private func track(atY py: CGFloat) -> Int? {
        let n = rowList.count
        guard py >= topInset, n > 0 else { return nil }
        return min(n - 1, Int((py - topInset) / laneHeight))
    }
    private func send(_ lane: AutomationLane, saying: String? = nil) {
        pending = lane
        let name = lane.strip == Master.id ? "master" : lane.strip.uuidString, rate = project.sampleRate
        if lane.points.isEmpty {
            pending = nil
            var params: [String: JSONValue] = ["strip": .string(name), "param": .string(lane.param.rawValue)]
            if let to = lane.to { params["to"] = .string(to.uuidString) }
            if let insert = lane.insert, let parameter = lane.parameter { params["insert"] = .string(insert.uuidString); params["parameter"] = .string(parameter) }
            session.perform("clear_automation", params, saying: saying)
        } else {
            var params: [String: JSONValue] = ["strip": .string(name), "param": .string(lane.param.rawValue)]
            if let to = lane.to { params["to"] = .string(to.uuidString) }
            if let insert = lane.insert, let parameter = lane.parameter { params["insert"] = .string(insert.uuidString); params["parameter"] = .string(parameter) }
            params["points"] = .array(lane.points.map { JSONValue.array([.number(Double($0.frame) / rate), .number($0.value)]) })
            session.perform("set_automation", params, saying: saying)
        }
        needsDisplay = true
        elements = nil
    }
    /// What a point is called and worth: the status line's text when it is selected or moved, and VoiceOver's.
    private func describe(_ lane: AutomationLane, _ i: Int) -> String {
        let p = lane.points[i]
        return L10n.text("automation.point.status", String(i + 1), String(lane.points.count), formatTime(Double(p.frame) / project.sampleRate), Self.valueText(p.value, lane.param))
    }
    /// Says how many points are selected, when it is more than one.
    private func sayChosen() {
        let text = L10n.count("automation.points.selected", chosen.count)
        session.status = text
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        needsDisplay = true
        elements = nil
    }
    private func select(_ i: Int?, seek: Bool = false) {
        selected = i
        others = []
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
        // (A group isn't heard itself: its lane is heard in its members' lines, and said there.)
        if lane.param == .gain, let t = focusedTrack, project.vca(t.id) == nil, let shownLane = shownProject.shownLane(.gain, of: t.id), shownLane.plays {
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
        let out = best.map { abs(Double($0 - frame)) <= reach ? $0 : frame } ?? frame
        // A light tap the moment a point snaps (COMFORT 76).
        if out != frame, out != lastSnap { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        lastSnap = out != frame ? out : nil
        return out
    }
    private var lastSnap: Frame?

    /// A click in the timeline, offered here first. True: it was about a point, and the timeline leaves it alone.
    func mouseDown(_ event: NSEvent, at p: NSPoint) -> Bool {
        cancelled = false
        guard let shown, let t = track(atY: p.y) else { return false }
        if !isActive { onActivate() }
        if t != focus { focus = t; selected = nil; needsDisplay = true; elements = nil }
        let r = area(t)
        if let own = ownLane, let k = own.points.indices.min(by: { hypot(place(own.points[$0], shown, in: r).x - p.x, place(own.points[$0], shown, in: r).y - p.y)
                                                                    < hypot(place(own.points[$1], shown, in: r).x - p.x, place(own.points[$1], shown, in: r).y - p.y) }),
           hypot(place(own.points[k], shown, in: r).x - p.x, place(own.points[k], shown, in: r).y - p.y) <= 8 {
            if event.modifierFlags.contains(.shift) {
                // ⇧ on a point is two things, told apart when the button is let go: moved, it is a drag that
                // holds the time; not moved, the point joins the selected ones or leaves them.
                toggleOnUp = k
                drag = (own, k, false, own)
                return true
            }
            if chosen.count > 1, chosen.contains(k) {
                // A click on one of several selected points: they are dragged together.
                others = chosen.filter { $0 != k }
                selected = k
            } else {
                select(k)
            }
            drag = (own, k, false, own)
            return true
        }
        if event.modifierFlags.contains([.option, .shift]), ownLane != nil {
            // ⌥⇧-drag across the row: the points in that stretch are selected.
            marquee = (p.x, p.x)
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
        else { value = valueAt(height: Double((r.maxY - p.y) / r.height), shown, in: r) }
        guard let added = lane.adding(frame: frame, value: value) else { NSSound.beep(); return true }
        selected = added.index
        send(added.lane, saying: describe(added.lane, added.index))
        return true
    }
    func mouseDragged(_ event: NSEvent, at p: NSPoint) -> Bool {
        if cancelled { return true }
        if let m = marquee { marquee = (m.from, p.x); needsDisplay = true; return true }
        guard let shown, var d = drag else { return false }
        let r = area(focus), old = d.origin.points[d.index], flags = event.modifierFlags
        var frame = Frame(viewport.frame(atX: p.x).rounded())
        var value = valueAt(height: Double((r.maxY - p.y) / r.height), shown, in: r)
        if !flags.contains(.control) {
            frame = snapped(frame)
            // 0 dB, or the centre, within 4 points.
            if shown != .mute, shown != .plugin, abs(y(0, shown, in: r) - p.y) <= 4 { value = 0 }
        }
        if flags.contains(.shift) { frame = old.frame }          // ⇧: the value only
        if flags.contains(.command) || shown == .mute { value = old.value }   // ⌘: the time only; a mute is moved sideways
        if chosen.count > 1 {
            // Several: as one piece, by what the pointer has moved the one that is held.
            d.lane = d.origin.moving(chosen, byFrames: frame - old.frame, byValue: value - old.value, limit: project.length)
        } else {
            d.lane = d.origin.moving(d.index, frame: frame, value: value, limit: project.length)
        }
        d.moved = d.moved || d.lane.points[d.index] != old
        if d.moved, let k = toggleOnUp {
            // It moved: a drag after all. A point that wasn't among the selected ones is dragged alone.
            toggleOnUp = nil
            if !chosen.contains(k) { selected = k; others = []; d.lane = d.origin.moving(d.index, frame: frame, value: value, limit: project.length) }
        }
        drag = d
        let now = d.lane.points[d.index]
        hover = (place(now, shown, in: r), label(d.lane, frame: now.frame, value: now.value))
        needsDisplay = true
        return true
    }
    func mouseUp(_ event: NSEvent, at p: NSPoint) -> Bool {
        if cancelled { cancelled = false; return true }
        if let m = marquee, let shown {
            marquee = nil
            let r = area(focus), lo = min(m.from, m.to), hi = max(m.from, m.to)
            let inside = (ownLane?.points ?? []).enumerated().filter { (lo...hi).contains(place($0.element, shown, in: r).x) }.map(\.offset)
            selected = inside.first
            others = Set(inside.dropFirst())
            if inside.count > 1 { sayChosen() } else { let one = selected; select(one) }
            needsDisplay = true
            return true
        }
        guard let shown, let d = drag else { return false }
        drag = nil
        hover = nil
        if let k = toggleOnUp {
            // ⇧-click: the point joins the selected ones, or leaves them.
            toggleOnUp = nil
            if chosen.contains(k) {
                var rest = chosen
                rest.remove(k)
                let first = rest.min()
                selected = first
                others = rest.filter { $0 != first }
            } else {
                if let was = selected { others.insert(was) }
                selected = k
            }
            if chosen.count > 1 { sayChosen() } else { let one = selected; select(one) }
            return true
        }
        if d.moved {
            send(d.lane, saying: chosen.count > 1 ? L10n.count("automation.points.moved", chosen.count) : describe(d.lane, d.index))
        } else if chosen.count > 1 {
            // A click on one of several selected points, without moving them: that one alone is selected.
            select(d.index)
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
    /// The pointer over the lanes (COMFORT 1): an open hand over a point that a press would grab, a closed one while
    /// points are dragged; nil elsewhere (the timeline's own pointer).
    func pointer(at p: NSPoint) -> NSCursor? {
        if drag != nil { return .closedHand }
        guard let shown, let t = track(atY: p.y), t == focus, let own = ownLane else { return nil }
        let r = area(t)
        return own.points.contains { hypot(place($0, shown, in: r).x - p.x, place($0, shown, in: r).y - p.y) <= 8 } ? .openHand : nil
    }

    /// The value at the pointer, while it is on the focused lane's line.
    override func mouseMoved(with event: NSEvent) {
        let at = convert(event.locationInWindow, from: nil)
        if rows != .tracks { (pointer(at: at) ?? .arrow).set() }
        guard let shown, drag == nil else { return }
        let p = at
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
    // MARK: Copying points (COMFORT 33)

    /// Points copied from a lane, with the kind of lane they came from; pasted only into a lane of that kind.
    static var clipboard: (param: AutomationLane.Param, points: [AutomationPoint])?

    /// Points are selected here: Cut and Copy are theirs.
    var hasChosenPoints: Bool { isActive && ownLane != nil && !chosen.isEmpty }
    /// A lane of the copied kind has the keys: Paste is its.
    var canPastePoints: Bool { isActive && Self.clipboard?.param == shown && laneToChange() != nil }

    func copyPoints(cut: Bool) -> Bool {
        guard hasChosenPoints, let shown, let lane = ownLane else { return false }
        let many = chosen
        Self.clipboard = (shown, lane.copying(many))
        if cut {
            var less = lane
            for i in many.sorted(by: >) where less.points.indices.contains(i) { less.points.remove(at: i) }
            selected = nil
            send(less, saying: L10n.count("automation.points.cut", many.count))
        } else {
            session.status = L10n.count("automation.points.copied", many.count)
        }
        return true
    }

    func pastePoints() -> Bool {
        guard canPastePoints, let c = Self.clipboard, let lane = laneToChange() else { return false }
        let (pasted, at) = lane.pasting(c.points, at: session.playhead, limit: project.length)
        selected = at.first
        others = Set(at.dropFirst())
        send(pasted, saying: L10n.count("automation.points.pasted", at.count))
        return true
    }

    /// The key came up: the nudges it made go as one step.
    func keyUp() {
        guard let n = heldNudge else { return }
        heldNudge = nil
        send(n.lane, saying: n.saying)
    }

    func key(_ event: NSEvent) -> Bool {
        // Escape in the middle of a drag or a marquee: back to how it was, nothing sent.
        if event.keyCode == 53, drag != nil || marquee != nil {
            drag = nil
            marquee = nil
            pending = nil
            hover = nil
            cancelled = true
            needsDisplay = true
            elements = nil
            return true
        }
        // Another key than the nudging one: what was nudged goes first, as its own step.
        if heldNudge != nil, !event.isARepeat { keyUp() }
        let list = rowList
        guard let shown, !list.isEmpty else { return false }
        let flags = event.modifierFlags.intersection([.option, .shift, .command, .control])
        let rate = project.sampleRate
        switch (event.keyCode, flags) {
        case (125, [.option]), (126, [.option]):     // ⌥↓ ⌥↑: the lane of the next or the previous track
            // Past the last or the first row: not this view's (the timeline tries the other one).
            let next = focus + (event.keyCode == 125 ? 1 : -1)
            guard list.indices.contains(next) else { return false }
            focus = next
            selected = nil
            session.status = L10n.text("automation.focus.status", list[focus].name)
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
        case (48, [.option]) where shown == .plugin:   // ⌥Tab: the strip's next plugin parameter lane
            let all = project.lanes(of: list[focus].id).filter { $0.param == .plugin }
            guard all.count > 1, let now = pluginTarget(list[focus].id),
                  let i = all.firstIndex(where: { $0.insert == now.insert && $0.parameter == now.parameter }) else { NSSound.beep(); return true }
            pluginShown[list[focus].id] = all[(i + 1) % all.count]
            selected = nil
            let names = pluginNames(all[(i + 1) % all.count])
            session.status = L10n.text("automation.caption.plugin", names.parameter, names.plugin)
            needsDisplay = true
            elements = nil
            return true
        case (48, [.option]) where shown == .send:   // ⌥Tab: the strip's next send
            let all = sends(of: list[focus].id)
            guard all.count > 1, let now = target(list[focus].id), let i = all.firstIndex(where: { $0.to == now }) else { NSSound.beep(); return true }
            sendShown[list[focus].id] = all[(i + 1) % all.count].to
            selected = nil
            session.status = sendCaption(list[focus].id, lane: ownLane != nil)
            needsDisplay = true
            elements = nil
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
        let many = chosen
        func move(frame: Frame = p.frame, value: Double = p.value) {
            // Several selected: all of them by what this one would move, as one piece.
            let moved = many.count > 1 ? lane.moving(many, byFrames: frame - p.frame, byValue: shown == .mute ? 0 : value - p.value, limit: project.length)
                : lane.moving(k, frame: frame, value: value, limit: project.length)
            guard moved != lane else { if !event.isARepeat { NSSound.beep() }; return }
            let saying = many.count > 1 ? L10n.count("automation.points.moved", many.count) : describe(moved, k)
            pending = moved
            heldNudge = (moved, saying)
            session.status = saying
            needsDisplay = true
            elements = nil
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
        case (124, [.shift]), (123, [.shift]):       // ⇧→ ⇧←: the next point after the selected ones, or the one before them, is selected too
            let next = event.keyCode == 124 ? many.max()! + 1 : many.min()! - 1
            guard lane.points.indices.contains(next) else { NSSound.beep(); return true }
            others.insert(k)
            selected = next
            sayChosen()
        case (51, []), (117, []):                    // Delete: the selected points; the lane's last point takes the lane with it, and the status line says so
            var less = lane
            for i in many.sorted(by: >) { less.points.remove(at: i) }
            // The point before them is selected next (or the first), so the keys alone can go on to an empty lane.
            selected = nil
            selected = less.points.isEmpty ? nil : max(0, many.min()! - 1)
            let name = list[focus].name
            let gone: String
            switch shown {
            case .send: gone = L10n.text("automation.removed.send", name)
            case .gain: gone = L10n.text("automation.removed.gain", name)
            case .plugin: gone = L10n.text("automation.removed.plugin", name)
            case .pan: gone = L10n.text("automation.removed.pan", name)
            case .mute: gone = L10n.text("automation.removed.mute", name)
            case .azimuth: gone = L10n.text("automation.removed.azimuth", name)
            case .elevation: gone = L10n.text("automation.removed.elevation", name)
            case .yaw: gone = L10n.text("automation.removed.yaw", name)
            case .pitch: gone = L10n.text("automation.removed.pitch", name)
            case .roll: gone = L10n.text("automation.removed.roll", name)
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
    override func accessibilityLabel() -> String? { rows == .tracks ? L10n.text("automation.ax.group") : L10n.text("automation.ax.group.strips") }
    override func accessibilityIdentifier() -> String { rows == .tracks ? "timeline.automation" : "timeline.automation.strips" }
    override func accessibilityChildren() -> [Any]? {
        let key = [Double(session.version), viewport.start, viewport.framesPerPoint, Double(bounds.width), Double(bounds.height), Double(focus), Double(selected ?? -1), Double(others.reduce(others.count) { $0 &* 31 &+ $1 })]
        if let elements, key == elementsFor { return elements }
        elementsFor = key
        let rate = project.sampleRate
        let made: [NSAccessibilityElement] = lanes.map { i, lane in
            let r = area(i)
            // The focused track's own points are the ones that can be moved; they are what is named there.
            let own = isActive && i == focus ? ownLane : nil
            let named = own.map { o in var l = lane; l.points = o.points; return l } ?? lane
            let inView = named.points(in: view, limit: Self.maxPointElements)
            let e = LaneElement()
            e.setAccessibilityParent(self)
            e.setAccessibilityRole(.list)
            e.setAccessibilityIdentifier(rows == .tracks ? "timeline.automation.lane.\(i)" : "timeline.automation.strip.\(i)")
            let name = rowList[i].name
            switch lane.param {
            case .send: e.setAccessibilityLabel(L10n.text("automation.ax.lane.send", name))
            case .gain: e.setAccessibilityLabel(L10n.text("automation.ax.lane.gain", name))
            case .plugin: e.setAccessibilityLabel(L10n.text("automation.ax.lane.plugin", pluginTarget(lane.strip).map { pluginNames($0).parameter } ?? "", name))
            case .pan: e.setAccessibilityLabel(L10n.text("automation.ax.lane.pan", name))
            case .mute: e.setAccessibilityLabel(L10n.text("automation.ax.lane.mute", name))
            case .azimuth: e.setAccessibilityLabel(L10n.text("automation.ax.lane.azimuth", name))
            case .elevation: e.setAccessibilityLabel(L10n.text("automation.ax.lane.elevation", name))
            case .yaw: e.setAccessibilityLabel(L10n.text("automation.ax.lane.yaw", name))
            case .pitch: e.setAccessibilityLabel(L10n.text("automation.ax.lane.pitch", name))
            case .roll: e.setAccessibilityLabel(L10n.text("automation.ax.lane.roll", name))
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
                c.setAccessibilitySelected(own != nil && chosen.contains(k))
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
