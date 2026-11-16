import AppKit
import JammerAgent
import JammerAssistant
import JammerCore
import Security
import SwiftUI

/// The user's own keys, in the Keychain only.
enum Keychain {
    /// The app's bundle id, so debug builds keep their keys apart (com.brattoo.jammer.debug).
    static let service = Bundle.main.bundleIdentifier ?? "com.brattoo.jammer"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ account: String, _ value: String?) {
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
    var input = ""
    var busy = false
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
    static var showHidden: Bool { UserDefaults.standard.bool(forKey: "assistant.showHiddenProviders") }

    var provider: TextProvider? { TextProvider.offered(showHidden: Self.showHidden).first { $0.id == source } }
    var model: String { chosen[source] ?? "" }
    var sourceName: String { source == "device" ? "On this Mac" : source == "ollama" ? "Ollama" : provider?.name ?? "On this Mac" }
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
            if choices.isEmpty { listNote = "\(provider.name)'s list has no text models." }
        } catch {
            // The provider's own words: a wrong key or a list that needs one is said, not hidden.
            listNote = Keychain.get(provider.id) == nil ? "Add your key to see \(provider.name)'s models." : error.localizedDescription
        }
    }

    func send() {
        let goal = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty, !busy else { return }
        input = ""
        messages.append(Message(role: .user, text: goal))
        busy = true
        Task {
            defer { busy = false }
            // A source other than the Mac's own model needs a model chosen there: without one the
            // request is not quietly answered by another model than the one the settings name.
            if source != "device", model.isEmpty {
                messages.append(Message(role: .note, text: "Choose one of \(sourceName)'s models in the assistant's settings (the gear) first. Nothing was sent."))
                return
            }
            let p = planner
            // A paid model: the price first, and only on a yes.
            if p.paid {
                guard await confirmPaid(goal) else { messages.append(Message(role: .note, text: "Not sent.")); return }
            }
            do {
                actions = await actions(for: goal)
                let context = AssistantContext(project: session.project, selection: session.selection, playhead: session.playhead)
                // `answer`, not `plan`: the model's sentence is checked before it is shown (ReplyGuard). A
                // measurement is written by Jämmer from its result, never by the model.
                let plan = try await p.answer(goal: goal, context: context, history: history, actions: actions)
                history.append((goal, plan.reply))
                var text = plan.reply
                if let cost = plan.cost { text += String(format: text.isEmpty ? "Cost $%.4f." : " (cost $%.4f)", cost) }
                if !text.isEmpty { messages.append(Message(role: .assistant, text: text)) }
                if !plan.heldBack.isEmpty { messages.append(Message(role: .note, text: ReplyGuard.heldBackNote(ReplyGuard.language(of: goal), count: plan.heldBack.count))) }
                if !plan.dropped.isEmpty { messages.append(Message(role: .note, text: "Left out: " + plan.dropped.joined(separator: "; "))) }
                guard !plan.steps.isEmpty else { return }
                let unasked = plan.unasked(goal: goal, actions: actions)
                if !unasked.isEmpty {
                    messages.append(Message(role: .note, text: "You didn't ask for \(unasked.count == 1 ? "this change" : "these changes") in so many words, so nothing has been done. Run it only if it is what you meant."))
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
            } catch {
                messages.append(Message(role: .note, text: error.localizedDescription))
            }
        }
    }

    func describe(_ s: PlannedStep) -> String {
        if let a = actions.first(where: { $0.name == s.op }), case .sibling(let slug, _, _) = a.kind {
            let app = siblings.first { $0.slug == slug }?.name ?? slug
            return "\(app): \(s.op)" + (s.params.isEmpty ? "" : " (" + s.params.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.display)" }.joined(separator: ", ") + ")")
        }
        let title = Operations.named(s.op)?.title ?? Operations.endpoints.first { $0.name == s.op }?.title
            ?? s.op.replacingOccurrences(of: "_", with: " ").capitalized
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
        Task { defer { busy = false }; await run(plan) }
    }

    func cancelPending() {
        pending = nil
        pendingImpact = nil
        messages.append(Message(role: .note, text: "Cancelled; nothing changed."))
    }

    /// Steps (and macros) run together as one undo step; jobs and measurements run in
    /// between, in order.
    func run(_ plan: AssistantPlan) async {
        var batch: [PlannedStep] = []
        func flush() async -> Bool {
            guard !batch.isEmpty else { return true }
            defer { batch = [] }
            // Filler words need words: transcribe first if there are none.
            if batch.contains(where: { $0.op == "remove_fillers" }), session.project.transcripts.isEmpty {
                messages.append(Message(role: .note, text: "Transcribing first…"))
                guard await runJob(JobRegistry.shared.startTranscription(session, locale: transcriptLocale, replace: false)) else { return false }
            }
            do {
                let state = EditState(project: session.project, selection: session.selection, playhead: session.playhead,
                                      pool: session.pool, media: MediaStore.folder)
                let steps = try MacroExpander.expand(batch, state: state)
                guard !steps.isEmpty else { messages.append(Message(role: .note, text: "Nothing to change.")); return true }
                let results = await session.run(steps, action: "Assistant")
                if let f = results.first(where: { $0.status == .failed }) {
                    messages.append(Message(role: .note, text: "\(f.op) failed: \(f.error ?? ""). Nothing was changed."))
                    return false
                }
                messages.append(Message(role: .note, text: "Done (\(steps.count) step\(steps.count == 1 ? "" : "s"), one undo step)."))
                for res in results where res.op == "loudness_preset" {
                    if res.info["limitedByPeak"] == 1, let after = res.info["integratedAfter"], let target = res.info["target"] {
                        messages.append(Message(role: .assistant, text: String(format: "Reached %.1f instead of %.0f LUFS: the peaks held it back. Ask for the preset with the limiter to reach it.", after, target)))
                    } else if let after = res.info["integratedAfter"] {
                        messages.append(Message(role: .assistant, text: String(format: "Now at %.1f LUFS.", after)))
                    }
                }
                return true
            } catch {
                messages.append(Message(role: .note, text: error.localizedDescription))
                return false
            }
        }
        for s in plan.steps {
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
                let title = ["dehum": "Remove Hum", "declip": "Repair Clipping", "declick": "Remove Clicks", "denoise": "Reduce Noise", "dereverb": "Reduce Reverb"][req.settings.kind.rawValue] ?? "Restore"
                return await runJob(JobRegistry.shared.startRestoration(session, settings: req.settings, range: range, tracks: req.tracks.map(Set.init), action: title))
            } catch {
                messages.append(Message(role: .note, text: (error as? AgentAPI.APIError)?.message ?? error.localizedDescription))
                return false
            }
        case "freeze", "unfreeze":
            // The same as the mixer's Frozen box: freezing is a job, thawing is at once, each one undo step.
            guard let id = UUID(uuidString: s.params["strip"]?.string ?? ""), let strip = session.project.strip(id), id != Master.id else {
                messages.append(Message(role: .note, text: "I couldn't tell which track or bus you meant."))
                return false
            }
            if s.op == "freeze" {
                guard session.project.frozen(id) == nil else { messages.append(Message(role: .note, text: "\(strip.name) is frozen already.")); return true }
                return await runJob(JobRegistry.shared.startFreeze(session, strip: id))
            }
            do { session.commit(try session.project.unfreezing(id), action: "Unfreeze \(strip.name)"); return true }
            catch { messages.append(Message(role: .note, text: error.localizedDescription)); return false }
        case "measure_loudness":
            let r = await session.analyze(session.selection)
            func f(_ v: Double?, _ u: String) -> String { v.map { String(format: "%.1f %@", $0, u) } ?? "—" }
            messages.append(Message(role: .assistant, text: "Loudness \(f(r.integrated, "LUFS")), range \(f(r.range, "LU")), true peak \(f(r.truePeak, "dBTP"))."))
            return true
        case "analyze_restoration":
            let p = session.project, pool = session.pool, range = session.selection ?? 0..<p.length
            let a = await Task.detached { Restoration.analyze(p, range: range, pool: pool) }.value
            messages.append(Message(role: .assistant, text: (a.hum.map { String(format: "Hum at %.1f Hz. ", $0.frequency) } ?? "No hum. ")
                                    + "\(a.clippedRuns) clipped stretches, \(a.clicks) clicks."))
            return true
        default:
            return true
        }
    }

    private func runJob(_ job: Job) async -> Bool {
        while let j = JobRegistry.shared.job(job.id), !j.isFinished {
            try? await Task.sleep(for: .milliseconds(250))
        }
        let done = JobRegistry.shared.job(job.id)
        if done?.status == .done { return true }
        messages.append(Message(role: .note, text: done?.error?.message ?? "The \(job.kind) job didn't finish."))
        return false
    }

    /// Asks before a paid request, with the price from the provider's own list when it gives one. What
    /// can't work is said here, before anything is sent: no key, no model chosen, a model without tools.
    private func confirmPaid(_ goal: String) async -> Bool {
        guard let provider else { return false }
        guard Keychain.get(provider.id) != nil else {
            messages.append(Message(role: .note, text: AssistantError.missingKey(provider.name).localizedDescription))
            return false
        }
        guard !model.isEmpty else {
            messages.append(Message(role: .note, text: "Choose one of \(provider.name)'s models in the assistant's settings first."))
            return false
        }
        if choices.isEmpty { await loadChoices() }
        let choice = choices.first { $0.id == model }
        if choice?.tools == false {
            messages.append(Message(role: .note, text: "\(model) can't call tools, which the assistant needs. Choose another of \(provider.name)'s models."))
            return false
        }
        let price = choice?.estimate ?? "Your \(provider.name) account is charged at the model's rate."
        let alert = NSAlert()
        alert.messageText = "Send this to \(model) at \(provider.name)?"
        alert.informativeText = "\(price) The request and a short description of the document go to \(provider.name); the audio doesn't. \(provider.note)"
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        guard let window = session.window else { return alert.runModal() == .alertFirstButtonReturn }
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }
}

extension JSONValue {
    var display: String {
        switch self {
        case .number(let d): d == d.rounded() ? String(Int(d)) : String(format: "%g", d)
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
                Text("Assistant").font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(model.summary).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                Button { showSettings.toggle() } label: { Label("Assistant model", systemImage: "gearshape").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless)
                    .help("Model")
                    .popover(isPresented: $showSettings) { settings.padding(14).frame(width: 320) }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.messages.isEmpty {
                            Text("Ask in Swedish or English, for example \"ta bort alla ehm och tystnader längre än en sekund\" or \"normalize to −16 LUFS\". Plans that remove audio are shown before they run, and everything is one undo step.")
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
                            .accessibilityLabel(Text(verbatim: "\(m.role == .user ? "You" : m.role == .assistant ? "Assistant" : "Note"): \(m.text)"))
                            .id(m.id)
                        }
                        if let plan = model.pending {
                            let impact = model.pendingImpact
                            let alarming = impact?.isAlarming ?? false
                            VStack(alignment: .leading, spacing: 6) {
                                Text("The plan").font(.caption.weight(.semibold))
                                ForEach(Array(plan.steps.enumerated()), id: \.offset) { i, s in
                                    Text("\(i + 1). \(model.describe(s))").font(.caption)
                                }
                                if let impact, !impact.lines.isEmpty {
                                    Text("What it does").font(.caption.weight(.semibold)).padding(.top, 2)
                                    ForEach(Array(impact.lines.enumerated()), id: \.offset) { _, line in
                                        Text("• " + line).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                ForEach(Array((impact?.warnings ?? []).enumerated()), id: \.offset) { _, w in
                                    Label(w, systemImage: "exclamationmark.triangle.fill").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                                }
                                HStack {
                                    if alarming {
                                        Button("Cancel") { model.cancelPending() }.keyboardShortcut(.defaultAction)
                                        Button("Run anyway") { model.confirmPending() }
                                    } else {
                                        Button("Run") { model.confirmPending() }.keyboardShortcut(.defaultAction)
                                        Button("Cancel") { model.cancelPending() }
                                    }
                                }
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(alarming ? Color.orange : .clear, lineWidth: 1.5))
                        }
                        if model.busy { ProgressView().controlSize(.small) }
                    }
                    .padding(12)
                }
                .onChange(of: model.messages.count) { if let last = model.messages.last { proxy.scrollTo(last.id) } }
            }
            HStack {
                TextField("Ask the assistant…", text: $model.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Ask the assistant")
                    .lineLimit(1...4)
                    .focused($focused)
                    .onChange(of: model.focusRequest) { focused = true }
                    .onChange(of: focused) { model.fieldFocused = focused }
                    .onSubmit { model.send() }
                Button { model.send() } label: { Label("Send", systemImage: "arrow.up.circle.fill").labelStyle(.iconOnly) }
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
            Picker("Model", selection: $model.source) {
                Text("On this Mac (Apple, free, private)").tag("device")
                if model.ollamaVersion != nil { Text("Ollama on this Mac (free, private)").tag("ollama") }
                ForEach(TextProvider.offered(showHidden: AssistantModel.showHidden)) { p in
                    Text("\(p.name) (your key, paid)").tag(p.id)
                }
            }
            .pickerStyle(.radioGroup)
            if model.source == "ollama" {
                if !model.ollamaAsked {
                    Text("Asking Ollama what it has…").font(.caption).foregroundStyle(.secondary)
                } else if model.ollamaModels.isEmpty {
                    Text("None of the models installed in Ollama can call tools, which the assistant needs.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Picker("Ollama model", selection: Binding(get: { model.model }, set: { model.chosen["ollama"] = $0 })) {
                        Text("Choose…").tag("")
                        ForEach(model.ollamaModels, id: \.self) { name in
                            Text(AssistantModel.evaluatedLocally.contains(name) ? name : "\(name) (not evaluated with Jämmer)").tag(name)
                        }
                    }
                }
                Text("Slower than the on-device model, and the model takes about 6 GB of memory while it runs. Tried with qwen3:8b on one Mac. Jämmer doesn't download models; it uses the ones you have installed.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if let p = model.provider {
                Picker("\(p.name) model", selection: Binding(get: { model.model }, set: { model.chosen[p.id] = $0 })) {
                    Text("Choose…").tag("")
                    // A model saved earlier that the list no longer has is still shown, so it isn't silently replaced.
                    if !model.model.isEmpty, !model.choices.contains(where: { $0.id == model.model }) { Text(model.model).tag(model.model) }
                    ForEach(model.choices) { c in
                        Text(c.tools == false ? "\(c.id) (no tool calls: can't be used)" : c.id).tag(c.id)
                    }
                }
                if let note = model.listNote { Text(note).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                SecureField(Keychain.get(p.id) == nil ? "\(p.name) key" : "Key saved; type to replace", text: $key)
                Text("\(p.note) The key stays in your Keychain. Every request asks first and shows the price.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button("Done") {
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
