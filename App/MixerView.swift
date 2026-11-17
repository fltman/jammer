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

    var body: some View {
        // In a scroll view: the window can be made lower and narrower than the mixer, and the mixer then scrolls in it.
        ScrollView([.horizontal, .vertical]) { content }
            .frame(minWidth: 560, idealWidth: 1300, maxWidth: .infinity, minHeight: 220, idealHeight: 560, maxHeight: .infinity)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mixer").font(.title2.bold())
            Text("Tracks go to the output, or to a bus that gathers several of them under one level. A document without buses, with every pan in the center, plays exactly as it always did.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tracks").font(.headline)
                    ForEach(project.tracks) { t in
                        MixerStrip(id: t.id, session: session, name: t.name, kind: "track", gainDB: t.gainDB, pan: t.pan, muted: t.isMuted, output: t.output, stereo: stereo,
                                   group: t.vca.flatMap { project.vca($0) }, groupAutomated: t.vca.map { !project.lanes(of: $0).isEmpty } ?? false,
                                   soloed: session.solo.contains(t.id), solo: { toggleSolo(t.id, $0) },
                                   frozen: t.frozen != nil, freeze: { toggleFreeze(t.id, t.name, $0) },
                                   automation: MixerStrip.automationText(project.lanes(of: t.id)),
                                   panAutomated: project.lane(strip: t.id, param: .pan)?.enabled == true,
                                   destinations: project.buses.map { ($0.id, $0.name) },
                                   sends: t.sends, sendTargets: project.buses.map { ($0.id, $0.name) },
                                   change: { session.perform("set_track", ["track": .string(t.id.uuidString)].merging($0) { $1 }) },
                                   send: { session.perform("set_send", ["from": .string(t.id.uuidString)].merging($0) { $1 }) }, remove: nil)
                    }
                    Text("Buses").font(.headline).padding(.top, 8)
                    if project.buses.isEmpty { Text("No buses yet.").foregroundStyle(.secondary) }
                    ForEach(project.buses) { b in
                        MixerStrip(id: b.id, session: session, name: b.name, kind: "bus", gainDB: b.gainDB, pan: b.pan, muted: b.isMuted, output: b.output, stereo: stereo,
                                   group: b.vca.flatMap { project.vca($0) }, groupAutomated: b.vca.map { !project.lanes(of: $0).isEmpty } ?? false,
                                   soloed: session.solo.contains(b.id), solo: { toggleSolo(b.id, $0) },
                                   frozen: b.frozen != nil, freeze: { toggleFreeze(b.id, b.name, $0) },
                                   automation: MixerStrip.automationText(project.lanes(of: b.id)),
                                   panAutomated: project.lane(strip: b.id, param: .pan)?.enabled == true,
                                   // A bus can go to any bus that doesn't lead back to it.
                                   destinations: project.buses.filter { $0.id != b.id && !leadsBack(from: $0.id, to: b.id) }.map { ($0.id, $0.name) },
                                   sends: b.sends, sendTargets: project.buses.filter { $0.id != b.id && !leadsBack(from: $0.id, to: b.id) }.map { ($0.id, $0.name) },
                                   change: { session.perform("set_bus", ["bus": .string(b.id.uuidString)].merging($0) { $1 }) },
                                   send: { session.perform("set_send", ["from": .string(b.id.uuidString)].merging($0) { $1 }) },
                                   remove: { session.perform("remove_bus", ["bus": .string(b.id.uuidString), "reroute": .string(b.output?.uuidString ?? "master")]) })
                    }
                    Text("VCA groups").font(.headline).padding(.top, 8)
                    if project.vcas.isEmpty { Text("No VCA groups yet. A group moves the level of several tracks and buses together; each keeps its own level, plugins and route.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    ForEach(project.vcas) { v in
                        VCAStrip(vca: v,
                                 strips: project.tracks.map { ($0.id, $0.name, $0.vca == v.id) } + project.buses.map { ($0.id, "\($0.name) (bus)", $0.vca == v.id) },
                                 change: { session.perform("set_vca", ["vca": .string(v.id.uuidString)].merging($0) { $1 }) },
                                 remove: { session.perform("remove_vca", ["vca": .string(v.id.uuidString)]) })
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
                StateLine(kind: .warning, text: "Solo is on (\(session.soloNames.joined(separator: ", "))): only what reaches those strips is heard. It is a way of listening; exports and measurements are not affected, and it isn't saved.")
                    .accessibilityIdentifier("mixer.solo.note")
            }
            // Outside the list that scrolls: the master and what its limiter promises are always in view.
            Text("Master").font(.headline)
            MasterStrip(master: project.master, automation: MixerStrip.automationText(project.lanes(of: Master.id)), change: { session.perform("set_master", $0) })
            HStack {
                TextField("Name of a new bus or VCA group", text: $newBus)
                    .accessibilityLabel("Name of a new bus or VCA group")
                    .accessibilityIdentifier("mixer.newName")
                    .onSubmit(add)
                Button("Add Bus", action: add).disabled(newBus.trimmingCharacters(in: .whitespaces).isEmpty || project.buses.count >= Mixer.maxBuses)
                    .accessibilityIdentifier("mixer.addBus")
                // The same name field makes a VCA group.
                Button("Add VCA") {
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
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
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
            session.status = "Freezing \(name)…"
            _ = JobRegistry.shared.startFreeze(session, strip: id)
        } else if let thawed = try? session.project.unfreezing(id) {
            session.commit(thawed, action: "Unfreeze \(name)")
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
            Toggle("Mute", isOn: Binding(get: { vca.isMuted }, set: { change(["muted": .bool($0)]) }))
                .toggleStyle(.checkbox)
                .fixedSize()
                .accessibilityLabel("Mute the group \(vca.name)")
                .accessibilityIdentifier("mixer.vca.mute")
            Slider(value: $level, in: -60...12, onEditingChanged: { editing in
                dragging = editing
                if !editing, level != vca.gainDB { change(["gainDB": .number((level * 10).rounded() / 10)]) }
            })
            .frame(width: 150)
            .accessibilityLabel("Level of the group \(vca.name)")
            .accessibilityValue(Text(MixerStrip.levelText(level)))
            .accessibilityIdentifier("mixer.vca.level")
            Text(MixerStrip.levelText(level)).monospacedDigit().lineLimit(1).frame(width: 72, alignment: .trailing)
            Menu(members == 0 ? "Members" : "Members (\(members))") {
                ForEach(strips, id: \.0) { strip in
                    Button("\(strip.2 ? "✓ " : "")\(strip.1)") { change([strip.2 ? "remove" : "add": .array([.string(strip.0.uuidString)])]) }
                }
            }
            .fixedSize()
            .accessibilityLabel("Members of the group \(vca.name)")
            .accessibilityIdentifier("mixer.vca.members")
            Button(action: remove) { Label("Remove the group \(vca.name)", systemImage: "minus.circle").labelStyle(.iconOnly) }
                .buttonStyle(.borderless)
                .help("Remove this group. Its members keep the level they had with it.")
            Spacer(minLength: 0)
        }
        .frame(height: 28)
        .onAppear { level = vca.gainDB }
        .onChange(of: vca.gainDB) { if !dragging { level = vca.gainDB } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(vca.name), VCA group")
    }
}

/// The master: everything goes through it last. Its level, and the limiter after everything else.
private struct MasterStrip: View {
    let master: Master
    /// Said when the master's level is automated (the lane isn't drawn anywhere yet).
    let automation: String?
    let change: ([String: JSONValue]) -> Void
    @State private var level = 0.0
    @State private var ceiling = -1.0
    @State private var dragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("Master").frame(width: 150, alignment: .leading)
                Slider(value: $level, in: -60...12, onEditingChanged: { editing in
                    dragging = editing
                    if !editing, level != master.gainDB { change(["gainDB": .number((level * 10).rounded() / 10)]) }
                })
                .frame(width: 150)
                .accessibilityLabel("Level of the master")
                .accessibilityValue(Text(MixerStrip.levelText(level)))
                .accessibilityIdentifier("mixer.master.level")
                Text(MixerStrip.levelText(level)).monospacedDigit().lineLimit(1).frame(width: 72, alignment: .trailing)
                Toggle("Limiter", isOn: Binding(get: { master.limiter != nil }, set: { change(["limiter": .bool($0)]) }))
                    .toggleStyle(.checkbox)
                    .fixedSize()
                    .accessibilityLabel("Limiter on the master")
                    .accessibilityIdentifier("mixer.master.limiter")
                if master.limiter != nil {
                    Slider(value: $ceiling, in: -12...0, onEditingChanged: { editing in
                        dragging = editing
                        if !editing, ceiling != master.limiter?.ceilingDB { change(["ceiling": .number((ceiling * 10).rounded() / 10)]) }
                    })
                    .frame(width: 120)
                    .accessibilityLabel("Ceiling of the master's limiter")
                    .accessibilityValue(Text(String(format: "%.1f dBTP", ceiling)))
                    .accessibilityIdentifier("mixer.master.ceiling")
                    Text(String(format: "%.1f dBTP", ceiling).replacingOccurrences(of: "-", with: "−")).monospacedDigit().lineLimit(1).fixedSize()
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
                Text("The limiter comes after everything else. An exported file is measured and held under the ceiling; playback has one pass and can go a little over.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("mixer.master.limiter.note")
            }
        }
        .onAppear { level = master.gainDB; ceiling = master.limiter?.ceilingDB ?? -1 }
        .onChange(of: master.gainDB) { if !dragging { level = master.gainDB } }
        .onChange(of: master.limiter?.ceilingDB) { if !dragging { ceiling = master.limiter?.ceilingDB ?? -1 } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Master")
    }
}

private struct MixerStrip: View {
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
    @State private var level = 0.0
    @State private var position = 0.0
    @State private var dragging = false

    static func levelText(_ db: Double) -> String { String(format: "%+.1f dB", db).replacingOccurrences(of: "-", with: "−") }
    /// What a strip's lanes are, in words: the slider beside it is then not the whole level.
    static func automationText(_ lanes: [AutomationLane]) -> String? {
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
            }
            return lane.enabled ? text : L10n.text("mixer.automation.off", text)
        }
        return parts.isEmpty ? nil : L10n.text("mixer.automation.line", parts.joined(separator: L10n.text("mixer.automation.separator")))
    }
    static func panText(_ p: Double) -> String { p == 0 ? "Center" : "\(Int((abs(p) * 100).rounded())) % \(p < 0 ? "left" : "right")" }

    /// What is heard when the strip is in a group: the slider is the strip's own level, and this says
    /// the level with the group's, or that the group's mute is why it is silent.
    static func heardText(own: Double, muted: Bool, group: VCA) -> String {
        if group.isMuted { return "Silent: the group \(group.name) is muted" }
        if muted { return "Muted; \(levelText(own + group.gainDB)) with the group \(group.name) when it isn't" }
        return "Heard at \(levelText(own + group.gainDB)) with the group \(group.name) (\(levelText(group.gainDB)))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
            if frozen {
                Text(kind == "bus" ? "Frozen: plays from a file, its plugins rest. Unfreeze it to change its plugins or anything that feeds it."
                                   : "Frozen: plays from a file, its plugins rest. Unfreeze it to change its clips or plugins.")
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
        .onAppear { level = gainDB; position = pan }
        .onChange(of: gainDB) { if !dragging { level = gainDB } }
        .onChange(of: pan) { if !dragging { position = pan } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name), \(kind)")
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Text(name).lineLimit(1).truncationMode(.middle).frame(width: 150, alignment: .leading)
            Toggle("Mute", isOn: Binding(get: { muted }, set: { change(["muted": .bool($0)]) }))
                .toggleStyle(.checkbox)
                .fixedSize()
                .accessibilityLabel("Mute \(name)")
            // Listening only: not a change to the document.
            Toggle("Solo", isOn: Binding(get: { soloed }, set: { solo($0) }))
                .toggleStyle(.checkbox)
                .fixedSize()
                .accessibilityLabel("Solo \(name)")
                .accessibilityIdentifier("mixer.strip.solo")
                .help("Hear only this strip (and any others that are soloed). Listening only: exports are not affected.")
            Toggle("Frozen", isOn: Binding(get: { frozen }, set: { freeze($0) }))
                .toggleStyle(.checkbox)
                .fixedSize()
                .accessibilityLabel("Freeze \(name)")
                .accessibilityIdentifier("mixer.strip.frozen")
                .help("Play this strip from a file made through its plugins, and let the plugins rest. Its level, pan, mute and sends still work.")
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
            .accessibilityLabel("Level of \(name)")
            .accessibilityValue(Text(Self.levelText(level)))
            Text(Self.levelText(level)).monospacedDigit().lineLimit(1).frame(width: 72, alignment: .trailing)
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
                .accessibilityLabel("Pan of \(name)")
                .accessibilityValue(Text(panAutomated ? L10n.text("mixer.pan.automated.help") : Self.panText(position)))
                .accessibilityIdentifier("mixer.strip.pan")
                Text(panAutomated ? L10n.text("mixer.pan.automated") : Self.panText(position)).font(.caption).lineLimit(1).frame(width: 72, alignment: .leading)
                    .foregroundStyle(panAutomated ? .secondary : .primary)
                    .help(panAutomated ? L10n.text("mixer.pan.automated.help") : "")
            }
            Picker("Output of \(name)", selection: Binding(get: { output }, set: { change(["output": .string($0?.uuidString ?? "master")]) })) {
                Text("Output").tag(UUID?.none)
                ForEach(destinations, id: \.0) { Text($0.1).tag(Optional($0.0)) }
            }
            .labelsHidden()
            .frame(width: 150)
            // Sends: a copy of the strip to a bus, each with a level and whether it is taken before the fader.
            Menu(sends.isEmpty ? "Sends" : "Sends (\(sends.count))") {
                if sendTargets.isEmpty { Text("Add a bus to send to") }
                ForEach(sendTargets, id: \.0) { target in
                    let now = sends.first { $0.to == target.0 }
                    Menu(now.map { "\(target.1): \(Self.levelText($0.gainDB))\($0.pre ? ", before the fader" : "")" } ?? target.1) {
                        ForEach([0.0, -6, -12, -18, -24], id: \.self) { db in
                            Button("\(now?.gainDB == db ? "✓ " : "")\(Self.levelText(db))") { send(["to": .string(target.0.uuidString), "gainDB": .number(db)]) }
                        }
                        Divider()
                        Button("\(now?.pre == true ? "✓ " : "")Before the fader") { send(["to": .string(target.0.uuidString), "pre": .bool(!(now?.pre ?? false))]) }
                        if now != nil { Button("Remove This Send") { send(["to": .string(target.0.uuidString), "remove": .bool(true)]) } }
                    }
                }
            }
            .fixedSize()
            .accessibilityLabel("Sends of \(name)")
            // The same width on every row, with or without the button, so the columns line up.
            Group {
                if let remove {
                    Button(action: remove) { Label("Remove \(name)", systemImage: "minus.circle").labelStyle(.iconOnly) }
                        .buttonStyle(.borderless)
                        .help("Remove this bus. What goes to it goes where the bus went.")
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
