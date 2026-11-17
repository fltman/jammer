import AppKit
import AVFoundation
import JammerAgent
import JammerCore
import SwiftUI

/// Keeps a film at the playhead: stopped, it shows the picture where the playhead is; playing, it runs
/// beside the sound and is put right when it has come more than two pictures away. The film's own sound
/// is never played. Nothing here is on the audio thread, and nothing is written to the film.
@MainActor
@Observable
final class PictureFollower {
    enum State: Equatable { case none, loading, ready, missing, unreadable, beforeStart, afterEnd }
    private(set) var state: State = .none
    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private weak var session: EditorSession?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var loaded: VideoReference?
    @ObservationIgnored private var length = 0.0
    @ObservationIgnored private var shown = -1.0       // the film time last sought to while stopped
    @ObservationIgnored private var running = false

    init(session: EditorSession) {
        self.session = session
        player.isMuted = true
        player.allowsExternalPlayback = false
        player.actionAtItemEnd = .pause
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.follow() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        follow()
    }
    func stop() {
        timer?.invalidate(); timer = nil
        player.pause(); running = false
    }

    private func load(_ video: VideoReference?) {
        loaded = video
        shown = -1; running = false; length = 0
        player.pause()
        guard let video else { player.replaceCurrentItem(with: nil); state = .none; return }
        guard FileManager.default.fileExists(atPath: video.path) else { player.replaceCurrentItem(with: nil); state = .missing; return }
        state = .loading
        let asset = AVURLAsset(url: URL(fileURLWithPath: video.path))
        Task { [weak self] in
            // A film has a picture track and a length; anything else is said to be unreadable, not shown as black.
            let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            let seconds = ((try? await asset.load(.duration)) ?? .zero).seconds
            guard let self, self.loaded == video else { return }
            guard !tracks.isEmpty, seconds.isFinite, seconds > 0 else { self.player.replaceCurrentItem(with: nil); self.state = .unreadable; return }
            self.length = seconds
            self.player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            self.state = .ready
            self.follow()
        }
    }

    private func follow() {
        guard let session else { return }
        let project = session.project
        if project.video != loaded { load(project.video) }
        guard let video = loaded, length > 0 else { return }
        guard let at = video.filmSeconds(at: session.playhead, sampleRate: project.sampleRate) else {
            if running { player.pause(); running = false }
            if state != .beforeStart { state = .beforeStart; shown = -1 }
            return
        }
        guard at < length else {
            if running { player.pause(); running = false }
            if state != .afterEnd { state = .afterEnd; shown = -1 }
            return
        }
        if state != .ready { state = .ready }
        let time = CMTime(seconds: at, preferredTimescale: 48_000)
        if session.isPlaying {
            if !running {
                running = true
                player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    MainActor.assumeIsolated { if self?.running == true { self?.player.play() } }
                }
            } else if player.rate != 0, abs(player.currentTime().seconds - at) > 0.08 {
                // Come apart (a seek while playing, a loop, a slow start): put right.
                player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            shown = -1
        } else {
            if running { player.pause(); running = false }
            if abs(shown - at) > 0.004 {
                shown = at
                player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }
}

/// The film's picture.
private struct PictureLayer: NSViewRepresentable {
    let player: AVPlayer
    final class Host: NSView {
        let picture = AVPlayerLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor
            picture.videoGravity = .resizeAspect
            layer?.addSublayer(picture)
        }
        required init?(coder: NSCoder) { nil }
        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            picture.frame = bounds
            CATransaction.commit()
        }
    }
    func makeNSView(context: Context) -> Host {
        let v = Host(frame: .zero)
        v.picture.player = player
        v.setAccessibilityElement(true)
        v.setAccessibilityRole(.image)
        v.setAccessibilityIdentifier("picture.film")
        v.setAccessibilityLabel(L10n.text("picture.ax.film"))
        return v
    }
    func updateNSView(_ v: Host, context: Context) {}
}

struct PictureSheet: View {
    let session: EditorSession
    let follower: PictureFollower

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PictureLayer(player: follower.player)
                .frame(minWidth: 320, minHeight: 180)
            HStack(spacing: 10) {
                line
                Spacer(minLength: 8)
                if session.project.video != nil {
                    Button(L10n.text("picture.startHere")) {
                        guard let v = session.project.video else { return }
                        session.perform("set_video_reference", ["path": .string(v.path), "at": .number(session.project.seconds(session.playhead))])
                    }
                    .help(L10n.text("picture.startHere.help"))
                    .accessibilityIdentifier("picture.startHere")
                    Button(L10n.text("picture.remove")) { session.perform("remove_video_reference") }
                        .accessibilityIdentifier("picture.remove")
                }
                Button(L10n.text("picture.choose")) { choose() }
                    .accessibilityIdentifier("picture.choose")
            }
            .controlSize(.small)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .onAppear { follower.start() }
        .onDisappear { follower.stop() }
    }

    @ViewBuilder private var line: some View {
        let name = session.project.video?.name ?? ""
        switch follower.state {
        case .none: StateLine(kind: .info, text: L10n.text("picture.state.none"))
        case .loading: StateLine(kind: .progress, text: L10n.text("picture.state.loading", name))
        case .ready: Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        case .missing: StateLine(kind: .warning, text: L10n.text("picture.state.missing", name))
        case .unreadable: StateLine(kind: .error, text: L10n.text("picture.state.unreadable", name))
        case .beforeStart: StateLine(kind: .info, text: L10n.text("picture.state.before", name))
        case .afterEnd: StateLine(kind: .info, text: L10n.text("picture.state.after", name))
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.quickTimeMovie, .mpeg4Movie, UTType("com.apple.m4v-video")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = L10n.text("picture.choose.message")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // A film chosen again keeps its place on the timeline; a new one starts at the timeline's start.
        let at = session.project.video?.path == url.standardizedFileURL.path ? session.project.video?.start : nil
        session.perform("set_video_reference", ["path": .string(url.path), "at": .number(session.project.seconds(at ?? 0))])
    }
}

final class PictureWindow: NSWindow, NSWindowDelegate {
    weak var session: EditorSession? { didSet { delegate = self } }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { session?.document?.undoManager }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49, event.modifierFlags.intersection([.command, .option, .control]).isEmpty { session?.togglePlay(); return }
        super.keyDown(with: event)
    }
}
