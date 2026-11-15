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
    var useCloud = UserDefaults.standard.bool(forKey: "assistant.cloud")
    var cloudModel = UserDefaults.standard.string(forKey: "assistant.model") ?? "anthropic/claude-sonnet-4.5"
    var cloudEndpoint = UserDefaults.standard.string(forKey: "assistant.endpoint") ?? "https://openrouter.ai/api/v1"
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
        if useCloud {
            return OpenRouterPlanner(endpoint: URL(string: cloudEndpoint) ?? URL(string: "https://openrouter.ai/api/v1")!,
                                     model: cloudModel, key: { Keychain.get("openrouter") })
        }
        return OnDevicePlanner()
    }

    func saveSettings() {
        UserDefaults.standard.set(useCloud, forKey: "assistant.cloud")
        UserDefaults.standard.set(cloudModel, forKey: "assistant.model")
        UserDefaults.standard.set(cloudEndpoint, forKey: "assistant.endpoint")
    }

    func send() {
        let goal = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty, !busy else { return }
        input = ""
        messages.append(Message(role: .user, text: goal))
        busy = true
        Task {
            defer { busy = false }
            let p = planner
            // A paid model: the price first, and only on a yes.
            if p.paid {
                guard await confirmPaid(goal) else { messages.append(Message(role: .note, text: "Not sent.")); return }
            }
            do {
                actions = await actions(for: goal)
                let context = AssistantContext(project: session.project, selection: session.selection, playhead: session.playhead)
                let plan = try await p.plan(goal: goal, context: context, history: history, actions: actions)
                history.append((goal, plan.reply))
                var text = plan.reply
                if let cost = plan.cost { text += String(format: " (cost $%.4f)", cost) }
                messages.append(Message(role: .assistant, text: text.isEmpty ? "OK." : text))
                if !plan.dropped.isEmpty { messages.append(Message(role: .note, text: "Left out: " + plan.dropped.joined(separator: "; "))) }
                guard !plan.steps.isEmpty else { return }
                if plan.isDestructive(actions) {
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
                        messages.append(Message(role: .assistant, text: String(format: "Reached %.1f instead of %.0f LUFS: the peaks held it back. A limiter comes later.", after, target)))
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
            case "transcribe", "restore", "measure_loudness", "analyze_restoration":
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

    /// Asks before a paid request, with the price per million tokens when OpenRouter reports it.
    private func confirmPaid(_ goal: String) async -> Bool {
        guard Keychain.get("openrouter") != nil else {
            messages.append(Message(role: .note, text: AssistantError.noKey.localizedDescription))
            return false
        }
        var price = "Your OpenRouter account is charged at the model's rate."
        if let url = URL(string: cloudEndpoint + "/models"), let (data, _) = try? await URLSession.shared.data(from: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let model = (obj["data"] as? [[String: Any]])?.first(where: { $0["id"] as? String == cloudModel }),
           let pricing = model["pricing"] as? [String: Any],
           let input = Double(pricing["prompt"] as? String ?? ""), let output = Double(pricing["completion"] as? String ?? "") {
            // Roughly 6 000 tokens in (catalogue and document) and 500 out.
            price = String(format: "About $%.4f for this request (%@).", input * 6_000 + output * 500, cloudModel)
        }
        let alert = NSAlert()
        alert.messageText = "Send this to \(cloudModel)?"
        alert.informativeText = "\(price) The request and a short description of the document go to the model service; the audio doesn't."
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
                Text(model.useCloud ? model.cloudModel : "On this Mac").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
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
                            Text(m.text)
                                .font(m.role == .note ? .caption : .callout)
                                .foregroundStyle(m.role == .note ? Color.secondary : m.role == .user ? Color.white : Theme.neonColor)
                                .frame(maxWidth: .infinity, alignment: m.role == .user ? .trailing : .leading)
                                .textSelection(.enabled)
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
            Picker("Model", selection: $model.useCloud) {
                Text("On this Mac (free, private)").tag(false)
                Text("OpenRouter (your key, paid)").tag(true)
            }
            .pickerStyle(.radioGroup)
            if model.useCloud {
                TextField("Model", text: $model.cloudModel)
                TextField("Endpoint", text: $model.cloudEndpoint)
                SecureField(Keychain.get("openrouter") == nil ? "OpenRouter key" : "Key saved; type to replace", text: $key)
                Text("The key stays in your Keychain. Every request asks first and shows the price.").font(.caption).foregroundStyle(.secondary)
            }
            Button("Done") {
                if !key.isEmpty { Keychain.set("openrouter", key); key = "" }
                model.saveSettings()
                showSettings = false
            }
        }
        .onChange(of: model.useCloud) { model.saveSettings() }
    }
}
