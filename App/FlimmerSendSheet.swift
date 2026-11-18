import AppKit
import JammerAssistant
import JammerAgent
import JammerCore
import OSLog
import SwiftUI

/// When and why the sheet closed, kept in the system log (notice), so that a sheet that went away in a test can be
/// looked into afterwards (the coordinator, 2026-11-18, after a click in a live test both closed it and started playback).
let sheetLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.brattoo.jammer", category: "sheets")

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
    /// Transcripts on their own, to the clips this document sent before: ready, or why not (one sentence).
    var transcriptsOnlyReady = false
    var transcriptsOnlyWhy: String?
    @ObservationIgnored private var prepared: FlimmerSend.Prepared?
    @ObservationIgnored private var client: FlimmerSend.Client?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(session: EditorSession) {
        self.session = session
        // What can be said without Flimmer: whether the document can go back at all.
        if let no = FlimmerSend.refusal(session.project) { stage = .failed(L10n.error(no)) }
        lookForTranscriptsOnly()
    }

    /// Whether transcripts can go on their own now: the document remembers clips from a send, and Flimmer has
    /// that project open. Otherwise the sheet says why, in a sentence (only when the document has a transcript).
    func lookForTranscriptsOnly() {
        let project = session.project
        guard !project.transcripts.isEmpty else { return }
        if let no = FlimmerSend.transcriptsOnlyRefusal(project, openProject: nil) { transcriptsOnlyWhy = Self.said(no); return }
        Task {
            let debug = AgentAPI.isDebugBundle(Bundle.main.bundleIdentifier ?? "")
            guard let base = await FlimmerSend.find(transport: Self.transport, debug: debug) else {
                transcriptsOnlyWhy = L10n.text("flimmer.transcriptsOnly.why.notRunning"); return
            }
            let client = FlimmerSend.Client(base: base, transport: Self.transport)
            let open = await FlimmerSend.openProject(client)
            if let no = FlimmerSend.transcriptsOnlyRefusal(project, openProject: open) { transcriptsOnlyWhy = Self.said(no); return }
            self.client = client
            transcriptsOnlyReady = true
        }
    }

    static func said(_ r: FlimmerSend.TranscriptsOnlyRefusal) -> String {
        switch r {
        case .noneSent: L10n.text("flimmer.transcriptsOnly.why.noneSent")
        case .noTranscript: L10n.text("flimmer.transcriptsOnly.why.noTranscript")
        case .otherProject: L10n.text("flimmer.transcriptsOnly.why.otherProject")
        }
    }

    /// Clip by clip, in the window's language: which transcripts went and which didn't, with Flimmer's own words.
    static func lines(_ outcomes: [FlimmerSend.TranscriptOutcome], soundWent: Bool) -> [String] {
        guard !outcomes.isEmpty else { return [] }
        let good = outcomes.filter(\.ok), bad = outcomes.filter { !$0.ok }
        var out: [String] = []
        if bad.isEmpty { out.append(L10n.text("flimmer.transcripts.all", String(good.count))) }
        else if good.isEmpty { out.append(soundWent ? L10n.text("flimmer.transcripts.none", String(bad.count)) : L10n.text("flimmer.transcripts.noneOnly", String(bad.count))) }
        else { out.append(L10n.text("flimmer.transcripts.some", String(good.count), String(outcomes.count), String(bad.count))) }
        for o in good { out.append(o.replacedEdited ? L10n.text("flimmer.transcripts.sentReplaced", o.name) : L10n.text("flimmer.transcripts.sent", o.name)) }
        for o in bad {
            out.append(L10n.text("flimmer.transcripts.notSent", o.name, o.message ?? "", o.reason ?? "")
                       + (FlimmerSend.clipGone(o) ? " " + L10n.text("flimmer.transcripts.gone") : ""))
        }
        return out
    }

    /// Only the transcripts, again, to the clips the last send made; each said by itself.
    func sendTranscriptsOnly() {
        guard let client else { return }
        let project = session.project, replace = replaceEdited
        stage = .sending
        task = Task {
            let outcomes = await FlimmerSend.sendTranscriptsOnly(project, replaceEdited: replace, client: client)
            transcriptLines = Self.lines(outcomes, soundWent: false)
            transcriptFailures = outcomes.filter { !$0.ok }.count
            stage = .done
            sheetLog.notice("Send to Flimmer: transcripts only, \(outcomes.count - self.transcriptFailures) of \(outcomes.count) went")
            session.status = transcriptFailures == 0 ? L10n.text("flimmer.transcriptsOnly.sent", String(outcomes.count))
                : L10n.text("flimmer.sent.transcriptsMissing", String(outcomes.count - transcriptFailures), String(outcomes.count))
        }
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
                // The document remembers what each clip became there, so its transcripts can go again on their own.
                let remembered = FlimmerSend.remembering(session.project, items: prepared.items, created: r.created, projectId: session.project.imported?.projectId)
                if remembered.imported != session.project.imported { session.commit(remembered, action: L10n.text("flimmer.remember.undo")) }
                (flimmerLines, flimmerWarnings) = (r.lines, r.warnings)
                transcriptLines = Self.lines(r.transcripts, soundWent: true)
                transcriptFailures = r.transcripts.filter { !$0.ok }.count
                self.prepared = nil
                stage = .done
                // The status line says the sound went, and, when some transcripts didn't, that not all of them did.
                // Canceled too late: Flimmer had already made the clips, and that is said (they are remembered above).
                session.status = r.canceledLate ? L10n.text("flimmer.sent.canceledLate", String(r.created.count))
                    : transcriptFailures == 0 ? L10n.text("flimmer.sent")
                    : L10n.text("flimmer.sent.transcriptsMissing", String(r.transcripts.count - transcriptFailures), String(r.transcripts.count))
            } catch {
                stage = .failed(L10n.error(error))
            }
        }
    }

    /// Set when the sheet is closed by its own button (Cancel or Close, by click, Return or Escape).
    var closedByButton = false

    /// Closing without sending takes the uploaded files away from Flimmer again.
    func close() {
        closedByButton = true
        sheetLog.notice("Send to Flimmer closed by its \(self.stage == .done ? "Close" : "Cancel", privacy: .public) button (click, or Escape/Return) at stage \(String(describing: self.stage), privacy: .public)")
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
            if model.stage == .choose, !model.transcriptsOnlyReady, let why = model.transcriptsOnlyWhy {
                StateLine(kind: .info, text: why, font: .callout).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("flimmer.transcriptsOnly.why")
            }
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
                    .accessibilityIdentifier(model.stage == .done ? "flimmer.close" : "flimmer.cancel")
                switch model.stage {
                case .choose:
                    if model.transcriptsOnlyReady {
                        Button(L10n.text("flimmer.transcriptsOnly")) { model.sendTranscriptsOnly() }.accessibilityIdentifier("flimmer.transcriptsOnly")
                    }
                    Button(L10n.text("flimmer.check")) { model.check() }.keyboardShortcut(.defaultAction).accessibilityIdentifier("flimmer.check")
                case .ready: Button(L10n.text("button.send")) { model.send() }.keyboardShortcut(.defaultAction).accessibilityIdentifier("flimmer.send")
                case .sending: ProgressView().controlSize(.small)
                default: EmptyView()
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { sheetLog.notice("Send to Flimmer opened") }
        // Gone without its own button: closed some other way (the window closed, the sheet was ended from outside).
        .onDisappear { if !model.closedByButton { sheetLog.notice("Send to Flimmer went away without its own button, at stage \(String(describing: model.stage), privacy: .public)") } }
    }
}
