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
    @ObservationIgnored private var prepared: FlimmerSend.Prepared?
    @ObservationIgnored private var client: FlimmerSend.Client?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(session: EditorSession) {
        self.session = session
        // What can be said without Flimmer: whether the document can go back at all.
        if let no = FlimmerSend.refusal(session.project) { stage = .failed(no.message) }
    }

    static let transport: FlimmerSend.Transport = { request in
        let (data, response) = try await KeyedRequest.data(for: request, session: .shared)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    /// Renders and uploads the files and asks Flimmer what it would do.
    func check() {
        let project = session.project, pool = session.pool, safe = EditorSession.pluginSafeMode, mode = self.mode
        stage = .working("Looking for Flimmer…")
        task = Task {
            do {
                let debug = Bundle.main.bundleIdentifier?.hasSuffix(".debug") ?? false
                guard let base = await FlimmerSend.find(transport: Self.transport, debug: debug) else {
                    throw FlimmerSend.Failure("not_running", "Flimmer is not running. Start Flimmer, open the film's project there, and try again.")
                }
                let client = FlimmerSend.Client(base: base, transport: Self.transport)
                self.client = client
                stage = .working("Preparing the files…")
                let p = try await FlimmerSend.prepare(project, mode: mode, client: client, render: { item, depth, rate in
                    // Plugins included, as the track sounds here.
                    try FlimmerSend.wavFile(PlanCompiler.mixBlocking(item.render, pool: pool, outOfProcess: safe), range: item.range,
                                            bitDepth: depth, sampleRate: rate, monoIfSame: item.monoSource, scratch: MediaStore.folder)
                }, progress: { p in Task { @MainActor in if case .working = self.stage { self.stage = .working("Preparing the files… \(Int(p * 100)) %") } } })
                prepared = p
                lines = p.lines
                flimmerLines = p.flimmerLines
                flimmerWarnings = p.flimmerWarnings
                stage = .ready
            } catch {
                stage = .failed(error.localizedDescription)
            }
        }
    }

    func send() {
        guard let prepared, let client else { return }
        stage = .sending
        task = Task {
            do {
                (flimmerLines, flimmerWarnings) = try await FlimmerSend.sendCounting(prepared, client: client)
                self.prepared = nil
                stage = .done
                session.status = "Sent to Flimmer. One undo step there takes it back."
            } catch {
                stage = .failed(error.localizedDescription)
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
            Text("Send to Flimmer").font(.title3.weight(.semibold))
            Picker("What to send", selection: $model.mode) {
                Text("Each changed clip as a new take").tag(FlimmerSend.Mode.takes)
                Text("The whole mix as one clip").tag(FlimmerSend.Mode.mix)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(model.stage != .choose)
            Text("Nothing is overwritten in Flimmer: originals are muted and kept, and one undo there takes everything back.")
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
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
            HStack {
                Spacer()
                Button(model.stage == .done ? "Close" : "Cancel") { model.close(); close() }.keyboardShortcut(.cancelAction)
                switch model.stage {
                case .choose: Button("Check with Flimmer") { model.check() }.keyboardShortcut(.defaultAction)
                case .ready: Button("Send") { model.send() }.keyboardShortcut(.defaultAction)
                case .sending: ProgressView().controlSize(.small)
                default: EmptyView()
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
