import AppKit
import NaturalLanguage
import JammerAgent
import JammerAssistant
import JammerCore
import Security
import SwiftUI

/// The user's own keys, in the Keychain only.
enum Keychain {
    /// The app's bundle id, so debug builds keep their keys apart (com.brattoo.jammer.debug).
    static let service = Bundle.main.bundleIdentifier ?? "com.brattoo.jammer"

    #if DEBUG
    /// `-ai.noKeychain YES` (Debug builds only): keys are held in memory and the Keychain is never touched.
    /// A test copy has another signature than the app that saved a real key, and macOS then asks for the
    /// Keychain's password before the window comes up; every test and guest start uses this.
    static let memoryOnly = UserDefaults.standard.bool(forKey: "ai.noKeychain")
    nonisolated(unsafe) static var memory: [String: String] = [:]
    static let memoryLock = NSLock()
    #endif

    static func get(_ account: String) -> String? {
        #if DEBUG
        if memoryOnly { return memoryLock.withLock { memory[account] } }
        #endif
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ account: String, _ value: String?) {
        #if DEBUG
        if memoryOnly { memoryLock.withLock { memory[account] = (value?.isEmpty ?? true) ? nil : value }; return }
        #endif
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// One chat for one document.
@MainActor
@Observable
final class AssistantModel {
    /// Raised by View › Show Assistant / Ask the Assistant (⌥⌘A): the field takes the keyboard.
    var focusRequest = 0
    /// Whether the field has the keyboard now (the command hides the panel only from there).
    var fieldFocused = false
    struct Message: Identifiable {
        enum Role { case user, assistant, note }
        let id = UUID()
        var role: Role
        var text: String
    }

    let session: EditorSession
    var messages: [Message] = []
    /// The language of the question being answered: the conversation's own sentences follow it.
    var replyLanguage: NLLanguage?
    var input = ""
    var busy = false
    /// What the spinner says: planning with whom, or running the plan.
    var phase: String?
    /// The planning or the plan now running, and the jobs it started: Stop (Esc) ends it, and only its own jobs
    /// (COMFORT 7; Glimmer b8695e6: Stop on a plan stops only its jobs).
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var planJobs: Set<String> = []
    /// Whether the plan running now has changed the document yet (a stop then says so: those steps can be undone).
    @ObservationIgnored private var changedSomething = false
    /// A paid request has left for the provider in this planning: a stop may come too late to spare the charge.
    @ObservationIgnored private var paidRequestOut: String?

    func stop() {
        guard busy, let work else { return }
        work.cancel()
        for id in planJobs { _ = JobRegistry.shared.cancel(id) }
        planJobs = []
        let text = paidRequestOut.map { L10n.reply("assistant.reply.stoppedPaid", replyLanguage, $0) }
            ?? (changedSomething ? L10n.reply("assistant.reply.stoppedPart", replyLanguage) : L10n.reply("assistant.reply.stopped", replyLanguage))
        messages.append(Message(role: .note, text: text))
    }
    /// A plan waiting for the user's go-ahead (destructive, or from a paid model).
    var pending: AssistantPlan?
    /// What the pending plan does, worked out from its steps (not from the model's words).
    var pendingImpact: PlanImpact?
    @ObservationIgnored private var pendingGoal = ""
    /// Where the plan is made: "device" (Apple's model on this Mac), "ollama" (a model in Ollama on this
    /// Mac), or a provider's slug. Settings from before there were several providers are carried over.
    var source = UserDefaults.standard.string(forKey: "assistant.source") ?? (UserDefaults.standard.bool(forKey: "assistant.cloud") ? "openrouter" : "device")
    /// The model chosen at each source. No id is built in: they are picked from the source's own list.
    var chosen: [String: String] = (UserDefaults.standard.dictionary(forKey: "assistant.models") as? [String: String])
        ?? (UserDefaults.standard.string(forKey: "assistant.model").map { ["openrouter": $0] } ?? [:])
    /// What the selected source offers, read from its list (settings only).
    var choices: [ModelChoice] = []
    var listNote: String?
    /// Ollama on this Mac: its version when it is running, and the installed models that can call tools.
    var ollamaVersion: String?
    var ollamaModels: [String] = []
    /// False until Ollama has been asked what it has: nothing is said about its models before that.
    var ollamaAsked = false
    /// The one local model that has been through Jämmer's own evaluation (docs/ASSISTANT.md).
    static let evaluatedLocally = ["qwen3:8b"]

    var provider: TextProvider? { TextProvider.offered().first { $0.id == source } }
    var model: String { chosen[source] ?? "" }
    var sourceName: String { source == "device" ? L10n.text("assistant.source.device") : source == "ollama" ? "Ollama" : provider?.name ?? L10n.text("assistant.source.device") }
    var summary: String { source == "device" || model.isEmpty ? sourceName : "\(sourceName): \(model)" }

    @ObservationIgnored private var history: [(user: String, reply: String)] = []
    @ObservationIgnored private var siblings: [Sibling] = []
    @ObservationIgnored private var scanned: Date?
    /// The actions offered for the current request (own, plus siblings it names).
    @ObservationIgnored private(set) var actions: [AssistantAction] = AssistantCatalog.actions

    init(session: EditorSession) { self.session = session }

    /// Glimmer and Flimmer, looked up at most once a minute (SIBLINGS.md §1). Their tools are
    /// offered only when the request names them, so the on-device model's context stays small.
    private func actions(for goal: String) async -> [AssistantAction] {
        if scanned.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
            siblings = await SiblingDirectory.discover()
            scanned = Date()
        }
        let lower = goal.lowercased()
        let named = siblings.filter { lower.contains($0.slug) || lower.contains($0.name.lowercased()) }
        return AssistantCatalog.actions + named.flatMap(\.actions)
    }

    var planner: any AssistantPlanner {
        #if DEBUG
        // `-assistantScript <file>`: answers from a file instead of a model, so that what the panel does with a
        // plan (a step that is a job, a sentence held back, a step left out) can be looked at without waiting
        // for a model to happen to say it. The file is JSON: {"<request>": {"reply": "…", "steps": [{"op": "…", "args": {…}}]}}.
        if let path = UserDefaults.standard.string(forKey: "assistantScript"), let data = FileManager.default.contents(atPath: path),
           let script = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return ScriptedPlanner(script: script) }
        #endif
        if source == "ollama", !model.isEmpty { return OllamaPlanner(model: model) }
        if let provider, !model.isEmpty {
            let account = provider.id
            // Grunden: the least reasoning the model takes (left out, it means the most).
            let effort = provider.id == "grunden" ? (choices.first { $0.id == model }?.reasoningLevels.first ?? "low") : nil
            return CloudPlanner(provider: provider, model: model, key: { Keychain.get(account) }, reasoningEffort: effort)
        }
        return OnDevicePlanner()
    }

    func saveSettings() {
        UserDefaults.standard.set(source, forKey: "assistant.source")
        UserDefaults.standard.set(chosen, forKey: "assistant.models")
    }

    /// For the settings: is Ollama there, and what does the selected source offer?
    func refreshSources() async {
        ollamaVersion = await Ollama.version()
        if ollamaVersion != nil {
            var withTools: [String] = []
            for name in await Ollama.models() where await Ollama.supportsTools(name) { withTools.append(name) }
            ollamaModels = withTools
        } else {
            ollamaModels = []
            if source == "ollama" { source = "device" }
        }
        ollamaAsked = true
        await loadChoices()
    }

    func loadChoices() async {
        choices = []
        listNote = nil
        guard let provider else { return }
        do {
            choices = try await ModelCatalog.list(provider, key: Keychain.get(provider.id))
            if choices.isEmpty { listNote = L10n.text("assistant.list.none", provider.name) }
        } catch {
            // The provider's own words: a wrong key or a list that needs one is said, not hidden.
            listNote = Keychain.get(provider.id) == nil ? L10n.text("assistant.list.needsKey", provider.name) : L10n.error(error)
        }
    }

    func send() {
        let goal = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty, !busy else { return }
        // A plan waiting for a yes isn't replaced without a word.
        if pending != nil { cancelPending() }
        input = ""
        messages.append(Message(role: .user, text: goal))
        replyLanguage = ReplyGuard.language(of: goal)
        busy = true
        changedSomething = false
        paidRequestOut = nil
        work = Task {
            defer { busy = false; phase = nil; work = nil; planJobs = []; paidRequestOut = nil }
            // A source other than the Mac's own model needs a model chosen there: without one the
            // request is not quietly answered by another model than the one the settings name.
            if source != "device", model.isEmpty {
                messages.append(Message(role: .note, text: L10n.reply("assistant.reply.chooseModel.gear", replyLanguage, sourceName)))
                return
            }
            let p = planner
            // A paid model: the price first, and only on a yes.
            if p.paid {
                guard await confirmPaid(goal) else { messages.append(Message(role: .note, text: L10n.reply("assistant.reply.notSent", replyLanguage))); return }
            }
            do {
                phase = L10n.text("assistant.thinking", sourceName)
                actions = await actions(for: goal)
                let context = AssistantContext(project: session.project, selection: session.selection, playhead: session.playhead)
                if p.paid { paidRequestOut = sourceName }
                // `answer`, not `plan`: the model's sentence is checked before it is shown (ReplyGuard). A
                // measurement is written by Jämmer from its result, never by the model.
                let plan = try await p.answer(goal: goal, context: context, history: history, actions: actions)
                paidRequestOut = nil
                try Task.checkCancellation()
                history.append((goal, plan.reply))
                var text = plan.reply
                if let cost = plan.cost {
                    let amount = L10n.number(cost, 4)
                    text += text.isEmpty ? L10n.reply("assistant.reply.cost", replyLanguage, amount) : " " + L10n.reply("assistant.reply.costAfter", replyLanguage, amount)
                }
                if !text.isEmpty { messages.append(Message(role: .assistant, text: text)) }
                if !plan.heldBack.isEmpty { messages.append(Message(role: .note, text: ReplyGuard.heldBackNote(ReplyGuard.language(of: goal), count: plan.heldBack.count))) }
                if !plan.dropped.isEmpty { messages.append(Message(role: .note, text: L10n.reply("assistant.reply.leftOut", replyLanguage, plan.dropped.joined(separator: "; ")))) }
                guard !plan.steps.isEmpty else { return }
                for line in plan.shownFirst { messages.append(Message(role: .note, text: line)) }
                let unasked = plan.unasked(goal: goal, actions: actions)
                if !unasked.isEmpty {
                    messages.append(Message(role: .note, text: unasked.count == 1 ? L10n.reply("assistant.reply.unasked.one", replyLanguage) : L10n.reply("assistant.reply.unasked.many", replyLanguage)))
                }
                if plan.needsConfirmation(goal: goal, actions: actions) {
                    let state = EditState(project: session.project, selection: session.selection, playhead: session.playhead,
                                          pool: session.pool, media: FileManager.default.temporaryDirectory.appending(path: "jammer-impact"))
                    pendingImpact = PlanImpact.compute(plan, goal: goal, state: state)
                    pendingGoal = goal
                    pending = plan
                } else {
                    await run(plan)
                }
            } catch is CancellationError {
                // Stopped: stop() has said so.
            } catch let e as URLError where e.code == .cancelled {
                // Stopped while the request was out.
            } catch {
                messages.append(Message(role: .note, text: L10n.replyError(error, replyLanguage)))
            }
        }
    }

    func describe(_ s: PlannedStep) -> String {
        if let a = actions.first(where: { $0.name == s.op }), case .sibling(let slug, _, _) = a.kind {
            let app = siblings.first { $0.slug == slug }?.name ?? slug
            return "\(app): \(s.op)" + (s.params.isEmpty ? "" : " (" + s.params.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.display)" }.joined(separator: ", ") + ")")
        }
        let title = L10n.operation(s.op)
        let params = s.params.sorted { $0.key < $1.key }.compactMap { k, v -> String? in
            if k == "tracks", let ids = v.strings {
                return "tracks " + ids.compactMap { id in session.project.tracks.first { $0.id.uuidString == id }?.name }.joined(separator: ", ")
            }
            return "\(k) \(v.display)"
        }
        return params.isEmpty ? title : "\(title): \(params.joined(separator: ", "))"
    }

    func confirmPending() {
        guard let plan = pending else { return }
        pending = nil
        pendingImpact = nil
        busy = true
        changedSomething = false
        work = Task { defer { busy = false; phase = nil; work = nil; planJobs = [] }; await run(plan) }
    }

    func cancelPending() {
        pending = nil
        pendingImpact = nil
        messages.append(Message(role: .note, text: L10n.reply("assistant.reply.canceled", replyLanguage)))
    }

    /// Steps (and macros) run together as one undo step; jobs and measurements run in
    /// between, in order.
    func run(_ plan: AssistantPlan) async {
        phase = L10n.text("assistant.running")
        var batch: [PlannedStep] = []
        func flush() async -> Bool {
            guard !batch.isEmpty else { return true }
            defer { batch = [] }
            // Filler words need words: transcribe first if there are none.
            if batch.contains(where: { $0.op == "remove_fillers" }), session.project.transcripts.isEmpty {
                messages.append(Message(role: .note, text: L10n.reply("assistant.reply.transcribingFirst", replyLanguage)))
                guard await runJob(JobRegistry.shared.startTranscription(session, locale: transcriptLocale, replace: false)) else { return false }
            }
            do {
                let state = EditState(project: session.project, selection: session.selection, playhead: session.playhead,
                                      pool: session.pool, media: MediaStore.folder)
                let steps = try MacroExpander.expand(batch, state: state)
                guard !steps.isEmpty else { messages.append(Message(role: .note, text: L10n.reply("assistant.reply.nothingToChange", replyLanguage))); return true }
                let results = await session.run(steps, action: L10n.text("assistant.title"))
                if results.contains(where: { $0.reason == "stopped" }) { return false }
                if let f = results.first(where: { $0.status == .failed }) {
                    messages.append(Message(role: .note, text: L10n.reply("assistant.reply.stepFailed", replyLanguage, L10n.operation(f.op), f.keyed.map(L10n.message) ?? f.error ?? "")))
                    return false
                }
                changedSomething = true
                messages.append(Message(role: .note, text: L10n.replyCount("assistant.reply.done", replyLanguage, steps.count)))
                for res in results where res.op == "loudness_preset" {
                    if res.info["limitedByPeak"] == 1, let after = res.info["integratedAfter"], let target = res.info["target"] {
                        messages.append(Message(role: .assistant, text: L10n.reply("assistant.reply.peakHeld", replyLanguage, L10n.number(after, 1), L10n.number(target, 0))))
                    } else if let after = res.info["integratedAfter"] {
                        messages.append(Message(role: .assistant, text: L10n.reply("assistant.reply.nowAt", replyLanguage, L10n.number(after, 1))))
                    }
                }
                return true
            } catch {
                messages.append(Message(role: .note, text: L10n.replyError(error, replyLanguage)))
                return false
            }
        }
        for s in plan.steps {
            if Task.isCancelled { return }
            if let a = actions.first(where: { $0.name == s.op }), case .sibling(let slug, _, _) = a.kind,
               let sib = siblings.first(where: { $0.slug == slug }) {
                guard await flush() else { return }
                messages.append(Message(role: .note, text: await SiblingDirectory.run(sib, a, s.params)))
                continue
            }
            switch s.op {
            case "transcribe", "restore", "measure_loudness", "analyze_restoration", "freeze", "unfreeze":
                guard await flush() else { return }
                guard await runEndpoint(s) else { return }
            default:
                batch.append(s)
            }
        }
        _ = await flush()
    }

    var transcriptLocale: Locale {
        Locale(identifier: session.project.transcripts.first?.language ?? UserDefaults.standard.string(forKey: "transcript.language") ?? "sv-SE")
    }

    private func runEndpoint(_ s: PlannedStep) async -> Bool {
        switch s.op {
        case "transcribe":
            let lang = s.params["language"]?.string ?? transcriptLocale.identifier(.bcp47)
            return await runJob(JobRegistry.shared.startTranscription(session, locale: Locale(identifier: lang), replace: s.params["replace"] == .bool(true)))
        case "restore":
            do {
                let req = try RestoreRequest.parse(s.params.mapValues(\.any))
                let range: Range<Frame>? = req.start.flatMap { a in req.end.map { session.project.frames(a)..<session.project.frames($0) } } ?? session.selection
                let title = ["dehum": L10n.text("restore.kind.dehum"), "declip": L10n.text("restore.kind.declip"), "declick": L10n.text("restore.kind.declick"), "denoise": L10n.text("restore.kind.denoise"), "dereverb": L10n.text("restore.kind.dereverb")][req.settings.kind.rawValue] ?? L10n.text("restore.title")
                return await runJob(JobRegistry.shared.startRestoration(session, settings: req.settings, range: range, tracks: req.tracks.map(Set.init), action: title))
            } catch {
                messages.append(Message(role: .note, text: (error as? AgentAPI.APIError)?.message ?? error.localizedDescription))
                return false
            }
        case "freeze", "unfreeze":
            // The same as the mixer's Frozen box: freezing is a job, thawing is at once, each one undo step.
            guard let id = UUID(uuidString: s.params["strip"]?.string ?? ""), let strip = session.project.strip(id), id != Master.id else {
                messages.append(Message(role: .note, text: L10n.reply("assistant.reply.whichStrip", replyLanguage)))
                return false
            }
            if s.op == "freeze" {
                guard session.project.frozen(id) == nil else { messages.append(Message(role: .note, text: L10n.reply("error.freeze.alreadyFrozen", replyLanguage, strip.name))); return true }
                return await runJob(JobRegistry.shared.startFreeze(session, strip: id))
            }
            do { try session.unfreeze(id); return true }
            catch { messages.append(Message(role: .note, text: L10n.replyError(error, replyLanguage))); return false }
        case "measure_loudness":
            let r = await session.analyze(session.selection)
            func f(_ v: Double?, _ u: String) -> String { v.map { L10n.number($0, 1) + " " + u } ?? "—" }
            messages.append(Message(role: .assistant, text: L10n.reply("assistant.reply.loudness", replyLanguage, f(r.integrated, "LUFS"), f(r.range, "LU"), f(r.truePeak, "dBTP"))))
            return true
        case "analyze_restoration":
            let p = session.project, pool = session.pool, range = session.selection ?? 0..<p.length
            let a = await Task.detached { Restoration.analyze(p, range: range, pool: pool) }.value
            let hum = a.hum.map { L10n.reply("assistant.reply.hum", replyLanguage, L10n.number($0.frequency, 1)) } ?? L10n.reply("assistant.reply.noHum", replyLanguage)
            let found = L10n.reply("assistant.reply.found", replyLanguage, L10n.replyCount("assistant.reply.clipped", replyLanguage, a.clippedRuns), L10n.replyCount("assistant.reply.clicks", replyLanguage, a.clicks))
            messages.append(Message(role: .assistant, text: hum + " " + found))
            return true
        default:
            return true
        }
    }

    private func runJob(_ job: Job) async -> Bool {
        planJobs.insert(job.id)
        defer { planJobs.remove(job.id) }
        while let j = JobRegistry.shared.job(job.id), !j.isFinished {
            try? await Task.sleep(for: .milliseconds(250))
        }
        let done = JobRegistry.shared.job(job.id)
        if done?.status == .done { changedSomething = true; return true }
        // Stopped (from the plan's Stop or the job's own): said once, by whoever stopped it.
        if done?.status == .cancelled { return false }
        messages.append(Message(role: .note, text: done?.errorKeyed.map { L10n.replyError(L10n.KeyedOnly(keyed: $0), replyLanguage) } ?? done?.error?.message ?? L10n.reply("assistant.reply.jobUnfinished", replyLanguage, job.kind)))
        return false
    }

    /// Asks before a paid request, with the price from the provider's own list when it gives one. What
    /// can't work is said here, before anything is sent: no key, no model chosen, a model without tools.
    private func confirmPaid(_ goal: String) async -> Bool {
        guard let provider else { return false }
        guard Keychain.get(provider.id) != nil else {
            messages.append(Message(role: .note, text: L10n.replyError(AssistantError.missingKey(provider.name), replyLanguage)))
            return false
        }
        guard !model.isEmpty else {
            messages.append(Message(role: .note, text: L10n.reply("assistant.reply.chooseModel", replyLanguage, provider.name)))
            return false
        }
        if choices.isEmpty { await loadChoices() }
        let choice = choices.first { $0.id == model }
        if choice?.tools == false {
            messages.append(Message(role: .note, text: L10n.reply("assistant.reply.noTools", replyLanguage, model, provider.name)))
            return false
        }
        // Text requests (SIBLINGS, "Betalt kräver alltid en fråga", the exception Anders made on 2026-11-25): the
        // notice at first use, with a tick per service; once a service is ticked, its text requests go without a
        // question. Taken back in Settings › Paid Services. (Plans with paid steps can't come from here: the
        // assistant's catalogue has no paid operation.)
        let service = "text.\(provider.id)"
        if UnknownPrice.isAccepted(service) { return true }
        let price = choice?.estimate ?? L10n.text("assistant.paid.rate", provider.name)
        let alert = NSAlert()
        alert.messageText = L10n.text("assistant.paid.title", model, provider.name)
        alert.informativeText = L10n.text("assistant.paid.text", price, provider.name, provider.note)
        alert.addButton(withTitle: L10n.text("button.send"))
        alert.addButton(withTitle: L10n.text("button.cancel"))
        alert.returnNeverPays()
        // No price on the provider's list for this model: Send stays grey until that is ticked as understood.
        // (A price from the provider's own list counts as known. Asked once per provider, not per model.)
        let unknown = UnknownPriceBox(service: service, name: provider.name)
        // A known price: the tick is offered, not required (the request may go this once without it).
        let dontAsk = NSButton(checkboxWithTitle: L10n.text("assistant.paid.dontAsk", provider.name), target: nil, action: nil)
        dontAsk.setAccessibilityIdentifier("assistant.paid.dontAsk")
        dontAsk.sizeToFit()
        if choice?.estimate == nil {
            UnknownPriceBox.place([unknown.view], in: alert)
            unknown.gate(alert.buttons[0])
        } else {
            UnknownPriceBox.place([dontAsk], in: alert)
        }
        let yes: Bool
        if let window = session.window { yes = await alert.beginSheetModal(for: window) == .alertFirstButtonReturn } else { yes = alert.runModal() == .alertFirstButtonReturn }
        if yes, choice?.estimate == nil { unknown.sent() }
        if yes, choice?.estimate != nil, dontAsk.state == .on { UnknownPrice.accept(service, name: provider.name) }
        return yes
    }
}

extension JSONValue {
    var display: String {
        switch self {
        case .number(let d): d == d.rounded() ? String(Int(d)) : d.formatted(.number.grouping(.never).locale(Locale.current))
        case .string(let s): s
        case .bool(let b): b ? "yes" : "no"
        case .array(let a): a.map(\.display).joined(separator: ", ")
        case .null: "–"
        }
    }
}

struct AssistantView: View {
    @Bindable var model: AssistantModel
    @State private var showSettings = false
    @State private var key = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.text("assistant.title")).font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(model.summary).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                Button { showSettings.toggle() } label: { Label(L10n.text("assistant.settings.ax"), systemImage: "gearshape").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless)
                    .help(L10n.text("assistant.model"))
                    .popover(isPresented: $showSettings) { settings.padding(14).frame(width: 320) }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.messages.isEmpty {
                            Text(L10n.text("assistant.intro"))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(model.messages) { m in
                            // Who said it is on the group, not on the selectable text (see AgentSplashView).
                            Group {
                                Text(m.text)
                                    .font(m.role == .note ? .caption : .callout)
                                    .foregroundStyle(m.role == .note ? Color.secondary : m.role == .user ? Color.white : Theme.neonColor)
                                    .frame(maxWidth: .infinity, alignment: m.role == .user ? .trailing : .leading)
                                    .textSelection(.enabled)
                            }
                            // One string, "who: text": on macOS 27 a text element shows its value and loses its label.
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text(verbatim: (m.role == .user ? L10n.text("assistant.ax.you") : m.role == .assistant ? L10n.text("assistant.title") : L10n.text("assistant.ax.note")) + ": " + m.text))
                            .id(m.id)
                        }
                        if let plan = model.pending {
                            let impact = model.pendingImpact
                            let alarming = impact?.isAlarming ?? false
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L10n.text("assistant.plan")).font(.caption.weight(.semibold))
                                ForEach(Array(plan.steps.enumerated()), id: \.offset) { i, s in
                                    Text("\(i + 1). \(model.describe(s))").font(.caption)
                                }
                                if let impact, !impact.lines.isEmpty {
                                    Text(L10n.text("assistant.plan.does")).font(.caption.weight(.semibold)).padding(.top, 2)
                                    ForEach(Array(impact.lines.enumerated()), id: \.offset) { _, line in
                                        Text("• " + line).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                ForEach(Array((impact?.warnings ?? []).enumerated()), id: \.offset) { _, w in
                                    StateLine(kind: .warning, text: w, font: .caption.weight(.semibold))
                                }
                                HStack {
                                    if alarming {
                                        Button(L10n.text("button.cancel")) { model.cancelPending() }.keyboardShortcut(.defaultAction)
                                        Button(L10n.text("assistant.runAnyway")) { model.confirmPending() }
                                    } else {
                                        Button(L10n.text("batch.run")) { model.confirmPending() }.keyboardShortcut(.defaultAction)
                                        Button(L10n.text("button.cancel")) { model.cancelPending() }.keyboardShortcut(.cancelAction)
                                    }
                                }
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(alarming ? StateKind.warning.color : .clear, lineWidth: 1.5))
                        }
                        if model.busy {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                if let phase = model.phase { Text(phase).font(.caption).foregroundStyle(.secondary) }
                                Button(L10n.text("job.stop")) { model.stop() }
                                    .keyboardShortcut(.cancelAction)
                                    .controlSize(.small)
                                    .help(L10n.text("assistant.stop.help"))
                            }
                        }
                    }
                    .padding(12)
                }
                .onChange(of: model.messages.count) { if let last = model.messages.last { proxy.scrollTo(last.id) } }
            }
            HStack {
                TextField(L10n.text("assistant.placeholder"), text: $model.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .accessibilityLabel(L10n.text("assistant.field.ax"))
                    .lineLimit(1...4)
                    .focused($focused)
                    .onChange(of: model.focusRequest) { focused = true }
                    .onChange(of: focused) { model.fieldFocused = focused }
                    .onSubmit { model.send() }
                Button { model.send() } label: { Label(L10n.text("button.send"), systemImage: "arrow.up.circle.fill").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless)
                    .disabled(model.input.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
            }
            .padding(10)
            .background(Color.white.opacity(0.04))
        }
        .background(Theme.inkColor)
        .onAppear { focused = true }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(L10n.text("assistant.model"), selection: $model.source) {
                Text(L10n.text("assistant.source.device.long")).tag("device")
                if model.ollamaVersion != nil { Text(L10n.text("assistant.source.ollama")).tag("ollama") }
                ForEach(TextProvider.offered()) { p in
                    Text(L10n.text("assistant.source.paid", p.name)).tag(p.id)
                }
            }
            .pickerStyle(.radioGroup)
            if model.source == "ollama" {
                if !model.ollamaAsked {
                    Text(L10n.text("assistant.ollama.asking")).font(.caption).foregroundStyle(.secondary)
                } else if model.ollamaModels.isEmpty {
                    Text(L10n.text("assistant.ollama.none"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Picker(L10n.text("assistant.ollama.model"), selection: Binding(get: { model.model }, set: { model.chosen["ollama"] = $0 })) {
                        Text(L10n.text("choice.choose")).tag("")
                        ForEach(model.ollamaModels, id: \.self) { name in
                            Text(AssistantModel.evaluatedLocally.contains(name) ? name : L10n.text("assistant.ollama.notEvaluated", name)).tag(name)
                        }
                    }
                }
                Text(L10n.text("assistant.ollama.text"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if let p = model.provider {
                Picker(L10n.text("assistant.provider.model", p.name), selection: Binding(get: { model.model }, set: { model.chosen[p.id] = $0 })) {
                    Text(L10n.text("choice.choose")).tag("")
                    // A model saved earlier that the list no longer has is still shown, so it isn't silently replaced.
                    if !model.model.isEmpty, !model.choices.contains(where: { $0.id == model.model }) { Text(model.model).tag(model.model) }
                    ForEach(model.choices) { c in
                        Text(c.tools == false ? L10n.text("assistant.model.noTools", c.id) : c.id).tag(c.id)
                    }
                }
                if let note = model.listNote { StateLine(kind: .error, text: note) }
                SecureField(Keychain.get(p.id) == nil ? L10n.text("assistant.key", p.name) : L10n.text("assistant.key.saved"), text: $key)
                Text(L10n.text("assistant.key.text", p.note))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button(L10n.text("button.done")) {
                if !key.isEmpty, let p = model.provider { Keychain.set(p.id, key); key = "" }
                model.saveSettings()
                showSettings = false
            }
        }
        .task { await model.refreshSources() }
        .onChange(of: model.source) {
            key = ""
            model.saveSettings()
            Task { await model.loadChoices() }
        }
    }
}

#if DEBUG
/// A model's answers read from a file (`-assistantScript`), put through the same typing, repairs and
/// checks as a real model's. Debug builds only.
struct ScriptedPlanner: AssistantPlanner, @unchecked Sendable {
    var id: String { "scripted" }
    var paid: Bool { false }
    let script: [String: Any]

    func plan(goal: String, context: AssistantContext, history: [(user: String, reply: String)], actions: [AssistantAction]) async throws -> AssistantPlan {
        if let reply = PlanParser.guardrail(goal) { return AssistantPlan(reply: reply, steps: []) }
        guard let entry = script[goal] as? [String: Any] else { return AssistantPlan(reply: "The script has no answer for that.", steps: []) }
        var dropped: [String] = []
        let steps = (entry["steps"] as? [[String: Any]] ?? []).compactMap { s -> PlannedStep? in
            let op = s["op"] as? String ?? ""
            var params: [String: JSONValue] = [:]
            for (k, v) in s["args"] as? [String: Any] ?? [:] { if let j = JSONValue(v) { params[k] = j } }
            guard let step = PlanParser.typed(op: op, json: params, why: "", actions: actions, context: context) else { dropped.append(op); return nil }
            return step
        }
        let plan = AssistantPlan(reply: entry["reply"] as? String ?? "", steps: steps, dropped: dropped)
        return PlanParser.augment(goal: goal, plan: PlanParser.validate(plan, actions: actions))
    }
}
#endif
