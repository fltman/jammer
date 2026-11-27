import AppKit
import JammerAssistant
import JammerCore
import SwiftUI

/// The omnibar: a glass field at the bottom of the window, where ⌘K puts the keyboard. What you type is
/// looked up among the app's commands (the menus, the presets and the agent's operations share one list);
/// Return runs the highlighted one, and a text that reads as a request goes to the assistant. A text that
/// could be either is decided by Apple's model on this Mac, free and private. ⌘Return always asks the
/// assistant. What goes to the assistant is sent as from its own field (`AssistantModel.send`), so its
/// source, its price question and its checks are the same.
@MainActor @Observable
final class OmnibarModel {
    var query = "" { didSet { if query != oldValue { chosen = nil } } }
    /// A row picked with ↑/↓; nil while Return does what the text suggests.
    var chosen: Int?
    var focusRequest = 0
    var focused = false
    /// Apple's model is deciding between a command and the assistant.
    var deciding = false

    @ObservationIgnored let commands: () -> [PaletteCommand]
    @ObservationIgnored let ask: (String) -> Void
    /// Gives the keyboard back to the timeline.
    @ObservationIgnored let leave: () -> Void

    init(commands: @escaping () -> [PaletteCommand], ask: @escaping (String) -> Void, leave: @escaping () -> Void) {
        self.commands = commands
        self.ask = ask
        self.leave = leave
    }

    struct Row: Identifiable {
        let id: String
        let title: String
        let detail: String
        let shortcut: String
        /// nil: the row that asks the assistant.
        let command: PaletteCommand?
    }

    // How often each command was run from here (for the order; kept on this Mac).
    static let usageKey = "omnibar.usage"
    private var usage: [String: CommandSearch.Usage] = {
        guard let data = UserDefaults.standard.data(forKey: OmnibarModel.usageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: CommandSearch.Usage].self, from: data)) ?? [:]
    }()

    var text: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The rows under the field, and what Return does with the text.
    func rows() -> (rows: [Row], route: CommandSearch.Route, selected: Int) {
        let list = commands()
        let byId = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let found = CommandSearch.search(text, in: list.map { .init(id: $0.id, title: $0.title, detail: $0.detail) }, usage: usage)
        // A second line that only repeats the title (a preset named as its operation) is left out.
        // A command that can't run now says why in place of its detail (SIBLINGS comfort list: a disabled command says why).
        var rows = found.compactMap { f in byId[f.entry.id].map { Row(id: $0.id, title: $0.title, detail: $0.unavailable ?? ($0.detail == $0.title ? "" : $0.detail), shortcut: $0.shortcut, command: $0) } }
        if !text.isEmpty {
            // No command matches: said, above the question to the assistant (COMFORT 64).
            let detail = rows.isEmpty ? L10n.text("omnibar.noMatch") + " " + L10n.text("omnibar.ask.detail") : L10n.text("omnibar.ask.detail")
            rows.append(Row(id: "omnibar.ask", title: L10n.text("omnibar.ask", text), detail: detail, shortcut: "⌘↩", command: nil))
        }
        let route = CommandSearch.route(text, best: found.first)
        let fallback = route == .ask ? rows.count - 1 : 0
        return (rows, route, chosen.map { min(max($0, 0), max(rows.count - 1, 0)) } ?? max(fallback, 0))
    }

    func move(_ by: Int) {
        let r = rows()
        guard !r.rows.isEmpty else { return }
        chosen = min(max(r.selected + by, 0), r.rows.count - 1)
    }

    /// Return (or ⌘Return, `alwaysAsk`).
    func submit(alwaysAsk: Bool = false) {
        guard !text.isEmpty, !deciding else { return }
        if alwaysAsk { return send(text) }
        let r = rows()
        guard let row = r.rows[safe: r.selected] else { return }
        guard let command = row.command else { return send(text) }
        // Could be either, and the row wasn't picked by hand: the model on this Mac decides, among the commands shown.
        if chosen == nil, r.route == .unsure, OmnibarRouter.available {
            let shown = r.rows.compactMap(\.command)
            let typed = text
            deciding = true
            deciding_ = Task {
                let i = await OmnibarRouter.pick(typed, among: shown.map { .init(id: $0.id, title: $0.title, detail: $0.detail) })
                deciding = false
                deciding_ = nil
                // Esc while it decided: nothing runs and nothing is sent (COMFORT 7).
                guard !Task.isCancelled else { return }
                if let i { run(shown[i]) } else { send(typed) }
            }
            return
        }
        run(command)
    }

    func run(_ command: PaletteCommand) {
        CommandSearch.Usage.record(command.id, in: &usage)
        if let data = try? JSONEncoder().encode(usage) { UserDefaults.standard.set(data, forKey: Self.usageKey) }
        query = ""
        leave()
        command.run()
    }

    private func send(_ request: String) {
        query = ""
        leave()
        ask(request)
    }

    func cancel() {
        deciding_?.cancel()
        deciding_ = nil
        deciding = false
        query = ""
        leave()
    }
    /// The decision under way (the model on this Mac picking a command): Esc cancels it.
    @ObservationIgnored private var deciding_: Task<Void, Never>?
}

struct OmnibarView: View {
    /// A plain arrow moves among the rows; with ⌥, ⇧, ⌘ or ⌃ it is left to the field (⌥↑ to the start of the line,
    /// ⇧↑ to select; K2a: a view's key stays the view's).
    private func rowMove(_ press: KeyPress, _ by: Int) -> KeyPress.Result {
        guard press.modifiers.isDisjoint(with: [.option, .shift, .command, .control]) else { return .ignored }
        model.move(by)
        return .handled
    }

    @Bindable var model: OmnibarModel
    @FocusState private var focused: Bool

    var body: some View {
        let r = model.rows()
        VStack(spacing: 6) {
            if focused, !r.rows.isEmpty {
                VStack(spacing: 1) {
                    ForEach(Array(r.rows.enumerated()), id: \.element.id) { i, row in
                        Button {
                            if let c = row.command { model.run(c) } else { model.submit(alwaysAsk: true) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: row.command == nil ? "sparkles" : "command").foregroundStyle(i == r.selected ? Theme.neonColor : .secondary)
                                    .frame(width: 16).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.title).foregroundStyle(row.command?.unavailable != nil ? .secondary : i == r.selected ? Theme.neonColor : .primary).lineLimit(1)
                                    if !row.detail.isEmpty { Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                }
                                Spacer(minLength: 8)
                                Text(row.shortcut).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 38)
                            .background(i == r.selected ? Theme.neonColor.opacity(0.12) : .clear, in: .rect(cornerRadius: 8))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        // The row under the pointer is the chosen one, so Return and a click mean the same row (COMFORT 64).
                        .onHover { inside in if inside { model.chosen = i } }
                        .accessibilityLabel(row.detail.isEmpty ? row.title : "\(row.title), \(row.detail)")
                        .accessibilityAddTraits(i == r.selected ? .isSelected : [])
                    }
                }
                .padding(6)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
            }
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(Theme.neonColor).accessibilityHidden(true)
                TextField(L10n.text("omnibar.placeholder"), text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .accessibilityLabel(L10n.text("omnibar.field.ax"))
                    .accessibilityHint(L10n.text("omnibar.field.hint"))
                    .focused($focused)
                    .onSubmit { model.submit() }
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        model.submit(alwaysAsk: true)
                        return .handled
                    }
                    // A plain arrow moves among the rows; with ⌥, ⇧, ⌘ or ⌃ it is the field's (⌥↑ to the start of the
                    // line, ⇧↑ to select; K2a: a view's key stays the view's).
                    .onKeyPress(.downArrow, phases: [.down, .repeat]) { (press: KeyPress) -> KeyPress.Result in rowMove(press, 1) }
                    .onKeyPress(.upArrow, phases: [.down, .repeat]) { (press: KeyPress) -> KeyPress.Result in rowMove(press, -1) }
                    .onKeyPress(.escape) { model.cancel(); return .handled }
                if model.deciding {
                    ProgressView().controlSize(.small).accessibilityLabel(L10n.text("omnibar.deciding"))
                } else if focused {
                    Text(L10n.text("omnibar.keys")).font(.caption).foregroundStyle(.secondary).fixedSize().accessibilityHidden(true)
                } else {
                    Text("⌘K").font(.caption.monospaced()).foregroundStyle(.secondary).accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .glassEffect(.regular, in: .capsule)
        }
        .onChange(of: model.focusRequest) { focused = true }
        .onChange(of: focused) { model.focused = focused }
    }
}
