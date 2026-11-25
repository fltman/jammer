import AppKit
import JammerAgent
import JammerCore
import SwiftUI

/// The track headers (the comfort block, step 4): one beside each lane, with its name, mute, solo and lock, and,
/// when the lane is tall enough, its level and pan. Each change is one undo step through set_track, committed when
/// a slider is let go (COMFORT 9), never on every move; solo is a way of listening and never a step.
struct TrackHeaders: View {
    @Bindable var session: EditorSession
    let rename: (UUID) -> Void

    var body: some View {
        GeometryReader { geo in
            let tracks = session.project.tracks
            let lane = (geo.size.height - TimelineView.rulerHeight) / CGFloat(max(1, tracks.count))
            VStack(spacing: 0) {
                Color.clear.frame(height: TimelineView.rulerHeight)
                ForEach(tracks) { t in
                    TrackHeader(session: session, track: t, height: lane, stereo: session.project.channels == 2, rename: rename)
                        .frame(height: lane)
                }
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
    private var lockLabel: String { track.locked ? L10n.text("trackHeader.unlock", track.name) : L10n.text("trackHeader.lock", track.name) }

    var body: some View {
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
                Button { set(["locked": .bool(!track.locked)]) } label: {
                    Image(systemName: track.locked ? "lock.fill" : "lock.open").font(.system(size: 10)).frame(width: 20, height: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(track.locked ? Theme.neonColor : .secondary)
                .help(lockLabel)
                .accessibilityLabel(lockLabel)
                Spacer(minLength: 0)
                Text(L10n.number(level ?? track.gainDB, 1, sign: true) + " dB").font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1)
                    // A double-click on the value puts the level back to 0 dB, one step (COMFORT 65).
                    .contentShape(.rect)
                    .onTapGesture(count: 2) { if track.gainDB != 0 { set(["gainDB": .number(0)]) } }
                    .help(L10n.text("mixer.level.reset.help"))
            }
            MeterBar(level: session.meters.level(track.id)) { session.meters.clearClip(track.id) }.frame(height: 6)
            if height >= 74 {
                Slider(value: Binding(get: { level ?? track.gainDB }, set: { level = ($0 * 2).rounded() / 2 }), in: -60...12) { editing in
                    if !editing, let v = level { if v != track.gainDB { set(["gainDB": .number(v)]) }; level = nil }
                }
                .controlSize(.mini)
                .accessibilityLabel(L10n.text("trackHeader.level.ax", track.name))
                .accessibilityValue(L10n.number(level ?? track.gainDB, 1) + " dB")
                .help(L10n.text("trackHeader.level.help"))
            }
            if height >= 96, stereo {
                Slider(value: Binding(get: { pan ?? track.pan }, set: { pan = ($0 * 50).rounded() / 50 }), in: -1...1) { editing in
                    if !editing, let v = pan { if v != track.pan { set(["pan": .number(v)]) }; pan = nil }
                }
                .controlSize(.mini)
                .accessibilityLabel(L10n.text("mixer.pan.ax", track.name))
                .accessibilityValue(panText(pan ?? track.pan))
                .help(panText(pan ?? track.pan))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(current ? Theme.neonColor.opacity(0.08) : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
        .contentShape(.rect)
        .onTapGesture(count: 2) { rename(track.id) }
        .onTapGesture { session.currentTrack = track.id }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(track.name)
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

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let session, !session.project.tracks.isEmpty else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        // From the top (the view isn't flipped): the ruler's height, then one lane per track.
        let y = bounds.height - p.y - TimelineView.rulerHeight
        let lane = (bounds.height - TimelineView.rulerHeight) / CGFloat(session.project.tracks.count)
        guard y >= 0, lane > 0, let t = session.project.tracks[safe: Int(y / lane)] else { return nil }
        session.currentTrack = t.id
        return CommandCenter.contextMenu(.track)
    }
}
