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
    /// Where the transcribing is done. Shown only while the paid route is being tried out (hidden providers on).
    private let engine = NSPopUpButton()
    private let transcribeButton = NSButton(title: "Transcribe", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private var placed: [PlacedWord] = []
    private var ranges: [NSRange] = []
    private var shownVersion = -1
    private var litWord: Int?
    private var updatingSelection = false

    static let languages: [(String, String)] = [
        ("Swedish", "sv-SE"), ("English (US)", "en-US"), ("English (UK)", "en-GB"), ("German", "de-DE"),
        ("French", "fr-FR"), ("Spanish", "es-ES"), ("Italian", "it-IT"), ("Portuguese (Brazil)", "pt-BR"),
    ]

    init(session: EditorSession) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.lane.cgColor

        let title = NSTextField(labelWithString: "Transcript")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = Theme.text
        for (name, code) in Self.languages {
            language.addItem(withTitle: name)
            language.lastItem?.representedObject = code
        }
        let preferred = UserDefaults.standard.string(forKey: "transcript.language") ?? Locale.current.identifier(.bcp47)
        if let i = Self.languages.firstIndex(where: { $0.1 == preferred || $0.1.hasPrefix(preferred.prefix(2)) }) { language.selectItem(at: i) }
        language.controlSize = .small
        language.setAccessibilityLabel("Transcription language")
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
        engine.addItem(withTitle: "On this Mac")
        engine.lastItem?.representedObject = SpeechEngines.Choice.auto.rawValue
        engine.addItem(withTitle: "OpenAI (your key, paid)")
        engine.lastItem?.representedObject = SpeechEngines.Choice.openai.rawValue
        // Said where it is chosen: what this choice means, before the sheet says it in full.
        engine.lastItem?.toolTip = "The audio is uploaded to OpenAI and transcribed there, for a price. The text comes back without the time of each word: you can read, search and correct it, but not edit the audio with it. Built from OpenAI's documentation, not tried with a real request."
        engine.toolTip = "Where the document is transcribed. On this Mac nothing leaves it."
        engine.controlSize = .small
        engine.setAccessibilityLabel("Transcription engine")
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
        textView.setAccessibilityLabel("Transcript")
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true

        empty.textColor = .secondaryLabelColor
        empty.font = .systemFont(ofSize: 12)
        empty.alignment = .center

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
        transcribeButton.title = session.project.transcripts.isEmpty ? "Transcribe" : "Transcribe Again"
        if placed.isEmpty {
            empty.isHidden = false
            scroll.isHidden = true
            if running {
                empty.stringValue = "Transcribing on this Mac…"
            } else if let job, job.status == .failed {
                empty.stringValue = job.error?.message ?? "Transcription failed."
            } else {
                // True for the choice that is made: on this Mac nothing leaves it; at OpenAI the audio does.
                let away = engine.selectedItem?.representedObject as? String == SpeechEngines.Choice.openai.rawValue
                empty.stringValue = away ? "No transcript yet. Choose the language and click Transcribe. With OpenAI chosen, the audio is uploaded there; Jämmer asks first."
                                         : "No transcript yet. Choose the language and click Transcribe. Transcribed on this Mac, nothing leaves it."
            }
        } else {
            empty.isHidden = true
            scroll.isHidden = false
        }
        lightPlayingWord()
        mirrorSelection()
    }

    private func rebuild() {
        shownVersion = session.version
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
                    session.status = "This transcript has no word times, so a click can't find the word in the audio."
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
        if engine.selectedItem?.representedObject as? String == SpeechEngines.Choice.openai.rawValue {
            Task { await transcribeAtOpenAI(Locale(identifier: code)) }
            return
        }
        _ = JobRegistry.shared.startTranscription(session, locale: Locale(identifier: code), replace: !session.project.transcripts.isEmpty)
        refresh()
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
            say("There is no OpenAI key", "Add your OpenAI key in the assistant's settings (the gear in the assistant panel, under OpenAI). Nothing was sent.")
            return
        }
        let models: [String]
        do { models = try await OpenAITranscription.models(endpoint: SpeechEngines.openAIEndpoint, key: key) } catch {
            say("OpenAI's list of models couldn't be read", "\(error.localizedDescription) Nothing was sent.")
            return
        }
        guard !models.isEmpty else {
            say("OpenAI lists no transcription model for this key", "Nothing was sent.")
            return
        }
        // What goes: the whole of each file the document plays from that has no transcript yet (or all of them, when transcribing again).
        let p = session.project
        let replace = !p.transcripts.isEmpty
        let used = Set(p.tracks.flatMap { $0.clips.map(\.sourceID) })
        let todo = p.sources.filter { s in used.contains(s.id) && (replace || !p.transcripts.contains { $0.sourceID == s.id }) }
        let seconds = todo.reduce(0.0) { $0 + Double($1.info.frames) / $1.info.sampleRate }
        let pieces = todo.reduce(0) { $0 + max(1, Int((Double($1.info.frames) / $1.info.sampleRate / 600).rounded(.up))) }
        let length = seconds >= 3600 ? String(format: "%d h %d min", Int(seconds) / 3600, Int(seconds) % 3600 / 60) : String(format: "%d min %d s", Int(seconds) / 60, Int(seconds) % 60)

        let pick = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        pick.addItems(withTitles: models)
        pick.setAccessibilityLabel("OpenAI model")
        if let last = models.firstIndex(of: SpeechEngines.openAIModel) { pick.selectItem(at: last) }
        let alert = NSAlert()
        alert.messageText = "Send the audio to OpenAI?"
        alert.informativeText = """
        \(todo.count == 1 ? "The file" : "The \(todo.count) files") this document plays from (\(length) in all, the whole of each file, not only the parts on the timeline) will be uploaded to OpenAI in \(pieces) piece\(pieces == 1 ? "" : "s") and transcribed there.

        OpenAI charges your account for it by its own price list for the model you choose; Jämmer can't read that price list and doesn't guess the cost.

        The transcript comes back as text without the time of each word. You can read, search and correct it; you can't delete words or filler words from the audio with it.

        Jämmer hasn't been able to read OpenAI's terms for what it does with uploaded audio. Read them at OpenAI before sending anything that isn't yours to share.

        This route is built from OpenAI's documentation and has not been tried with a real request. If OpenAI answers with an error, Jämmer shows it as it came.
        """
        let unknown = UnknownPriceBox(service: "openai.transcription", name: "OpenAI")
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
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
