import AppKit
import JammerAssistant
import JammerAgent
import JammerAssistant
import JammerCore
import SwiftUI

/// File › Send to Flimmer…: the sound of a film that came from Flimmer goes back as new
/// takes or as one mix. The sheet first shows what would happen (Jämmer's list and
/// Flimmer's own dry run); nothing changes in Flimmer until Send.
@MainActor
@Observable
final class FlimmerSendModel {
    enum Stage: Equatable { case choose, working(String), ready, sending, done, failed(String) }
    let session: EditorSession
    var mode: FlimmerSend.Mode = .takes
    var stage: Stage = .choose
    var lines: [String] = []
    var flimmerLines: [String] = []
    /// How many of them, from the first, are warnings.
    var flimmerWarnings = 0
    /// Send each clip's transcript after the sound (when it has one).
    var sendTranscripts = true
    /// Replace a transcript a person corrected by hand in Flimmer: off every time the sheet opens, never kept.
    var replaceEdited = false
    /// How each transcript went, clip by clip, and how many of the lines (from the first after the summary) failed.
    var transcriptLines: [String] = []
    var transcriptFailures = 0
    var hasTranscripts: Bool { !(prepared?.transcripts.isEmpty ?? true) }
    @ObservationIgnored private var prepared: FlimmerSend.Prepared?
    @ObservationIgnored private var client: FlimmerSend.Client?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(session: EditorSession) {
        self.session = session
        // What can be said without Flimmer: whether the document can go back at all.
        if let no = FlimmerSend.refusal(session.project) { stage = .failed(L10n.error(no)) }
    }

    static let transport: FlimmerSend.Transport = { request in
        let (data, response) = try await KeyedRequest.data(for: request, session: .shared)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    /// Renders and uploads the files and asks Flimmer what it would do.
    func check() {
        let project = session.project, pool = session.pool, safe = EditorSession.pluginSafeMode, mode = self.mode
        stage = .working(L10n.text("flimmer.looking"))
        task = Task {
            do {
                // A guest copy (…debug.guest) is a debug build too, and pairs with a debug or guest Flimmer
                // (found in the live test, 2026-11-18: the guest asked only for a release Flimmer).
                let debug = AgentAPI.isDebugBundle(Bundle.main.bundleIdentifier ?? "")
                guard let base = await FlimmerSend.find(transport: Self.transport, debug: debug) else {
                    throw FlimmerSend.Failure("not_running", "Flimmer is not running. Start Flimmer, open the film's project there, and try again.")
                }
                let client = FlimmerSend.Client(base: base, transport: Self.transport)
                self.client = client
                stage = .working(L10n.text("flimmer.preparing"))
                let p = try await FlimmerSend.prepare(project, mode: mode, client: client, render: { item, depth, rate in
                    // Plugins included, as the track sounds here.
                    try FlimmerSend.wavFile(PlanCompiler.mixBlocking(item.render, pool: pool, outOfProcess: safe), range: item.range,
                                            bitDepth: depth, sampleRate: rate, monoIfSame: item.monoSource, scratch: MediaStore.folder)
                }, progress: { p in Task { @MainActor in if case .working = self.stage { self.stage = .working(L10n.text("flimmer.preparing.percent", String(Int(p * 100)))) } } })
                prepared = p
                lines = p.lines
                flimmerLines = p.flimmerLines
                flimmerWarnings = p.flimmerWarnings
                stage = .ready
            } catch {
                stage = .failed(L10n.error(error))
            }
        }
    }

    func send() {
        guard let prepared, let client else { return }
        stage = .sending
        task = Task {
            do {
                let r = try await FlimmerSend.sendAll(prepared, client: client, transcripts: sendTranscripts, replaceEdited: replaceEdited)
                (flimmerLines, flimmerWarnings) = (r.lines, r.warnings)
                transcriptLines = FlimmerSend.transcriptLines(r.transcripts)
                transcriptFailures = r.transcripts.filter { !$0.ok }.count
                self.prepared = nil
                stage = .done
                // The status line says the sound went, and, when some transcripts didn't, that not all of them did.
                session.status = transcriptFailures == 0 ? L10n.text("flimmer.sent")
                    : L10n.text("flimmer.sent.transcriptsMissing", String(r.transcripts.count - transcriptFailures), String(r.transcripts.count))
            } catch {
                stage = .failed(L10n.error(error))
            }
        }
    }

    /// Closing without sending takes the uploaded files away from Flimmer again.
    func close() {
        task?.cancel()
        if let prepared, let client { Task { await FlimmerSend.cancel(prepared, client: client) } }
        prepared = nil
    }
}

struct FlimmerSendSheet: View {
    @Bindable var model: FlimmerSendModel
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("flimmer.title")).font(.title3.weight(.semibold))
            Picker(L10n.text("flimmer.what"), selection: $model.mode) {
                Text(L10n.text("flimmer.mode.takes")).tag(FlimmerSend.Mode.takes)
                Text(L10n.text("flimmer.mode.mix")).tag(FlimmerSend.Mode.mix)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(model.stage != .choose)
            Toggle(L10n.text("flimmer.transcripts"), isOn: $model.sendTranscripts)
                .disabled(model.stage == .sending || model.stage == .done)
                .accessibilityIdentifier("flimmer.transcripts")
            Toggle(L10n.text("flimmer.replaceEdited"), isOn: $model.replaceEdited)
                .disabled(!model.sendTranscripts || model.stage == .sending || model.stage == .done)
                .accessibilityIdentifier("flimmer.replaceEdited")
            Text(L10n.text("flimmer.promise"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            switch model.stage {
            case .choose: EmptyView()
            case .working(let what), .failed(let what):
                StateLine(kind: model.stage == .working(what) ? .progress : .error, text: what, font: .callout)
                    .fixedSize(horizontal: false, vertical: true)
            case .ready, .sending, .done:
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(model.lines.enumerated()), id: \.offset) { _, l in Text(l).fixedSize(horizontal: false, vertical: true) }
                        if !model.flimmerLines.isEmpty { Divider() }
                        ForEach(Array(model.flimmerLines.enumerated()), id: \.offset) { i, l in
                            StateLine(kind: i < model.flimmerWarnings ? .warning : .info, text: l, font: .body)
                        }
                        // Clip by clip: which got its transcript and which didn't, in Flimmer's words.
                        ForEach(Array(model.transcriptLines.enumerated()), id: \.offset) { i, l in
                            StateLine(kind: i == 0 ? (model.transcriptFailures > 0 ? .warning : .success)
                                      : (i > model.transcriptLines.count - 1 - model.transcriptFailures ? .error : .success), text: l, font: .body)
                        }
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // A sheet sizes itself by what it holds, and a scroll view asks for almost nothing: without a
                // height of its own it showed one line of the list (found in the live test, 2026-11-18).
                .frame(height: min(260, CGFloat(model.lines.count + model.flimmerLines.count + model.transcriptLines.count) * 22 + 24))
            }
            HStack {
                Spacer()
                Button(model.stage == .done ? L10n.text("button.close") : L10n.text("button.cancel")) { model.close(); close() }.keyboardShortcut(.cancelAction)
                switch model.stage {
                case .choose: Button(L10n.text("flimmer.check")) { model.check() }.keyboardShortcut(.defaultAction)
                case .ready: Button(L10n.text("button.send")) { model.send() }.keyboardShortcut(.defaultAction)
                case .sending: ProgressView().controlSize(.small)
                default: EmptyView()
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
