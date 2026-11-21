import AppKit
import JammerAgent
import JammerCore
import JammerSpeech
import Observation

extension NSAttributedString.Key {
    /// Index into the panel's placed words.
    static let jammerWord = NSAttributedString.Key("JammerWord")
}

/// The transcript under the timeline. It reads what plays now (a view of the edit
/// list): selecting words selects their audio, Delete removes them, a click moves the
/// playhead, and the word being played is lit.
@MainActor
final class TranscriptPanel: NSView, NSTextViewDelegate {
    let session: EditorSession
    private let textView = TranscriptTextView()
    private let scroll = NSScrollView()
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let language = NSPopUpButton()
    /// Where the transcribing is done.
    private let engine = NSPopUpButton()
    private var selectedEngine: SpeechEngines.Choice {
        (engine.selectedItem?.representedObject as? String).flatMap(SpeechEngines.Choice.init(rawValue:)) ?? .auto
    }
    private let transcribeButton = NSButton(title: L10n.text("transcript.transcribe"), target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private var placed: [PlacedWord] = []
    private var ranges: [NSRange] = []
    private var shownVersion = -1
    private var litWord: Int?
    private var updatingSelection = false

    static var languages: [(String, String)] { [
        (L10n.text("lang.sv"), "sv-SE"), (L10n.text("lang.da"), "da-DK"), (L10n.text("lang.nb"), "nb-NO"), (L10n.text("lang.enUS"), "en-US"), (L10n.text("lang.enGB"), "en-GB"), (L10n.text("lang.de"), "de-DE"),
        (L10n.text("lang.fr"), "fr-FR"), (L10n.text("lang.es"), "es-ES"), (L10n.text("lang.it"), "it-IT"), (L10n.text("lang.ptBR"), "pt-BR"),
    ] }

    init(session: EditorSession) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.lane.cgColor

        let title = NSTextField(labelWithString: L10n.text("transcript.title"))
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = Theme.text
        for (name, code) in Self.languages {
            language.addItem(withTitle: name)
            language.lastItem?.representedObject = code
        }
        let preferred = UserDefaults.standard.string(forKey: "transcript.language") ?? Locale.current.identifier(.bcp47)
        if let i = Self.languages.firstIndex(where: { $0.1 == preferred || $0.1.hasPrefix(preferred.prefix(2)) }) { language.selectItem(at: i) }
        language.controlSize = .small
        language.setAccessibilityLabel(L10n.text("transcript.language.ax"))
        transcribeButton.target = self
        transcribeButton.action = #selector(transcribe(_:))
        transcribeButton.controlSize = .small
        transcribeButton.bezelStyle = .rounded
        progress.style = .bar
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1
        progress.isIndeterminate = false
        progress.isHidden = true
        progress.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let choices: [(SpeechEngines.Choice, String, String?)] = [
            (.auto, L10n.text("transcript.engine.local"), nil),
            (.pianissimo, L10n.text("transcript.engine.pianissimo"), L10n.text("transcript.engine.pianissimo.help")),
            (.bergetPianissimo, L10n.text("transcript.engine.berget"), L10n.text("transcript.engine.berget.help")),
            (.openai, L10n.text("transcript.engine.openai"), L10n.text("transcript.engine.openai.help")),
        ]
        for (choice, title, help) in choices {
            engine.addItem(withTitle: title)
            engine.lastItem?.representedObject = choice.rawValue
            engine.lastItem?.toolTip = help
        }
        engine.toolTip = L10n.text("transcript.engine.help")
        engine.controlSize = .small
        engine.setAccessibilityLabel(L10n.text("transcript.engine.ax"))
        engine.target = self
        engine.action = #selector(engineChanged(_:))
        let header = NSStackView(views: [title, NSView(), progress, engine, language, transcribeButton])
        header.orientation = .horizontal
        header.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        header.setHuggingPriority(.required, for: .vertical)

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 6)
        textView.font = .systemFont(ofSize: 14)
        textView.delegate = self
        textView.panel = self
        textView.setAccessibilityLabel(L10n.text("transcript.title"))
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true

        empty.textColor = .secondaryLabelColor
        empty.font = .systemFont(ofSize: 12)
        empty.alignment = .center
        // It wraps to the panel's width rather than asking for its text's.
        empty.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [header, scroll, empty])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 110),
        ])
        observe()
        refresh()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func observe() {
        withObservationTracking {
            _ = session.version
            _ = session.playhead
            _ = session.selection
            _ = JobRegistry.shared.latest("transcribe", document: session.agentID)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                self.observe()
            }
        }
    }

    private func refresh() {
        if session.version != shownVersion { rebuild() }
        let job = JobRegistry.shared.latest("transcribe", document: session.agentID)
        let running = job.map { !$0.isFinished } ?? false
        progress.isHidden = !running
        progress.doubleValue = job?.progress ?? 0
        transcribeButton.isEnabled = !running
        transcribeButton.title = session.project.transcripts.isEmpty ? L10n.text("transcript.transcribe") : L10n.text("transcript.transcribeAgain")
        if placed.isEmpty {
            empty.isHidden = false
            scroll.isHidden = true
            if running {
                empty.stringValue = L10n.text("transcript.working")
            } else if let job, job.status == .failed {
                empty.stringValue = job.errorKeyed.map(L10n.message) ?? job.error?.message ?? L10n.text("transcript.failed")
            } else {
                empty.stringValue = switch selectedEngine {
                case .openai: L10n.text("transcript.empty.openai")
                case .bergetPianissimo: L10n.text("transcript.empty.berget")
                default: L10n.text("transcript.empty.local")
                }
            }
        } else {
            empty.isHidden = true
            scroll.isHidden = false
        }
        lightPlayingWord()
        mirrorSelection()
    }

    /// What the text is made from. A step that changes none of it (a fader, a marker, a plugin) leaves the
    /// text as it is: building 20 000 words again took a quarter of a second at every step.
    private struct Shown: Equatable {
        var transcripts: [SourceTranscript]
        var clips: [[Clip]]
        var muted: [Bool]
        var turns: [SourceSpeakers]
        var speakers: [String]
    }
    private var shown: Shown?

    private func rebuild() {
        shownVersion = session.version
        let p = session.project
        let now = Shown(transcripts: p.transcripts, clips: p.tracks.map(\.clips), muted: p.tracks.map(\.isMuted), turns: p.speakerTurns, speakers: p.speakers)
        if now == shown { return }
        shown = now
        // Show the language the transcript is in, once there is one.
        if let lang = session.project.transcripts.first?.language,
           let i = Self.languages.firstIndex(where: { $0.1 == lang }) ?? Self.languages.firstIndex(where: { $0.1.prefix(2) == lang.prefix(2) }) {
            language.selectItem(at: i)
        }
        placed = session.project.placedWords()
        let text = NSMutableAttributedString()
        ranges = []
        let normal: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor(white: 1, alpha: 0.88)]
        let names = session.project.speakers
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: Theme.neon]
        var speaker: Int?
        for (i, w) in placed.enumerated() {
            // A new speaker starts a paragraph with their name.
            if let s = w.word.speaker, s != speaker, names.indices.contains(s) {
                speaker = s
                text.append(NSAttributedString(string: (i > 0 ? "\n\n" : "") + names[s] + "\n", attributes: label))
            } else if i > 0 {
                text.append(NSAttributedString(string: " ", attributes: normal))
            }
            var attrs = normal
            attrs[.jammerWord] = i
            if w.isPartial { attrs[.foregroundColor] = NSColor(white: 1, alpha: 0.45) }
            if let c = w.word.confidence, c < 0.6 {
                // Unsure words: dotted underline, so they're easy to check.
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
                attrs[.underlineColor] = Theme.marker
            }
            let start = text.length
            text.append(NSAttributedString(string: w.word.text, attributes: attrs))
            ranges.append(NSRange(location: start, length: text.length - start))
        }
        updatingSelection = true
        textView.textStorage?.setAttributedString(text)
        updatingSelection = false
        litWord = nil
    }

    /// The word under the playhead gets a soft neon background while playing.
    private func lightPlayingWord() {
        guard let lm = textView.layoutManager else { return }
        let i = session.isPlaying ? wordIndex(at: session.playhead) : nil
        guard i != litWord else { return }
        if let old = litWord, old < ranges.count { lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: ranges[old]) }
        litWord = i
        if let i, i < ranges.count {
            lm.addTemporaryAttribute(.backgroundColor, value: Theme.neon.withAlphaComponent(0.28), forCharacterRange: ranges[i])
            textView.scrollRangeToVisible(ranges[i])
        }
    }

    private func wordIndex(at frame: Frame) -> Int? {
        var lo = 0, hi = placed.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if placed[mid].end <= frame { lo = mid + 1 } else { hi = mid }
        }
        return lo < placed.count && placed[lo].start <= frame ? lo : nil
    }

    /// A timeline selection shows as selected words.
    private func mirrorSelection() {
        guard let sel = session.selection, !placed.isEmpty else { return }
        let inside = placed.indices.filter { placed[$0].start < sel.upperBound && placed[$0].end > sel.lowerBound }
        guard let first = inside.first, let last = inside.last else { return }
        let r = NSRange(location: ranges[first].location, length: NSMaxRange(ranges[last]) - ranges[first].location)
        guard textView.selectedRange() != r else { return }
        updatingSelection = true
        textView.setSelectedRange(r)
        updatingSelection = false
    }

    func selectedWordIndices() -> [Int] {
        let sel = textView.selectedRange()
        guard sel.length > 0 else { return [] }
        return ranges.indices.filter { NSIntersectionRange(ranges[$0], sel).length > 0 }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !updatingSelection else { return }
        let sel = textView.selectedRange()
        if sel.length == 0 {
            // A click: the playhead goes to the word.
            if let i = ranges.firstIndex(where: { NSLocationInRange(sel.location, $0) || NSMaxRange($0) == sel.location }) {
                // Without word times the word's place is a guess; going there would look like knowing.
                if session.project.areTextOnly([placed[i].word.id]) {
                    session.status = L10n.text("transcript.noTimes")
                    return
                }
                session.selection = nil
                session.seek(placed[i].start)
            }
            return
        }
        let idx = selectedWordIndices()
        guard let first = idx.first, let last = idx.last else { return }
        session.selection = placed[first].start..<placed[last].end
    }

    /// Delete: the selected words go, with the pauses between them.
    func deleteSelectedWords() {
        let ids = selectedWordIndices().map { JSONValue.string(placed[$0].word.id.uuidString) }
        guard !ids.isEmpty else { NSSound.beep(); return }
        session.perform("delete_words", ["words": .array(ids), "bridge": .number(0.3)])
    }

    /// The line under an empty transcript says where it will be transcribed.
    @objc func engineChanged(_ sender: Any?) { refresh() }

    @objc func transcribe(_ sender: Any?) {
        let code = language.selectedItem?.representedObject as? String ?? "sv-SE"
        UserDefaults.standard.set(code, forKey: "transcript.language")
        let locale = Locale(identifier: code)
        switch selectedEngine {
        case .openai:
            Task { await transcribeAtOpenAI(locale) }
        case .bergetPianissimo:
            Task { await transcribeAtBerget(locale) }
        default:
            _ = JobRegistry.shared.startTranscription(session, locale: locale, replace: !session.project.transcripts.isEmpty, engine: selectedEngine)
            refresh()
        }
    }

    private func transcribeAtBerget(_ locale: Locale) async {
        let choice = SpeechEngines.Choice.bergetPianissimo
        do { _ = try SpeechEngines.engine(choice, for: locale) } catch {
            let alert = NSAlert()
            alert.messageText = L10n.text("transcript.engine.berget")
            alert.informativeText = L10n.error(error)
            if let window { _ = await alert.beginSheetModal(for: window) } else { alert.runModal() }
            return
        }
        guard let price = choice.price else { return }
        let replace = !session.project.transcripts.isEmpty
        let sources = transcriptionSources(replace: replace)
        guard !sources.isEmpty else { return }
        let seconds = sources.reduce(0.0) { $0 + Double($1.info.frames) / $1.info.sampleRate }
        let estimate = seconds / 60 * price.amount
        let alert = NSAlert()
        alert.messageText = L10n.text("berget.transcription.ask")
        alert.informativeText = L10n.text("berget.transcription.upload", L10n.count("storage.files", sources.count),
                                        L10n.number(seconds / 60, 2), L10n.number(estimate, 4))
            + "\n\n" + SpeechEngines.bergetPriceLine(price)
        alert.addButton(withTitle: L10n.text("button.send"))
        alert.addButton(withTitle: L10n.text("button.cancel"))
        let answer: NSApplication.ModalResponse
        if let window { answer = await alert.beginSheetModal(for: window) } else { answer = alert.runModal() }
        guard answer == .alertFirstButtonReturn else { return }
        guard sources == transcriptionSources(replace: replace) else {
            session.say(L10n.text("berget.transcription.changed"), .warning)
            return
        }
        _ = JobRegistry.shared.startTranscription(session, locale: locale, replace: replace, engine: choice)
        refresh()
    }

    private func transcriptionSources(replace: Bool) -> [SourceRef] {
        let project = session.project
        let used = Set(project.tracks.flatMap { $0.clips.map(\.sourceID) })
        return project.sources.filter { source in
            used.contains(source.id) && (replace || !project.transcripts.contains { $0.sourceID == source.id })
        }
    }

    /// The paid route: what leaves the Mac and who charges for it is said first, and nothing is sent
    /// before the user has chosen a model from the provider's own list and clicked Send.
    private func transcribeAtOpenAI(_ locale: Locale) async {
        func say(_ title: String, _ text: String) {
            let a = NSAlert()
            a.messageText = title
            a.informativeText = text
            if let w = window { a.beginSheetModal(for: w) } else { a.runModal() }
        }
        guard let key = SpeechEngines.openAIKey, !key.isEmpty else {
            say(L10n.text("openai.noKey.title"), L10n.text("openai.noKey.text"))
            return
        }
        let models: [String]
        do { models = try await OpenAITranscription.models(endpoint: SpeechEngines.openAIEndpoint, key: key) } catch {
            say(L10n.text("openai.models.failed.title"), L10n.text("openai.models.failed.text", L10n.error(error)))
            return
        }
        guard !models.isEmpty else {
            say(L10n.text("openai.models.none.title"), L10n.text("openai.nothingSent"))
            return
        }
        // What goes: the whole of each file the document plays from that has no transcript yet (or all of them, when transcribing again).
        let replace = !session.project.transcripts.isEmpty
        let todo = transcriptionSources(replace: replace)
        let seconds = todo.reduce(0.0) { $0 + Double($1.info.frames) / $1.info.sampleRate }
        let pieces = todo.reduce(0) { $0 + max(1, Int((Double($1.info.frames) / $1.info.sampleRate / 600).rounded(.up))) }
        let length = seconds >= 3600 ? L10n.text("duration.hoursMinutes", String(Int(seconds) / 3600), String(Int(seconds) % 3600 / 60)) : L10n.text("duration.minutesSeconds", String(Int(seconds) / 60), String(Int(seconds) % 60))

        let pick = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        pick.addItems(withTitles: models)
        pick.setAccessibilityLabel(L10n.text("openai.model.ax"))
        if let last = models.firstIndex(of: SpeechEngines.openAIModel) { pick.selectItem(at: last) }
        let alert = NSAlert()
        alert.messageText = L10n.text("openai.ask.title")
        alert.informativeText = L10n.text("openai.ask.text", L10n.count("storage.files", todo.count), length, L10n.count("openai.ask.pieces", pieces))
        let unknown = UnknownPriceBox(service: "openai.transcription", name: "OpenAI")
        alert.addButton(withTitle: L10n.text("button.send"))
        alert.addButton(withTitle: L10n.text("button.cancel"))
        UnknownPriceBox.place([pick, unknown.view], in: alert)
        unknown.gate(alert.buttons[0])
        let answer: NSApplication.ModalResponse
        if let w = window { answer = await alert.beginSheetModal(for: w) } else { answer = alert.runModal() }
        guard answer == .alertFirstButtonReturn, let model = pick.titleOfSelectedItem else { return }
        unknown.sent()
        UserDefaults.standard.set(model, forKey: "transcribe.openai.model")
        _ = JobRegistry.shared.startTranscription(session, locale: locale, replace: replace, engine: .openai, model: model)
        refresh()
    }
}

/// Read-only text that turns Delete into "delete these words".
final class TranscriptTextView: NSTextView {
    weak var panel: TranscriptPanel?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            MainActor.assumeIsolated { panel?.deleteSelectedWords() }
            return
        }
        // Space plays and stops, as on the timeline.
        if event.charactersIgnoringModifiers == " " {
            MainActor.assumeIsolated { panel?.session.togglePlay() }
            return
        }
        super.keyDown(with: event)
    }
}
