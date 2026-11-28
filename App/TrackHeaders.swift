import AppKit
import JammerAgent
import JammerAudio
import JammerCore
import SwiftUI

/// The track headers (the comfort block, step 4): one beside each lane, with its name, mute, solo and lock, and,
/// when the lane is tall enough, its level and pan. Each change is one undo step through set_track, committed when
/// a slider is let go (COMFORT 9), never on every move; solo is a way of listening and never a step.
struct TrackHeaders: View {
    @Bindable var session: EditorSession
    let rename: (UUID) -> Void

    static func layout(_ session: EditorSession, height: CGFloat) -> LaneLayout {
        LaneLayout(tracks: session.project.tracks.count, rulerHeight: Double(TimelineView.rulerHeight),
                   areaHeight: Double(height - TimelineView.rulerHeight), zoom: session.trackZoom, scrollY: session.trackScroll)
    }

    var body: some View {
        GeometryReader { geo in
            let tracks = session.project.tracks
            // The lanes' own layout (LaneLayout), so a header lies beside its lane however the tracks are scrolled.
            let l = Self.layout(session, height: geo.size.height)
            let lane = CGFloat(l.laneHeight)
            VStack(spacing: 0) {
                Color.clear.frame(height: TimelineView.rulerHeight + CGFloat(l.edge))
                VStack(spacing: 0) {
                    ForEach(tracks) { t in
                        // Drawn from the lane's top and cut at its bottom: a header never lies over the next one.
                        TrackHeader(session: session, track: t, height: lane, stereo: session.project.channels == 2, rename: rename)
                            .frame(height: lane, alignment: .top)
                            .clipped()
                    }
                }
                .offset(y: -CGFloat(l.scrollY))
                .frame(height: CGFloat(l.visibleHeight), alignment: .top)
                .clipped()
                Color.clear.frame(height: CGFloat(l.edge))
            }
        }
        .frame(width: 168)
        .background(Theme.inkColor)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("trackHeader.column.ax"))
    }
}

private struct TrackHeader: View {
    let session: EditorSession
    let track: Track
    let height: CGFloat
    let stereo: Bool
    let rename: (UUID) -> Void
    /// The value under the hand while a slider is dragged; committed on release.
    @State private var level: Double?
    @State private var pan: Double?
    @State private var hovered: String?

    private var current: Bool { session.currentTrack == track.id }
    private var soloed: Bool { session.solo.contains(track.id) }
    private var armed: Bool { session.armed[track.id] != nil }
    private var lockLabel: String { track.locked ? L10n.text("trackHeader.unlock", track.name) : L10n.text("trackHeader.lock", track.name) }

    var body: some View {
        Group {
            if LaneLayout.header(forLane: Double(height)) == .full { full } else { compact }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(current ? Theme.neonColor.opacity(0.08) : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
        .contentShape(.rect)
        .onTapGesture(count: 2) { rename(track.id) }
        .onTapGesture { session.currentTrack = track.id }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(track.name)
    }

    /// A lane too low for all of it (LaneLayout.header): the name and M, S, R on one row, in the middle of the lane.
    /// The level, the meter and the input are in the mixer, and the full header is back as soon as the lane is.
    private var compact: some View {
        HStack(spacing: 4) {
            if track.locked {
                Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            Text(track.name).font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                .help(track.name)
                .layoutPriority(1)
            Spacer(minLength: 4)
            toggle("M", on: track.isMuted, color: .orange, help: L10n.text("mixer.mute.ax", track.name)) {
                set(["muted": .bool(!track.isMuted)])
            }
            toggle("S", on: soloed, color: .yellow, help: L10n.text("mixer.solo.ax", track.name)) {
                var s = session.solo
                if s.contains(track.id) { s.remove(track.id) } else { s.insert(track.id) }
                session.setSolo(s)
            }
            toggle("R", on: armed, color: StateKind.error.color, help: armed ? L10n.text("record.disarm.help", track.name) : L10n.text("record.arm.help", track.name)) {
                Task { await session.toggleArm(track.id) }
            }
            .accessibilityIdentifier("header.arm")
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
    }

    private var full: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if track.locked {
                    Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.secondary).accessibilityHidden(true)
                }
                Text(track.name).font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                    .help(track.name)
            }
            HStack(spacing: 4) {
                toggle("M", on: track.isMuted, color: .orange, help: L10n.text("mixer.mute.ax", track.name)) {
                    set(["muted": .bool(!track.isMuted)])
                }
                toggle("S", on: soloed, color: .yellow, help: L10n.text("mixer.solo.ax", track.name)) {
                    var s = session.solo
                    if s.contains(track.id) { s.remove(track.id) } else { s.insert(track.id) }
                    session.setSolo(s)
                }
                // Arm to record (only here, in the window: SIBLINGS §5). Red while armed, with its input beside it.
                toggle("R", on: armed, color: StateKind.error.color, help: armed ? L10n.text("record.disarm.help", track.name) : L10n.text("record.arm.help", track.name)) {
                    Task { await session.toggleArm(track.id) }
                }
                .accessibilityIdentifier("header.arm")
                if let arm = session.armed[track.id], let r = session.recorder {
                    Menu {
                        ForEach(0..<r.deviceChannels, id: \.self) { ch in
                            Button(L10n.text("record.input.mono", String(ch + 1))) { session.setInput(track.id, first: ch, channels: 1) }
                        }
                        ForEach(stride(from: 0, to: r.deviceChannels - 1, by: 2).map { $0 }, id: \.self) { ch in
                            Button(L10n.text("record.input.stereo", String(ch + 1), String(ch + 2))) { session.setInput(track.id, first: ch, channels: 2) }
                        }
                    } label: {
                        Text(arm.channels == 2 ? L10n.text("record.input.stereo", String(arm.first + 1), String(arm.first + 2)) : L10n.text("record.input.mono", String(arm.first + 1)))
                            .font(.system(size: 9))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(L10n.text("record.input.help"))
                    .accessibilityLabel(L10n.text("record.input.ax", track.name))
                    .accessibilityIdentifier("header.input")
                }
                Button { set(["locked": .bool(!track.locked)]) } label: {
                    Image(systemName: track.locked ? "lock.fill" : "lock.open").font(.system(size: 10)).frame(width: 20, height: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(track.locked ? Theme.neonColor : .secondary)
                .help(lockLabel)
                .accessibilityLabel(lockLabel)
                Spacer(minLength: 0)
                EditableValue(text: L10n.number(level ?? track.gainDB, 1, sign: true) + " dB", draftText: L10n.number(track.gainDB, 1),
                              help: L10n.text("mixer.level.edit.help"), width: 52,
                              commit: { typed in
                                  guard let v = ValueEntry.decibels(typed) else { return false }
                                  if v != track.gainDB { set(["gainDB": .number(v)]) }
                                  return true
                              },
                              reset: { if track.gainDB != 0 { set(["gainDB": .number(0)]) } })
                    .foregroundStyle(.secondary)
            }
            MeterBar(level: session.meters.level(track.id)) { session.meters.clearClip(track.id) }.frame(height: 6)
            if height >= 74 {
                ResettableSlider(value: Binding(get: { level ?? track.gainDB }, set: { level = ($0 * 2).rounded() / 2 }), in: -60...12, reset: 0, label: L10n.text("trackHeader.level.ax", track.name), valueText: L10n.number(level ?? track.gainDB, 1) + " dB") { editing in
                    if !editing, let v = level { if v != track.gainDB { set(["gainDB": .number(v)]) }; level = nil }
                }
                .controlSize(.mini)
                .help(L10n.text("trackHeader.level.help"))
            }
            if height >= 96, stereo {
                ResettableSlider(value: Binding(get: { pan ?? track.pan }, set: { pan = ($0 * 50).rounded() / 50 }), in: -1...1, reset: 0, label: L10n.text("mixer.pan.ax", track.name), valueText: panText(pan ?? track.pan)) { editing in
                    if !editing, let v = pan { if v != track.pan { set(["pan": .number(v)]) }; pan = nil }
                }
                .controlSize(.mini)
                .help(panText(pan ?? track.pan))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }

    private func toggle(_ letter: String, on: Bool, color: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(letter).font(.system(size: 10, weight: .bold)).frame(width: 18, height: 16)
                .foregroundStyle(on ? Color.black : .secondary)
                .background(on ? color : Color.white.opacity(hovered == letter ? 0.2 : 0.08), in: .rect(cornerRadius: 3))
        }
        // The button under the pointer lights a little (COMFORT 21, 46).
        .onHover { inside in hovered = inside ? letter : (hovered == letter ? nil : hovered) }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    private func panText(_ v: Double) -> String {
        abs(v) < 0.01 ? L10n.text("trackHeader.pan.center") : v < 0 ? L10n.text("trackHeader.pan.left", String(Int((-v * 100).rounded())))
            : L10n.text("trackHeader.pan.right", String(Int((v * 100).rounded())))
    }

    private func set(_ params: [String: JSONValue]) {
        session.currentTrack = track.id
        session.perform("set_track", params.merging(["track": .string(track.id.uuidString)]) { a, _ in a })
    }
}

/// The header column's host: a right-click on a header gives that track's menu from the registry (Rename, Mute, Solo,
/// Lock, Duplicate, Move, Delete, Plugins…), named and checked as in the menu bar (COMFORT 37, 4).
final class TrackHeaderHost: NSHostingView<TrackHeaders> {
    weak var session: EditorSession?
    /// Scrolling over the headers scrolls the tracks, as over the lanes.
    var onScroll: ((NSEvent) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        if let onScroll { onScroll(event) } else { super.scrollWheel(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let session, !session.project.tracks.isEmpty else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        // From the top (the view isn't flipped), through the lanes' own layout.
        let l = TrackHeaders.layout(session, height: bounds.height)
        guard let i = l.lane(atY: Double(bounds.height - p.y)), let t = session.project.tracks[safe: i] else { return nil }
        session.currentTrack = t.id
        return CommandCenter.contextMenu(.track)
    }
}

/// A slider's value as text that can be typed into (COMFORT 17) and reset (COMFORT 65): a click opens a field with the
/// number, Return applies it as one step (ValueEntry reads it as people write it), Esc or leaving it changes nothing,
/// a double-click sets the default back.
struct EditableValue: View {
    let text: String
    /// What the field starts with: the number alone.
    let draftText: String
    let help: String
    var font: Font = .system(size: 10, design: .monospaced)
    var width: CGFloat = 64
    /// The typed text, applied; false when it isn't a value (a beep, and the field stays).
    let commit: (String) -> Bool
    let reset: () -> Void
    @State private var draft: String?
    @FocusState private var focused: Bool

    var body: some View {
        if let d = draft {
            TextField("", text: Binding(get: { d }, set: { draft = $0 }))
                .font(font)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
                .focused($focused)
                .onAppear { focused = true }
                .onSubmit { if commit(draft ?? "") { draft = nil } else { NSSound.beep() } }
                .onExitCommand { draft = nil }
                .onChange(of: focused) { _, now in if !now { draft = nil } }
                .accessibilityLabel(help)
        } else {
            Text(text).font(font).lineLimit(1)
                .contentShape(.rect)
                .onTapGesture(count: 2, perform: reset)
                .onTapGesture { draft = draftText }
                .help(help)
        }
    }
}
