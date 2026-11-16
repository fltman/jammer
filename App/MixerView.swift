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
        VStack(alignment: .leading, spacing: 12) {
            Text("Mixer").font(.title2.bold())
            Text("Tracks go to the output, or to a bus that gathers several of them under one level. A document without buses, with every pan in the centre, plays exactly as it always did.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tracks").font(.headline)
                    ForEach(project.tracks) { t in
                        MixerStrip(name: t.name, kind: "track", gainDB: t.gainDB, pan: t.pan, muted: t.isMuted, output: t.output, stereo: stereo,
                                   destinations: project.buses.map { ($0.id, $0.name) },
                                   sends: t.sends, sendTargets: project.buses.map { ($0.id, $0.name) },
                                   change: { session.perform("set_track", ["track": .string(t.id.uuidString)].merging($0) { $1 }) },
                                   send: { session.perform("set_send", ["from": .string(t.id.uuidString)].merging($0) { $1 }) }, remove: nil)
                    }
                    Text("Buses").font(.headline).padding(.top, 8)
                    if project.buses.isEmpty { Text("No buses yet.").foregroundStyle(.secondary) }
                    ForEach(project.buses) { b in
                        MixerStrip(name: b.name, kind: "bus", gainDB: b.gainDB, pan: b.pan, muted: b.isMuted, output: b.output, stereo: stereo,
                                   // A bus can go to any bus that doesn't lead back to it.
                                   destinations: project.buses.filter { $0.id != b.id && !leadsBack(from: $0.id, to: b.id) }.map { ($0.id, $0.name) },
                                   sends: b.sends, sendTargets: project.buses.filter { $0.id != b.id && !leadsBack(from: $0.id, to: b.id) }.map { ($0.id, $0.name) },
                                   change: { session.perform("set_bus", ["bus": .string(b.id.uuidString)].merging($0) { $1 }) },
                                   send: { session.perform("set_send", ["from": .string(b.id.uuidString)].merging($0) { $1 }) },
                                   remove: { session.perform("remove_bus", ["bus": .string(b.id.uuidString), "reroute": .string(b.output?.uuidString ?? "master")]) })
                    }
                }
                .padding(.trailing, 6)
            }
            .frame(minHeight: 180, maxHeight: 420)
            // Outside the list that scrolls: the master and what its limiter promises are always in view.
            Text("Master").font(.headline)
            MasterStrip(master: project.master, change: { session.perform("set_master", $0) })
            HStack {
                TextField("Name of a new bus", text: $newBus)
                    .accessibilityLabel("Name of a new bus")
                    .onSubmit(add)
                Button("Add Bus", action: add).disabled(newBus.trimmingCharacters(in: .whitespaces).isEmpty || project.buses.count >= Mixer.maxBuses)
            }
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        // Wide enough for a whole strip: a row that doesn't fit pushes the sheet's content out of its left edge.
        .frame(width: 1000)
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
/// The master: everything goes through it last. Its level, and the limiter after everything else.
private struct MasterStrip: View {
    let master: Master
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
    let name: String
    let kind: String
    let gainDB: Double
    let pan: Double
    let muted: Bool
    let output: UUID?
    let stereo: Bool
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
    static func panText(_ p: Double) -> String { p == 0 ? "Centre" : "\(Int((abs(p) * 100).rounded())) % \(p < 0 ? "left" : "right")" }

    var body: some View {
        HStack(spacing: 10) {
            Text(name).lineLimit(1).truncationMode(.middle).frame(width: 150, alignment: .leading)
            Toggle("Mute", isOn: Binding(get: { muted }, set: { change(["muted": .bool($0)]) }))
                .toggleStyle(.checkbox)
                .fixedSize()
                .accessibilityLabel("Mute \(name)")
            Slider(value: $level, in: -60...12, onEditingChanged: { editing in
                dragging = editing
                if !editing, level != gainDB { change(["gainDB": .number((level * 10).rounded() / 10)]) }
            })
            .frame(width: 150)
            .accessibilityLabel("Level of \(name)")
            .accessibilityValue(Text(Self.levelText(level)))
            Text(Self.levelText(level)).monospacedDigit().lineLimit(1).frame(width: 72, alignment: .trailing)
            if stereo {
                Slider(value: $position, in: -1...1, onEditingChanged: { editing in
                    dragging = editing
                    // Close to the middle is the middle: the centre is the one position that leaves the sound untouched.
                    if !editing { if abs(position) < 0.03 { position = 0 }; if position != pan { change(["pan": .number((position * 100).rounded() / 100)]) } }
                })
                .frame(width: 90)
                .accessibilityLabel("Pan of \(name)")
                .accessibilityValue(Text(Self.panText(position)))
                Text(Self.panText(position)).font(.caption).lineLimit(1).frame(width: 72, alignment: .leading)
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
        .onAppear { level = gainDB; position = pan }
        .onChange(of: gainDB) { if !dragging { level = gainDB } }
        .onChange(of: pan) { if !dragging { position = pan } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name), \(kind)")
    }
}
