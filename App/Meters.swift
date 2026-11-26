import Foundation
import JammerCore
import Observation
import SwiftUI

/// The peak meters (the comfort block, step 4; Anders chose post-fader peak with a clip light): each track, bus and
/// the master, read from the engine 30 times a second while the sound plays. A meter holds its peak 1.5 s and then
/// falls 20 dB a second; a peak at or over full scale lights the strip's clip light, which stays lit until clicked.
/// The numbers are the engine's sample peaks, tested against squares of known amplitude (MeterTests).
@MainActor
@Observable
final class StripMeters {
    /// The bar, the held peak's line, and the clip light: MeterBallistics (no flash faster than 3 Hz).
    typealias Level = MeterBallistics.Level
    private(set) var levels: [UUID: Level] = [:]
    /// Where the mix first reaches full scale on the timeline (the timeline's clip light, Flimmer's K5): found in the
    /// background 1.5 s after the document last changed, with a plan of its own and never by playing. nil: nowhere.
    private(set) var clipAt: Frame?
    @ObservationIgnored private var scannedVersion = -1
    @ObservationIgnored private var changedVersion = -1
    @ObservationIgnored private var changedAt = Date()
    @ObservationIgnored private var scan: Task<Void, Never>?
    @ObservationIgnored private var lastFrame: Frame?
    @ObservationIgnored private var lastTick = Date()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private weak var session: EditorSession?

    static let floor = MeterBallistics.floor

    func attach(_ session: EditorSession) {
        self.session = session
        loop?.cancel()
        // 30 times a second; ends by itself once the window's session (and so these meters) is gone.
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self, self.session != nil else { return }
                self.tick()
            }
        }
    }

    func level(_ id: UUID) -> Level { levels[id] ?? Level() }

    private func scanIfDue(_ session: EditorSession) {
        if session.version != changedVersion {
            changedVersion = session.version
            changedAt = Date()
            scan?.cancel()
            scan = nil
        }
        guard changedVersion != scannedVersion, scan == nil, !session.isPlaying, Date().timeIntervalSince(changedAt) > 1.5 else { return }
        let version = changedVersion, project = session.project, pool = session.pool, safe = EditorSession.pluginSafeMode
        let stop = JobRegistry.StopFlag()
        scan = Task { [weak self] in
            let found = await withTaskCancellationHandler {
                await Task.detached(priority: .utility) { () -> Frame? in
                    let plan = PlanCompiler.mixBlocking(project, pool: pool, outOfProcess: safe)
                    return plan.firstOver(0..<project.length, cancelled: { stop.isSet })
                }.value
            } onCancel: { stop.set() }
            guard let self, !Task.isCancelled, self.changedVersion == version else { return }
            self.clipAt = found
            self.scannedVersion = version
            self.scan = nil
        }
    }
    func clearClip(_ id: UUID) { levels[id]?.clipped = false }

    private func tick() {
        guard let session else { return }
        scanIfDue(session)
        let now = Date(), dt = now.timeIntervalSince(lastTick)
        lastTick = now
        let p = session.project
        var peaks: [UUID: Float] = [:]
        if session.isPlaying {
            let frame = session.output.playhead
            // What was heard since the last look; after a jump, the last block only.
            let from = lastFrame.flatMap { $0 <= frame && frame - $0 < Frame(p.sampleRate) ? $0 : nil } ?? max(0, frame - 2_048)
            lastFrame = frame
            let t = session.output.meterPeaks(from: from, to: frame + 1, kind: 0, count: p.tracks.count)
            for (i, track) in p.tracks.enumerated() where i < t.count { peaks[track.id] = t[i] }
            let b = session.output.meterPeaks(from: from, to: frame + 1, kind: 1, count: p.buses.count)
            for (i, bus) in p.buses.enumerated() where i < b.count { peaks[bus.id] = b[i] }
            peaks[Master.id] = session.output.meterPeaks(from: from, to: frame + 1, kind: 2, count: 1).first
        } else {
            lastFrame = nil
            if session.armed.isEmpty, levels.values.allSatisfy({ $0.db == -.infinity && $0.held == -.infinity }) { return }
        }
        // An armed track's meter shows its input, before and while it records (the level set before pressing Record).
        for id in session.armed.keys { if let p = session.inputPeak(id) { peaks[id] = p } }
        var next = levels
        for id in p.tracks.map(\.id) + p.buses.map(\.id) + [Master.id] {
            let db = peaks[id].map { $0 > 0 ? 20 * log10(Double($0)) : -.infinity } ?? -.infinity
            // The ballistics, with the bar held 0.4 s after it rises (no flash faster than 3 Hz).
            next[id] = MeterBallistics.next(next[id] ?? Level(), peak: db, dt: dt, now: now)
        }
        if next != levels { levels = next }
    }
}

/// A meter: a bar from −60 to 0 dBFS (green, yellow from −12, red from −3), the held peak as a line, and the clip
/// light, which a click puts out.
struct MeterBar: View {
    let level: StripMeters.Level
    var vertical = false
    let clear: () -> Void

    private func fraction(_ db: Double) -> CGFloat { db == -.infinity ? 0 : CGFloat(max(0, min(1, (db - StripMeters.floor) / -StripMeters.floor))) }

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 3))
        layout {
            if vertical { light }
            GeometryReader { g in
                let len = vertical ? g.size.height : g.size.width
                ZStack(alignment: vertical ? .bottom : .leading) {
                    Rectangle().fill(Color.white.opacity(0.08))
                    Rectangle()
                        .fill(LinearGradient(stops: [.init(color: .green, location: 0), .init(color: .green, location: 0.8),
                                                     .init(color: .yellow, location: 0.8), .init(color: .yellow, location: 0.95),
                                                     .init(color: .red, location: 0.95)],
                                             startPoint: vertical ? .bottom : .leading, endPoint: vertical ? .top : .trailing))
                        .mask(alignment: vertical ? .bottom : .leading) {
                            Rectangle().frame(width: vertical ? nil : len * fraction(level.db), height: vertical ? len * fraction(level.db) : nil)
                        }
                    if level.held > StripMeters.floor {
                        Rectangle().fill(Color.white.opacity(0.8))
                            .frame(width: vertical ? nil : 1, height: vertical ? 1 : nil)
                            .offset(x: vertical ? 0 : len * fraction(level.held) - 1, y: vertical ? -(len * fraction(level.held) - 1) : 0)
                    }
                }
            }
            if !vertical { light }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("meter.ax"))
        .accessibilityValue(level.db == -.infinity ? L10n.text("meter.silent") : L10n.text("meter.value", L10n.number(level.db, 1)) + (level.clipped ? ", " + L10n.text("meter.clipped") : ""))
    }

    private var light: some View {
        // The clip light is an error state: its colour is the error's (StateKind), as everywhere.
        Circle().fill(level.clipped ? StateKind.error.color : Color.white.opacity(0.12))
            .frame(width: 7, height: 7)
            .contentShape(.rect.inset(by: -4))
            .onTapGesture(perform: clear)
            .help(level.clipped ? L10n.text("meter.clipped.help") : L10n.text("meter.light.help"))
    }
}
