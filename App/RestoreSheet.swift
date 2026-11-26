import AppKit
import JammerCore
import SwiftUI

/// Audio › Restore…: pick a repair, set the amount, listen A/B on a short stretch,
/// then apply it (a job; one undo step).
@MainActor
@Observable
final class RestoreModel {
    let session: EditorSession
    var kind: Restoration.Kind
    var amount = 1.0
    /// 0 = find it, else 50 or 60.
    var hum = 0.0
    var sensitivity = 1.0
    var findings = L10n.text("restore.looking")
    var previewing = false
    /// While the preview renders: its progress and what stops it (COMFORT 7: the wait can be stopped, and a second
    /// click doesn't start a second render).
    var rendering: (progress: Double, stop: JobRegistry.StopFlag)?
    func stopRendering() { rendering?.stop.set() }
    /// The sheet goes (Cancel, Apply): a preview still rendering is stopped too, so it can't start playing after.
    func dismiss() {
        dismissed = true
        stopRendering()
        stopPreview()
    }
    @ObservationIgnored private var dismissed = false
    /// What the Preview button does: start the preview, or stop it (or its rendering). Space does the same (COMFORT 66).
    func togglePreview() {
        if rendering != nil { stopRendering() } else if previewing { stopPreview() } else { Task { await preview() } }
    }
    var listeningToRepair = true
    var previewError: String?
    @ObservationIgnored private var previewPlan: RenderPlan?
    @ObservationIgnored private var previewRange: Range<Frame>?
    @ObservationIgnored private var stopTimer: Timer?
    @ObservationIgnored private var previewDir: URL?

    init(session: EditorSession, kind: Restoration.Kind) {
        self.session = session
        self.kind = kind
        amount = Double(kind.defaultAmount)
    }

    var range: Range<Frame> { session.selection ?? 0..<session.project.length }
    var rangeText: String {
        guard let s = session.selection else { return L10n.text("restore.range.whole") }
        let p = session.project
        return L10n.text("restore.range.selection", formatTime(p.seconds(s.lowerBound)), formatTime(p.seconds(s.upperBound)))
    }

    var settings: Restoration.Settings {
        .init(kind: kind, amount: Float(amount), humFrequency: kind == .dehum && hum > 0 ? hum : nil, sensitivity: sensitivity)
    }

    func analyse() async {
        let project = session.project, pool = session.pool, range = self.range
        let a = await Task.detached(priority: .userInitiated) { Restoration.analyze(project, range: range, pool: pool) }.value
        var parts: [String] = []
        parts.append(a.hum.map { L10n.text("restore.found.hum", L10n.number($0.frequency, 2), L10n.number($0.prominence, 0)) } ?? L10n.text("restore.found.noHum"))
        parts.append(a.clippedRuns > 0 ? L10n.count("restore.found.clipped", a.clippedRuns) : L10n.text("restore.found.noClipping"))
        parts.append(a.clicks > 0 ? L10n.count("restore.found.clicks", a.clicks) : L10n.text("restore.found.noClicks"))
        parts.append(a.rt60.map { a.reverberant ? L10n.text("restore.found.reverb", L10n.number($0, 1)) : L10n.text("restore.found.littleReverb", L10n.number($0, 1)) }
                     ?? (a.reverbUnknown != nil ? L10n.text("restore.found.reverbUnknown.after") : L10n.text("restore.found.reverbUnknown")))
        if let n = a.noiseFloor { parts.append(L10n.text("restore.found.noiseFloor", "\(n.level < 0 ? "−" : "")\(Int(abs(n.level).rounded()))")) }
        findings = a.sampled ? L10n.text("restore.found.sampled", parts.joined(separator: " · ")) : parts.joined(separator: " · ")
    }

    /// Renders the repair of up to 30 s (from the selection, else the playhead) and plays it.
    func preview() async {
        guard rendering == nil else { return }
        stopPreview()
        previewError = nil
        let p = session.project
        let start = session.selection?.lowerBound ?? min(session.playhead, max(0, p.length - 1))
        let end = min(session.selection?.upperBound ?? p.length, start + p.frames(30))
        guard end > start else { return }
        let r = start..<end
        let dir = FileManager.default.temporaryDirectory.appending(path: "jammer-ab-\(UUID().uuidString)")
        let s = settings, pool = session.pool
        let stop = JobRegistry.StopFlag()
        rendering = (0, stop)
        let result = await Task.detached(priority: .userInitiated) { [weak self] () -> Result<Project, Error> in
            Result {
                try Restoration.apply(s, to: p, range: r, pool: pool, media: dir) { f in
                    Task { @MainActor in if self?.rendering?.stop === stop { self?.rendering?.progress = f } }
                    return !stop.isSet
                }.0
            }
        }.value
        rendering = nil
        if stop.isSet || dismissed {
            try? FileManager.default.removeItem(at: dir)
            return
        }
        switch result {
        case .success(let repaired):
            previewDir = dir
            previewPlan = PlanCompiler.compile(repaired, pool: pool)
            previewRange = r
            previewing = true
            listeningToRepair = true
            session.setPreviewPlan(previewPlan)
            session.play(from: r.lowerBound)
            stopTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let r = self.previewRange else { return }
                    if !self.session.isPlaying || self.session.playhead >= r.upperBound { self.stopPreview() }
                }
            }
        case .failure(let e):
            try? FileManager.default.removeItem(at: dir)
            previewError = L10n.error(e)
        }
    }

    /// A/B: switch between the original and the repair without stopping.
    func listen(repaired: Bool) {
        listeningToRepair = repaired
        guard previewing else { return }
        session.setPreviewPlan(repaired ? previewPlan : nil)
    }

    func stopPreview() {
        stopTimer?.invalidate()
        stopTimer = nil
        if previewing || previewPlan != nil {
            if session.isPlaying { session.stop() }
            session.setPreviewPlan(nil)
        }
        previewing = false
        previewPlan = nil
        previewRange = nil
        if let d = previewDir { try? FileManager.default.removeItem(at: d) }
        previewDir = nil
    }

    func apply() {
        stopPreview()
        let titles: [Restoration.Kind: String] = [.dehum: L10n.text("restore.kind.dehum"), .declip: L10n.text("restore.kind.declip"), .declick: L10n.text("restore.kind.declick"), .denoise: L10n.text("restore.kind.denoise"), .dereverb: L10n.text("restore.kind.dereverb")]
        _ = JobRegistry.shared.startRestoration(session, settings: settings, range: session.selection, action: titles[kind] ?? L10n.text("restore.title"))
    }
}

struct RestoreSheet: View {
    @Bindable var model: RestoreModel
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("restore.title")).font(.title3.weight(.semibold))
            Picker(L10n.text("restore.repair"), selection: $model.kind) {
                Text(L10n.text("restore.kind.dehum")).tag(Restoration.Kind.dehum)
                Text(L10n.text("restore.kind.declip")).tag(Restoration.Kind.declip)
                Text(L10n.text("restore.kind.declick")).tag(Restoration.Kind.declick)
                if Restoration.denoiser != nil { Text(L10n.text("restore.kind.denoise")).tag(Restoration.Kind.denoise) }
                if Restoration.dereverber != nil { Text(L10n.text("restore.kind.dereverb")).tag(Restoration.Kind.dereverb) }
            }
            .onChange(of: model.kind) { _, kind in model.amount = Double(kind.defaultAmount) }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(model.rangeText).font(.callout).foregroundStyle(.secondary)
            Text(model.findings).font(.callout).foregroundStyle(Theme.neonColor)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(L10n.text("restore.amount"))
                    Slider(value: $model.amount, in: 0...1)
                        .accessibilityLabel(L10n.text("restore.amount"))
                        .accessibilityValue(L10n.text("restore.amount.ax", String(Int((model.amount * 100).rounded()))))
                    Text(verbatim: "\(Int((model.amount * 100).rounded())) %").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                if model.kind == .dehum {
                    GridRow {
                        Text(L10n.text("restore.mains"))
                        Picker(L10n.text("restore.mains"), selection: $model.hum) {
                            Text(L10n.text("restore.mains.find")).tag(0.0)
                            Text(verbatim: "50 Hz").tag(50.0)
                            Text(verbatim: "60 Hz").tag(60.0)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        Text("")
                    }
                }
                if model.kind == .declick {
                    GridRow {
                        Text(L10n.text("restore.sensitivity"))
                        Slider(value: $model.sensitivity, in: 0.25...4)
                            .accessibilityLabel(L10n.text("restore.sensitivity"))
                            .accessibilityValue(L10n.text("restore.sensitivity.ax", L10n.number(model.sensitivity, 1)))
                        Text(L10n.number(model.sensitivity, 1) + "×").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            }
            if let e = model.previewError { StateLine(kind: .error, text: e, font: .callout) }
            HStack {
                Button(model.rendering != nil || model.previewing ? L10n.text("transport.stop") : L10n.text("restore.preview")) {
                    model.togglePreview()
                }
                .help(model.rendering != nil ? L10n.text("job.stop.help", L10n.text("restore.preview.rendering", String(Int((model.rendering?.progress ?? 0) * 100)))) : L10n.text("restore.preview.help"))
                if let r = model.rendering {
                    ProgressView(value: r.progress).frame(width: 80).controlSize(.small)
                        .accessibilityLabel(L10n.text("restore.preview.rendering", String(Int(r.progress * 100))))
                }
                Picker(L10n.text("restore.listen"), selection: Binding(get: { model.listeningToRepair }, set: { model.listen(repaired: $0) })) {
                    Text(L10n.text("restore.listen.original")).tag(false)
                    Text(L10n.text("restore.listen.repaired")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                .disabled(!model.previewing)
                Spacer()
                Button(L10n.text("button.cancel")) { model.dismiss(); close() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("button.apply")) { model.dismiss(); model.apply(); close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 660)
        .task { await model.analyse() }
        .onChange(of: model.kind) { model.stopPreview() }
    }
}
