import AppKit
import JammerAgent
import JammerCore
import SwiftUI

/// Audio › Mixer…: every track and bus as a strip with its level, pan, mute and where it goes.
/// Everything here goes through the same steps an agent uses (set_track, add_bus, set_bus, remove_bus),
/// one undo step per change.
struct MixerSheet: View {
    let session: EditorSession
    let done: () -> Void
    @State private var newBus = ""

    private var project: Project { session.project }
    private var stereo: Bool { project.channels == 2 }
    /// The name a running plugin gives a lane's parameter.
    private func parameterName(_ lane: AutomationLane) -> String? {
        guard let insert = lane.insert, let id = lane.parameter, let unit = session.inserts.instance(insert) else { return nil }
        return unit.parameters.first { $0.identifier == id }?.name
    }

    var body: some View {
        // The title and the description wrap to the window; the strips are in a scroll view, so the window can
        // be made lower and narrower than the mixer and the strips then scroll in it.
        VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("mixer.title")).font(.title2.bold())
            Text(L10n.text("mixer.intro"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 1220, alignment: .leading)
        }
        .padding([.horizontal, .top], 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minWidth: 560, idealWidth: 1300, maxWidth: .infinity)
        ScrollView([.horizontal, .vertical]) { content }
            .frame(minWidth: 560, idealWidth: 1300, maxWidth: .infinity, minHeight: 160, idealHeight: 480, maxHeight: .infinity)
        }
    }

    /// A track strip's menu: mute, solo, lock, duplicate and delete, each the step the Track menu takes; Delete is off,
    /// with its reason, where the Track menu's is (locked, the last track).
    @ViewBuilder private func trackMenu(_ t: Track) -> some View {
        Button(t.isMuted ? L10n.text("mixer.menu.unmute") : L10n.text("track.mute")) { session.perform("set_track", ["track": .string(t.id.uuidString), "muted": .bool(!t.isMuted)]) }
        Button(session.solo.contains(t.id) ? L10n.text("mixer.menu.unsolo") : L10n.text("track.solo")) { toggleSolo(t.id, !session.solo.contains(t.id)) }
        Button(t.locked ? L10n.text("mixer.menu.unlock") : L10n.text("track.lock")) { session.perform("set_track", ["track": .string(t.id.uuidString), "locked": .bool(!t.locked)]) }
        Divider()
        Button(L10n.text("track.duplicate")) { session.perform("duplicate_track", ["track": .string(t.id.uuidString)]) }
        let why = t.locked ? L10n.text("reason.trackLocked", t.name) : project.tracks.count < 2 ? L10n.text("error.track.lastTrack") : nil
        Button(L10n.text("track.delete")) { session.perform("remove_track", ["track": .string(t.id.uuidString)]) }
            .disabled(why != nil)
            .help(why ?? "")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("mixer.tracks")).font(.headline)
                    ForEach(project.tracks) { t in
                        MixerStrip(id: t.id, session: session, name: t.name, kind: "track", gainDB: t.gainDB, pan: t.pan, muted: t.isMuted, output: t.output, stereo: stereo,
                                   group: t.vca.flatMap { project.vca($0) }, groupAutomated: t.vca.map { !project.lanes(of: $0).isEmpty } ?? false,
                                   soloed: session.solo.contains(t.id), solo: { toggleSolo(t.id, $0) },
                                   frozen: t.frozen != nil, freeze: { toggleFreeze(t.id, t.name, $0) },
                                   automation: MixerStrip.automationText(project.lanes(of: t.id), names: parameterName),
                                   panAutomated: project.lane(strip: t.id, param: .pan)?.enabled == true,
                                   destinations: project.buses.map { ($0.id, $0.name) },
                                   sends: t.sends, sendTargets: project.buses.map { ($0.id, $0.name) },
                                   change: { session.perform("set_track", ["track": .string(t.id.uuidString)].merging($0) { $1 }) },
                                   send: { session.perform("set_send", ["from": .string(t.id.uuidString)].merging($0) { $1 }) }, remove: nil,
                                   place: t.position, placeable: project.channels > 2, heights: project.layout == .immersive714 || project.layout.isAmbisonic,
                                   field: project.playsField(t), rotation: t.rotation)
                        // The strip's own menu (COMFORT 37, 26): what the Track menu does to this track, the same steps.
                        .contextMenu { trackMenu(t) }
                    }
                    Text(L10n.text("mixer.buses")).font(.headline).padding(.top, 8)
                    if project.buses.isEmpty { Text(L10n.text("mixer.buses.none")).foregroundStyle(.secondary) }
                    ForEach(project.buses) { b in
                        MixerStrip(id: b.id, session: session, name: b.name, kind: "bus", gainDB: b.gainDB, pan: b.pan, muted: b.isMuted, output: b.output, stereo: stereo,
                                   group: b.vca.flatMap { project.vca($0) }, groupAutomated: b.vca.map { !project.lanes(of: $0).isEmpty } ?? false,
                                   soloed: session.solo.contains(b.id), solo: { toggleSolo(b.id, $0) },
                                   frozen: b.frozen != nil, freeze: { toggleFreeze(b.id, b.name, $0) },
                                   automation: MixerStrip.automationText(project.lanes(of: b.id), names: parameterName),
                                   panAutomated: project.lane(strip: b.id, param: .pan)?.enabled == true,
                                   // A bus can go to any bus that doesn't lead back to it.
                                   destinations: project.buses.filter { $0.id != b.id && !leadsBack(from: $0.id, to: b.id) }.map { ($0.id, $0.name) },
                                   sends: b.sends, sendTargets: project.buses.filter { $0.id != b.id && !leadsBack(from: $0.id, to: b.id) }.map { ($0.id, $0.name) },
                                   change: { session.perform("set_bus", ["bus": .string(b.id.uuidString)].merging($0) { $1 }) },
                                   send: { session.perform("set_send", ["from": .string(b.id.uuidString)].merging($0) { $1 }) },
                                   remove: { session.perform("remove_bus", ["bus": .string(b.id.uuidString), "reroute": .string(b.output?.uuidString ?? "master")]) },
                                   // A bus is turned, not placed: its tracks have placed its channels already.
                                   place: b.azimuth.map { SurroundPosition(azimuth: $0) }, placeable: project.channels > 2 && !project.layout.isAmbisonic)
                        .contextMenu {
                            Button(L10n.text("mixer.bus.delete", b.name)) {
                                session.perform("remove_bus", ["bus": .string(b.id.uuidString), "reroute": .string(b.output?.uuidString ?? "master")])
                            }
                        }
                    }
                    Text(L10n.text("mixer.vcas")).font(.headline).padding(.top, 8)
                    if project.vcas.isEmpty { Text(L10n.text("mixer.vcas.none")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    ForEach(project.vcas) { v in
                        VCAStrip(vca: v,
                                 strips: project.tracks.map { ($0.id, $0.name, $0.vca == v.id) } + project.buses.map { ($0.id, L10n.text("strip.bus.named", $0.name), $0.vca == v.id) },
                                 change: { session.perform("set_vca", ["vca": .string(v.id.uuidString)].merging($0) { $1 }) },
                                 remove: { session.perform("remove_vca", ["vca": .string(v.id.uuidString)]) })
                        .contextMenu {
                            Button(L10n.text("mixer.vca.delete", v.name)) { session.perform("remove_vca", ["vca": .string(v.id.uuidString)]) }
                        }
                        // A group's lanes move every member: said here, where the group's level is.
                        if let text = MixerStrip.automationText(project.lanes(of: v.id)) {
                            StateLine(kind: .info, text: L10n.text("mixer.automation.forGroup", text))
                                .lineLimit(1).padding(.leading, 160).frame(height: 16)
                                .accessibilityIdentifier("mixer.vca.automation")
                        }
                    }
                }
                .padding(.trailing, 6)
            }
            // As tall as what is in it, up to a limit; only past that does it scroll. A fixed short list cut
            // its last rows off (seen in a picture of the sheet, 2026-11-16).
            .frame(height: min(440, listHeight))
            // While the sound plays and this window is in front, what is done here is heard within a few blocks.
            if session.isPlaying, let ahead = session.mixerAhead {
                let ms = String(Int((ahead * 1_000).rounded()))
                if ahead > EditorSession.mixerAheadSteps[0] {
                    StateLine(kind: .warning, text: L10n.text("mixer.ahead.stepped", ms, L10n.count("mixer.ahead.dropouts", Int(session.mixerDropouts))))
                        .accessibilityIdentifier("mixer.ahead")
                } else {
                    StateLine(kind: .info, text: L10n.text("mixer.ahead", ms)).accessibilityIdentifier("mixer.ahead")
                }
            }
            if !session.solo.isEmpty {
                StateLine(kind: .warning, text: L10n.text("mixer.solo.on", session.soloNames.joined(separator: ", ")))
                    .accessibilityIdentifier("mixer.solo.note")
            }
            // Outside the list that scrolls: the master and what its limiter promises are always in view.
            Text(L10n.text("strip.master")).font(.headline)
            MasterStrip(master: project.master, meters: session.meters, automation: MixerStrip.automationText(project.lanes(of: Master.id), names: parameterName), change: { session.perform("set_master", $0) })
            HStack {
                TextField(L10n.text("mixer.new.name"), text: $newBus)
                    .accessibilityLabel(L10n.text("mixer.new.name"))
                    .accessibilityIdentifier("mixer.newName")
                    .onSubmit(add)
                Button(L10n.text("mixer.addBus"), action: add).disabled(newBus.trimmingCharacters(in: .whitespaces).isEmpty || project.buses.count >= Mixer.maxBuses)
                    .accessibilityIdentifier("mixer.addBus")
                // The same name field makes a VCA group.
                Button(L10n.text("mixer.addVCA")) {
                    let name = newBus.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    session.perform("add_vca", ["name": .string(name)])
                    newBus = ""
                }
                .disabled(newBus.trimmingCharacters(in: .whitespaces).isEmpty || project.vcas.count >= Mixer.maxVCAs)
                .accessibilityIdentifier("mixer.addVCA")
            }
            HStack {
                Spacer()
                Button(L10n.text("button.done"), action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding([.horizontal, .bottom], 20)
        .padding(.top, 8)
        // Wide enough for a whole strip: a row that doesn't fit pushes the sheet's content out of its left edge.
        .frame(width: 1260)
    }

    /// The height the strips need: three headings, a row per strip, and a line where a section is empty.
    private var listHeight: CGFloat {
        let rows = project.tracks.count + project.buses.count + project.vcas.count
        // A strip in a group has a line under it saying what is heard.
        let grouped = project.tracks.filter { $0.vca != nil }.count + project.buses.filter { $0.vca != nil }.count
            + project.tracks.filter { $0.frozen != nil }.count + project.buses.filter { $0.frozen != nil }.count
            + project.tracks.filter { !project.lanes(of: $0.id).isEmpty }.count + project.buses.filter { !project.lanes(of: $0.id).isEmpty }.count
            + project.vcas.filter { !project.lanes(of: $0.id).isEmpty }.count
        return CGFloat(3 * 34 + rows * 34 + grouped * 16 + (project.buses.isEmpty ? 24 : 0) + (project.vcas.isEmpty ? 44 : 0) + 8)
    }

    /// Freezing is a job (it renders the strip); thawing is at once. Each is one undo step.
    private func toggleFreeze(_ id: UUID, _ name: String, _ on: Bool) {
        if on {
            session.status = L10n.text("freeze.working", name)
            _ = JobRegistry.shared.startFreeze(session, strip: id)
        } else {
            do { try session.unfreeze(id) } catch { session.say(L10n.error(error), .error) }
        }
    }

    private func toggleSolo(_ id: UUID, _ on: Bool) {
        var now = session.solo
        if on { now.insert(id) } else { now.remove(id) }
        session.setSolo(now)
    }

    private func add() {
        let name = newBus.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        session.perform("add_bus", ["name": .string(name)])
        newBus = ""
    }

    /// Whether `from` reaches `to` through the buses it feeds, by output or by send.
    private func leadsBack(from: UUID, to: UUID) -> Bool {
        var seen = Set<UUID>(), queue = [from]
        while let id = queue.popLast() {
            if id == to { return true }
            guard seen.insert(id).inserted, let b = project.bus(id) else { continue }
            if let o = b.output { queue.append(o) }
            queue.append(contentsOf: b.sends.map(\.to))
        }
        return false
    }
}

/// One strip. The level and the pan are moved freely and sent when the slider is let go, so a drag is one undo step.
/// A VCA group: its level and mute for all its members, and which strips those are.
private struct VCAStrip: View {
    let vca: VCA
    let strips: [(UUID, String, Bool)]
    let change: ([String: JSONValue]) -> Void
    let remove: () -> Void
    @State private var level = 0.0
    @State private var dragging = false

    var body: some View {
        let members = strips.filter(\.2).count
        HStack(spacing: 10) {
            Text(vca.name).lineLimit(1).truncationMode(.middle).frame(width: 150, alignment: .leading)
            Toggle(L10n.text("mixer.mute"), isOn: Binding(get: { vca.isMuted }, set: { change(["muted": .bool($0)]) }))
                .toggleStyle(.checkbox)
                .fixedSize()
                .accessibilityLabel(L10n.text("mixer.vca.mute.ax", vca.name))
                .accessibilityIdentifier("mixer.vca.mute")
            Slider(value: $level, in: -60...12, onEditingChanged: { editing in
                dragging = editing
                if !editing, level != vca.gainDB { change(["gainDB": .number((level * 10).rounded() / 10)]) }
            })
            .frame(width: 150)
            .accessibilityLabel(L10n.text("mixer.vca.level.ax", vca.name))
            .accessibilityValue(Text(MixerStrip.levelText(level)))
            .accessibilityIdentifier("mixer.vca.level")
            Text(MixerStrip.levelText(level)).monospacedDigit().lineLimit(1).frame(width: 72, alignment: .trailing)
            Menu(members == 0 ? L10n.text("mixer.vca.members") : L10n.text("mixer.vca.members.count", String(members))) {
                ForEach(strips, id: \.0) { strip in
                    Button((strip.2 ? "✓ " : "") + strip.1) { change([strip.2 ? "remove" : "add": .array([.string(strip.0.uuidString)])]) }
                }
            }
            .fixedSize()
            .accessibilityLabel(L10n.text("mixer.vca.members.ax", vca.name))
            .accessibilityIdentifier("mixer.vca.members")
            Button(action: remove) { Label(L10n.text("mixer.vca.remove.ax", vca.name), systemImage: "minus.circle").labelStyle(.iconOnly) }
                .buttonStyle(.borderless)
                .help(L10n.text("mixer.vca.remove.help"))
            Spacer(minLength: 0)
        }
        .frame(height: 28)
        .onAppear { level = vca.gainDB }
        .onChange(of: vca.gainDB) { if !dragging { level = vca.gainDB } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("mixer.vca.ax", vca.name))
    }
}

/// The master: everything goes through it last. Its level, and the limiter after everything else.
private struct MasterStrip: View {
    let master: Master
    let meters: StripMeters
    /// Said when the master's level is automated (the lane isn't drawn anywhere yet).
    let automation: String?
    let change: ([String: JSONValue]) -> Void
    @State private var level = 0.0
    @State private var ceiling = -1.0
    @State private var dragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(L10n.text("strip.master")).frame(width: 150, alignment: .leading)
                MeterBar(level: meters.level(Master.id)) { meters.clearClip(Master.id) }.frame(width: 110, height: 8)
                Slider(value: $level, in: -60...12, onEditingChanged: { editing in
                    dragging = editing
                    if !editing, level != master.gainDB { change(["gainDB": .number((level * 10).rounded() / 10)]) }
                })
                .frame(width: 150)
                .accessibilityLabel(L10n.text("mixer.master.level.ax"))
                .accessibilityValue(Text(MixerStrip.levelText(level)))
                .accessibilityIdentifier("mixer.master.level")
                Text(MixerStrip.levelText(level)).monospacedDigit().lineLimit(1).frame(width: 72, alignment: .trailing)
                Toggle(L10n.text("mixer.master.limiter"), isOn: Binding(get: { master.limiter != nil }, set: { change(["limiter": .bool($0)]) }))
                    .toggleStyle(.checkbox)
                    .fixedSize()
                    .accessibilityLabel(L10n.text("mixer.master.limiter.ax"))
                    .accessibilityIdentifier("mixer.master.limiter")
                if master.limiter != nil {
                    Slider(value: $ceiling, in: -12...0, onEditingChanged: { editing in
                        dragging = editing
                        if !editing, ceiling != master.limiter?.ceilingDB { change(["ceiling": .number((ceiling * 10).rounded() / 10)]) }
                    })
                    .frame(width: 120)
                    .accessibilityLabel(L10n.text("mixer.master.ceiling.ax"))
                    .accessibilityValue(Text(L10n.number(ceiling, 1) + " dBTP"))
                    .accessibilityIdentifier("mixer.master.ceiling")
                    Text((L10n.number(ceiling, 1) + " dBTP").replacingOccurrences(of: "-", with: "−")).monospacedDigit().lineLimit(1).fixedSize()
                }
                Spacer(minLength: 0)
            }
            .frame(height: 28)
            if let automation {
                // Information, not a warning: neutral, with the information's symbol.
                StateLine(kind: .info, text: automation)
                    .accessibilityIdentifier("mixer.master.automation")
            }
            // Said where it is switched on: what the limiter promises, and for what.
            if master.limiter != nil {
                Text(L10n.text("mixer.master.limiter.text"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("mixer.master.limiter.note")
            }
        }
        .onAppear { level = master.gainDB; ceiling = master.limiter?.ceilingDB ?? -1 }
        .onChange(of: master.gainDB) { if !dragging { level = master.gainDB } }
        .onChange(of: master.limiter?.ceilingDB) { if !dragging { ceiling = master.limiter?.ceilingDB ?? -1 } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("strip.master"))
    }
}

struct MixerStrip: View {
    let id: UUID
    let session: EditorSession
    let name: String
    let kind: String
    let gainDB: Double
    let pan: Double
    let muted: Bool
    let output: UUID?
    let stereo: Bool
    /// The VCA group the strip belongs to, if any.
    let group: VCA?
    /// Whether that group has automation: the levels in the "heard" line are then not the whole story.
    var groupAutomated = false
    let soloed: Bool
    let solo: (Bool) -> Void
    let frozen: Bool
    let freeze: (Bool) -> Void
    /// Said when the strip's level is automated: until lanes are drawn in the window, this line is where it shows.
    let automation: String?
    /// A pan lane steers the pan: the slider then does nothing, so it is grey and says why.
    var panAutomated = false
    let destinations: [(UUID, String)]
    let sends: [Send]
    let sendTargets: [(UUID, String)]
    let change: ([String: JSONValue]) -> Void
    let send: ([String: JSONValue]) -> Void
    let remove: (() -> Void)?
    /// In a document wider than stereo: the track's place by the surround panner (nil: its sources on their own loudspeakers).
    var place: SurroundPosition? = nil
    /// Whether the strip is placed by azimuth (a track in a layout wider than stereo), and whether the layout has heights.
    var placeable = false
    var heights = false
    /// A track that plays a sound field: its turn round the listener, in place of a place.
    var field = false
    var rotation: FieldRotation? = nil
    @State private var yaw = 0.0
    @State private var azimuth = 0.0
    @State private var level = 0.0
    @State private var position = 0.0
    @State private var dragging = false

    /// A place in words: "Own loudspeakers", "Center", "Left 30°", "Right 110°", "Behind", with the height when there is one.
    /// A bus's turn in words: "Not turned", "Turned 30° left".
    static func turnText(_ p: SurroundPosition?) -> String {
        guard let a = p?.azimuth, abs(a) >= 0.5 else { return L10n.text("mixer.turn.none") }
        return a > 0 ? L10n.text("mixer.turn.left", L10n.number(a, 0)) : L10n.text("mixer.turn.right", L10n.number(-a, 0))
    }
    /// A field's turn in words: "Field not turned", "Field turned 30° left, front up 15°".
    static func fieldText(_ r: FieldRotation?) -> String {
        guard let r, !r.isNone else { return L10n.text("mixer.field.none") }
        var parts: [String] = []
        if abs(r.yaw) >= 0.5 { parts.append(r.yaw > 0 ? L10n.text("mixer.field.yaw.left", L10n.number(r.yaw, 0)) : L10n.text("mixer.field.yaw.right", L10n.number(-r.yaw, 0))) }
        if abs(r.pitch) >= 0.5 { parts.append(r.pitch > 0 ? L10n.text("mixer.field.pitch.up", L10n.number(r.pitch, 0)) : L10n.text("mixer.field.pitch.down", L10n.number(-r.pitch, 0))) }
        if abs(r.roll) >= 0.5 { parts.append(r.roll > 0 ? L10n.text("mixer.field.roll.left", L10n.number(r.roll, 0)) : L10n.text("mixer.field.roll.right", L10n.number(-r.roll, 0))) }
        return parts.isEmpty ? L10n.text("mixer.field.none") : L10n.text("mixer.field.turned", parts.joined(separator: L10n.text("mixer.field.separator")))
    }
    static func placeText(_ p: SurroundPosition?) -> String {
        guard let p else { return L10n.text("mixer.place.own") }
        let a = p.azimuth
        let direction = abs(a) < 0.5 ? L10n.text("mixer.place.center")
            : abs(abs(a) - 180) < 0.5 ? L10n.text("mixer.place.behind")
            : a > 0 ? L10n.text("mixer.place.left", L10n.number(a, 0)) : L10n.text("mixer.place.right", L10n.number(-a, 0))
        return p.elevation > 0 ? L10n.text("mixer.place.withHeight", direction, L10n.number(p.elevation, 0)) : direction
    }

    static func levelText(_ db: Double) -> String { (L10n.number(db, 1, sign: true) + " dB").replacingOccurrences(of: "-", with: "−") }
    /// What a strip's lanes are, in words: the slider beside it is then not the whole level.
    static func automationText(_ lanes: [AutomationLane], names: (AutomationLane) -> String? = { _ in nil }) -> String? {
        // From the catalogue: the count by its plural forms, each lane a whole phrase with its values as
        // placeholders, joined by the catalogue's own separator.
        let parts = lanes.compactMap { lane -> String? in
            let n = lane.points.count, values = lane.points.map(\.value)
            guard n > 0 else { return nil }
            let points = L10n.count("mixer.automation.points", n)
            let text: String
            switch lane.param {
            case .gain:
                let span = values.min() == values.max() ? levelText(values[0]) : L10n.text("mixer.automation.span", levelText(values.min()!), levelText(values.max()!))
                text = L10n.text("mixer.automation.level", points, span)
            case .pan: text = L10n.text("mixer.automation.pan", points)
            case .mute: text = L10n.text("mixer.automation.mute", points)
            case .send: text = L10n.text("mixer.automation.send", points)
            // A plugin's parameter by the name the plugin gives it (its identifier when the plugin isn't running).
            case .plugin: text = L10n.text("mixer.automation.plugin", points, names(lane) ?? lane.parameter ?? "")
            case .azimuth: text = L10n.text("mixer.automation.azimuth", points)
            case .elevation: text = L10n.text("mixer.automation.elevation", points)
            case .yaw: text = L10n.text("mixer.automation.yaw", points)
            case .pitch: text = L10n.text("mixer.automation.pitch", points)
            case .roll: text = L10n.text("mixer.automation.roll", points)
            }
            return lane.enabled ? text : L10n.text("mixer.automation.off", text)
        }
        return parts.isEmpty ? nil : L10n.text("mixer.automation.line", parts.joined(separator: L10n.text("mixer.automation.separator")))
    }
    static func panText(_ p: Double) -> String {
        let percent = String(Int((abs(p) * 100).rounded()))
        return p == 0 ? L10n.text("mixer.pan.center") : p < 0 ? L10n.text("mixer.pan.left", percent) : L10n.text("mixer.pan.right", percent)
    }

    /// What is heard when the strip is in a group: the slider is the strip's own level, and this says
    /// the level with the group's, or that the group's mute is why it is silent.
    static func heardText(own: Double, muted: Bool, group: VCA) -> String {
        if group.isMuted { return L10n.text("mixer.heard.groupMuted", group.name) }
        if muted { return L10n.text("mixer.heard.muted", levelText(own + group.gainDB), group.name) }
        return L10n.text("mixer.heard", levelText(own + group.gainDB), group.name, levelText(group.gainDB))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
            if frozen {
                Text(kind == "bus" ? L10n.text("mixer.frozen.bus") : L10n.text("mixer.frozen.track"))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).padding(.leading, 160).frame(height: 16)
                    .accessibilityIdentifier("mixer.strip.frozen.note")
            }
            if let automation {
                StateLine(kind: .info, text: automation)
                    .lineLimit(1).padding(.leading, 160).frame(height: 16)
                    .accessibilityIdentifier("mixer.strip.automation")
            }
            if let group {
                Text(groupAutomated ? L10n.text("mixer.heard.groupAutomated", Self.heardText(own: gainDB, muted: muted, group: group)) : Self.heardText(own: gainDB, muted: muted, group: group))
                    .font(.caption).foregroundStyle(Color.secondary)
                    .lineLimit(1).padding(.leading, 160).frame(height: 16)
                    .accessibilityIdentifier("mixer.strip.heard")
            }
        }
        // The azimuth slider runs left to right, so its value is the azimuth turned round (positive is left).
        .onAppear { level = gainDB; position = pan; azimuth = -(place?.azimuth ?? 0); yaw = -(rotation?.yaw ?? 0) }
        .onChange(of: place) { azimuth = -(place?.azimuth ?? 0) }
        .onChange(of: rotation) { yaw = -(rotation?.yaw ?? 0) }
        .onChange(of: gainDB) { if !dragging { level = gainDB } }
        .onChange(of: pan) { if !dragging { position = pan } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name), \(kind)")
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Text(name).lineLimit(1).truncationMode(.middle).frame(width: 150, alignment: .leading)
            MeterBar(level: session.meters.level(id)) { session.meters.clearClip(id) }.frame(width: 110, height: 8)
            Toggle(L10n.text("mixer.mute"), isOn: Binding(get: { muted }, set: { change(["muted": .bool($0)]) }))
                .toggleStyle(.checkbox)
                .fixedSize()
                .accessibilityLabel(L10n.text("mixer.mute.ax", name))
            // Listening only: not a change to the document.
            Toggle(L10n.text("mixer.solo"), isOn: Binding(get: { soloed }, set: { solo($0) }))
                .toggleStyle(.checkbox)
                .fixedSize()
                .accessibilityLabel(L10n.text("mixer.solo.ax", name))
                .accessibilityIdentifier("mixer.strip.solo")
                .help(L10n.text("mixer.solo.help"))
            Toggle(L10n.text("mixer.frozen"), isOn: Binding(get: { frozen }, set: { freeze($0) }))
                .toggleStyle(.checkbox)
                .fixedSize()
                .accessibilityLabel(L10n.text("mixer.freeze.ax", name))
                .accessibilityIdentifier("mixer.strip.frozen")
                .help(L10n.text("mixer.frozen.help"))
            Slider(value: $level, in: -60...12, onEditingChanged: { editing in
                dragging = editing
                if editing {
                    // Taken while the sound plays in Touch or Latch: from where the level is now (the fader with its lane).
                    if let start = session.rideStart(id) { level = min(12, max(-60, start)) }
                    session.faderHeld(id, true, level: level)
                } else if session.faderHeld(id, false, level: level) {
                    if level != gainDB { change(["gainDB": .number((level * 10).rounded() / 10)]) }
                } else {
                    level = gainDB      // a ride that is written leaves the fader where it was
                }
            })
            .onChange(of: level) { if dragging { session.faderMoved(id, level: level) } }
            .frame(width: 150)
            .accessibilityLabel(L10n.text("mixer.level.ax", name))
            .accessibilityValue(Text(Self.levelText(level)))
            // Typed into with a click, set back to 0 dB with a double-click (COMFORT 17, 65).
            EditableValue(text: Self.levelText(level), draftText: L10n.number(gainDB, 1), help: L10n.text("mixer.level.edit.help"),
                          font: .body.monospacedDigit(), width: 72,
                          commit: { typed in
                              guard let v = ValueEntry.decibels(typed) else { return false }
                              level = v
                              if v != gainDB { change(["gainDB": .number(v)]) }
                              return true
                          },
                          reset: { if gainDB != 0 { level = 0; change(["gainDB": .number(0)]) } })
                .frame(width: 72, alignment: .trailing)
            if Operations.automationOn {
                // How the fader is taken while the sound plays. Not saved; Read again when the window leaves the front.
                Picker(L10n.text("mixer.mode.label", name), selection: Binding(get: { session.writeMode(id) }, set: { session.writeModes[id] = $0 })) {
                    Text(L10n.text("mixer.mode.read")).tag(EditorSession.WriteMode.read)
                    Text(L10n.text("mixer.mode.touch")).tag(EditorSession.WriteMode.touch)
                    Text(L10n.text("mixer.mode.latch")).tag(EditorSession.WriteMode.latch)
                }
                .labelsHidden()
                .frame(width: 86)
                .help(L10n.text("mixer.mode.help"))
                .accessibilityIdentifier("mixer.strip.mode")
                if session.writing.contains(id) {
                    StateLine(kind: .progress, text: L10n.text("mixer.writing")).accessibilityIdentifier("mixer.strip.writing")
                }
            }
            if stereo {
                Slider(value: $position, in: -1...1, onEditingChanged: { editing in
                    dragging = editing
                    // Close to the middle is the middle: the centre is the one position that leaves the sound untouched.
                    if !editing { if abs(position) < 0.03 { position = 0 }; if position != pan { change(["pan": .number((position * 100).rounded() / 100)]) } }
                })
                .frame(width: 90)
                .disabled(panAutomated)
                .help(panAutomated ? L10n.text("mixer.pan.automated.help") : "")
                .accessibilityLabel(L10n.text("mixer.pan.ax", name))
                .accessibilityValue(Text(panAutomated ? L10n.text("mixer.pan.automated.help") : Self.panText(position)))
                .accessibilityIdentifier("mixer.strip.pan")
                Group {
                if panAutomated {
                    Text(L10n.text("mixer.pan.automated")).font(.caption).lineLimit(1).frame(width: 72, alignment: .leading)
                } else {
                    EditableValue(text: Self.panText(position), draftText: String(Int((pan * 100).rounded())), help: L10n.text("mixer.pan.edit.help"),
                                  font: .caption, width: 72,
                                  commit: { typed in
                                      guard let v = ValueEntry.pan(typed) else { return false }
                                      position = v
                                      if v != pan { change(["pan": .number(v)]) }
                                      return true
                                  },
                                  reset: { if pan != 0 { position = 0; change(["pan": .number(0)]) } })
                        .frame(width: 72, alignment: .leading)
                }
                }
                    .foregroundStyle(panAutomated ? Color.secondary : Color.primary)
                    .help(panAutomated ? L10n.text("mixer.pan.automated.help") : "")
            } else if field {
                // A sound field turned round the listener: the slider turns it (to the left is to the left, as a place),
                // the menu lifts its front or its side, or takes the turn away.
                Slider(value: $yaw, in: -180...180, onEditingChanged: { editing in
                    if !editing {
                        yaw = (yaw / 5).rounded() * 5
                        if -yaw != (rotation?.yaw ?? 0) { change(["yaw": .number(-yaw == 0 ? 0 : -yaw)]) }
                    }
                })
                .frame(width: 90)
                .help(L10n.text("mixer.field.help"))
                .accessibilityLabel(L10n.text("mixer.field.ax", name))
                .accessibilityValue(Text(Self.fieldText(rotation)))
                .accessibilityIdentifier("mixer.strip.yaw")
                Menu(Self.fieldText(rotation)) {
                    ForEach([-30.0, -15, 0, 15, 30], id: \.self) { up in
                        Button(((rotation?.pitch ?? 0) == up ? "✓ " : "") + L10n.text("mixer.field.pitch", L10n.number(up, 0))) { change(["pitch": .number(up)]) }
                    }
                    Divider()
                    ForEach([-30.0, -15, 0, 15, 30], id: \.self) { side in
                        Button(((rotation?.roll ?? 0) == side ? "✓ " : "") + L10n.text("mixer.field.roll", L10n.number(side, 0))) { change(["roll": .number(side)]) }
                    }
                    Divider()
                    Button(L10n.text("mixer.field.off")) { change(["turned": .bool(false)]) }.disabled(rotation == nil)
                }
                .menuStyle(.borderlessButton).font(.caption).frame(width: 250, alignment: .leading)
                .accessibilityIdentifier("mixer.strip.field")
            } else if placeable {
                // The surround panner: where the sound comes from, positive to the left (BS.2051's convention).
                Slider(value: $azimuth, in: -180...180, onEditingChanged: { editing in
                    if !editing {
                        azimuth = (azimuth / 5).rounded() * 5
                        if -azimuth != (place?.azimuth ?? 0) || place == nil { change(["azimuth": .number(-azimuth == 0 ? 0 : -azimuth)]) }
                    }
                })
                .frame(width: 90)
                .help(kind == "bus" ? L10n.text("mixer.turn.help") : L10n.text("mixer.place.help"))
                .accessibilityLabel(kind == "bus" ? L10n.text("mixer.turn.ax", name) : L10n.text("mixer.place.ax", name))
                .accessibilityValue(Text(kind == "bus" ? Self.turnText(place) : Self.placeText(place)))
                .accessibilityIdentifier("mixer.strip.azimuth")
                Menu(kind == "bus" ? Self.turnText(place) : Self.placeText(place)) {
                    if heights {
                        ForEach([0.0, 15, 30], id: \.self) { up in
                            Button((place?.elevation == up ? "✓ " : "") + L10n.text("mixer.place.elevation", L10n.number(up, 0))) { change(["elevation": .number(up)]) }
                        }
                        Divider()
                    }
                    if kind == "bus" {
                        Button(L10n.text("mixer.turn.off")) { change(["turned": .bool(false)]) }.disabled(place == nil)
                    } else {
                        Button(L10n.text("mixer.place.off")) { change(["placed": .bool(false)]) }.disabled(place == nil)
                    }
                }
                .menuStyle(.borderlessButton).font(.caption).frame(width: 128, alignment: .leading)
                .accessibilityIdentifier("mixer.strip.place")
            }
            Picker(L10n.text("mixer.output.ax", name), selection: Binding(get: { output }, set: { change(["output": .string($0?.uuidString ?? "master")]) })) {
                Text(L10n.text("mixer.output")).tag(UUID?.none)
                ForEach(destinations, id: \.0) { Text($0.1).tag(Optional($0.0)) }
            }
            .labelsHidden()
            .frame(width: 150)
            // Sends: a copy of the strip to a bus, each with a level and whether it is taken before the fader.
            Menu(sends.isEmpty ? L10n.text("mixer.sends") : L10n.text("mixer.sends.count", String(sends.count))) {
                if sendTargets.isEmpty { Text(L10n.text("mixer.sends.none")) }
                ForEach(sendTargets, id: \.0) { target in
                    let now = sends.first { $0.to == target.0 }
                    Menu(now.map { $0.pre ? L10n.text("mixer.send.line.pre", target.1, Self.levelText($0.gainDB)) : L10n.text("mixer.send.line", target.1, Self.levelText($0.gainDB)) } ?? target.1) {
                        ForEach([0.0, -6, -12, -18, -24], id: \.self) { db in
                            Button((now?.gainDB == db ? "✓ " : "") + Self.levelText(db)) { send(["to": .string(target.0.uuidString), "gainDB": .number(db)]) }
                        }
                        Divider()
                        Button((now?.pre == true ? "✓ " : "") + L10n.text("mixer.send.pre")) { send(["to": .string(target.0.uuidString), "pre": .bool(!(now?.pre ?? false))]) }
                        if now != nil { Button(L10n.text("mixer.send.remove")) { send(["to": .string(target.0.uuidString), "remove": .bool(true)]) } }
                    }
                }
            }
            .fixedSize()
            .accessibilityLabel(L10n.text("mixer.sends.ax", name))
            // The same width on every row, with or without the button, so the columns line up.
            Group {
                if let remove {
                    Button(action: remove) { Label(L10n.text("button.remove.ax", name), systemImage: "minus.circle").labelStyle(.iconOnly) }
                        .buttonStyle(.borderless)
                        .help(L10n.text("mixer.bus.remove.help"))
                } else {
                    Color.clear
                }
            }
            .frame(width: 24, height: 20)
            Spacer(minLength: 0)
        }
        .frame(height: 28)
    }
}
