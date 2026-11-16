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
    var findings = "Looking…"
    var previewing = false
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
        guard let s = session.selection else { return "The whole document" }
        let p = session.project
        return "Selection \(formatTime(p.seconds(s.lowerBound)))–\(formatTime(p.seconds(s.upperBound)))"
    }

    var settings: Restoration.Settings {
        .init(kind: kind, amount: Float(amount), humFrequency: kind == .dehum && hum > 0 ? hum : nil, sensitivity: sensitivity)
    }

    func analyse() async {
        let project = session.project, pool = session.pool, range = self.range
        let a = await Task.detached(priority: .userInitiated) { Restoration.analyze(project, range: range, pool: pool) }.value
        var parts: [String] = []
        parts.append(a.hum.map { String(format: "Hum at %.2f Hz (%.0f dB above its surroundings)", $0.frequency, $0.prominence) } ?? "No mains hum")
        parts.append(a.clippedRuns > 0 ? "\(a.clippedRuns) clipped stretch\(a.clippedRuns == 1 ? "" : "es")" : "no clipping")
        parts.append(a.clicks > 0 ? "\(a.clicks) click\(a.clicks == 1 ? "" : "s")" : "no clicks")
        parts.append(a.rt60.map { String(format: a.reverberant ? "reverb about %.1f s" : "little reverb (%.1f s)", $0) }
                     ?? (a.reverbUnknown != nil ? "reverb not measurable after noise or hum removal" : "reverb not measurable"))
        if let n = a.noiseFloor { parts.append("noise floor \(n.level < 0 ? "−" : "")\(Int(abs(n.level).rounded())) dBFS") }
        findings = parts.joined(separator: " · ") + (a.sampled ? " (sampled)" : "")
    }

    /// Renders the repair of up to 30 s (from the selection, else the playhead) and plays it.
    func preview() async {
        stopPreview()
        previewError = nil
        let p = session.project
        let start = session.selection?.lowerBound ?? min(session.playhead, max(0, p.length - 1))
        let end = min(session.selection?.upperBound ?? p.length, start + p.frames(30))
        guard end > start else { return }
        let r = start..<end
        let dir = FileManager.default.temporaryDirectory.appending(path: "jammer-ab-\(UUID().uuidString)")
        let s = settings, pool = session.pool
        let result = await Task.detached(priority: .userInitiated) { () -> Result<Project, Error> in
            Result { try Restoration.apply(s, to: p, range: r, pool: pool, media: dir).0 }
        }.value
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
            previewError = e.localizedDescription
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
        let titles: [Restoration.Kind: String] = [.dehum: "Remove Hum", .declip: "Repair Clipping", .declick: "Remove Clicks", .denoise: "Reduce Noise", .dereverb: "Reduce Reverb"]
        _ = JobRegistry.shared.startRestoration(session, settings: settings, range: session.selection, action: titles[kind] ?? "Restore")
    }
}

struct RestoreSheet: View {
    @Bindable var model: RestoreModel
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Restore").font(.title3.weight(.semibold))
            Picker("Repair", selection: $model.kind) {
                Text("Remove Hum").tag(Restoration.Kind.dehum)
                Text("Repair Clipping").tag(Restoration.Kind.declip)
                Text("Remove Clicks").tag(Restoration.Kind.declick)
                if Restoration.denoiser != nil { Text("Reduce Noise").tag(Restoration.Kind.denoise) }
                if Restoration.dereverber != nil { Text("Reduce Reverb").tag(Restoration.Kind.dereverb) }
            }
            .onChange(of: model.kind) { _, kind in model.amount = Double(kind.defaultAmount) }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(model.rangeText).font(.callout).foregroundStyle(.secondary)
            Text(model.findings).font(.callout).foregroundStyle(Theme.neonColor)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Amount")
                    Slider(value: $model.amount, in: 0...1)
                        .accessibilityLabel("Amount")
                        .accessibilityValue("\(Int((model.amount * 100).rounded())) percent")
                    Text("\(Int((model.amount * 100).rounded())) %").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                if model.kind == .dehum {
                    GridRow {
                        Text("Mains")
                        Picker("Mains", selection: $model.hum) {
                            Text("Find it").tag(0.0)
                            Text("50 Hz").tag(50.0)
                            Text("60 Hz").tag(60.0)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        Text("")
                    }
                }
                if model.kind == .declick {
                    GridRow {
                        Text("Sensitivity")
                        Slider(value: $model.sensitivity, in: 0.25...4)
                            .accessibilityLabel("Sensitivity")
                            .accessibilityValue(String(format: "%.1f times", model.sensitivity))
                        Text(String(format: "%.1f×", model.sensitivity)).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            }
            if let e = model.previewError { Text(e).font(.callout).foregroundStyle(.orange) }
            HStack {
                Button(model.previewing ? "Stop" : "Preview") {
                    if model.previewing { model.stopPreview() } else { Task { await model.preview() } }
                }
                .help("Plays up to 30 seconds from the selection (or the playhead) with the repair.")
                Picker("Listen to", selection: Binding(get: { model.listeningToRepair }, set: { model.listen(repaired: $0) })) {
                    Text("Original").tag(false)
                    Text("Repaired").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                .disabled(!model.previewing)
                Spacer()
                Button("Cancel") { model.stopPreview(); close() }.keyboardShortcut(.cancelAction)
                Button("Apply") { model.apply(); close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 660)
        .task { await model.analyse() }
        .onChange(of: model.kind) { model.stopPreview() }
    }
}
