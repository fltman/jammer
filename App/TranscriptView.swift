import AppKit
import JammerAgent
import JammerCore
import JammerSpeech
import Observation
import SwiftUI

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
    private var placed: [PlacedWord] = [] { didSet { wordStarts = placed.map(\.start); wordEnds = placed.map(\.end) } }
    private var wordStarts: [Frame] = [], wordEnds: [Frame] = []
    private var ranges: [NSRange] = []
    private var shownVersion = -1
    private var litWord: Int?
    private var updatingSelection = false
    /// The line above the text when a transcript has no word times (COMFORT: say what can't be done, before it's tried).
    private let textOnlyNote = NSHostingView(rootView: StateLine(kind: .warning, text: L10n.text("transcript.textOnly")))
    /// The text's size, ⌘+ and ⌘− while the transcript has the keys (remembered).
    private(set) var textSize: CGFloat = {
        let v = UserDefaults.standard.double(forKey: "transcript.textSize")
        return v >= 10 && v <= 28 ? CGFloat(v) : 14
    }()
    /// When the reader last scrolled the text: following the playing word waits a while after that, so it doesn't
    /// snap the view back from what they are reading ahead.
    private var readerScrolledAt: Date?
    private var scrollingToWord = false
    private var wasPlaying = false
    /// A paid route is asking its provider or the user (OpenAI's model list, the question): the button waits, with a
    /// spinner, so a second click doesn't start a second request (COMFORT 52).
    private var asking = false { didSet { refresh() } }
    /// The panel's height, dragged at its top edge (remembered).
    private(set) lazy var heightConstraint: NSLayoutConstraint = {
        let saved = UserDefaults.standard.double(forKey: "transcript.height")
        let c = heightAnchor.constraint(equalToConstant: saved >= 110 ? saved : 220)
        c.priority = .defaultHigh
        return c
    }()

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
        language.toolTip = L10n.text("transcript.language.help")
        language.autoenablesItems = false
        language.target = self
        language.action = #selector(languageChanged(_:))
        transcribeButton.target = self
        transcribeButton.action = #selector(transcribe(_:))
        transcribeButton.controlSize = .small
        transcribeButton.bezelStyle = .rounded
        transcribeButton.toolTip = L10n.text("transcript.transcribe.help")
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
        // The engine chosen last time (paid ones too: choosing one sends nothing; Transcribe asks first).
        if let saved = UserDefaults.standard.string(forKey: "transcript.engine"),
           let i = engine.itemArray.firstIndex(where: { $0.representedObject as? String == saved }) { engine.selectItem(at: i) }
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
        textView.font = .systemFont(ofSize: textSize)
        textView.delegate = self
        textView.panel = self
        textView.setAccessibilityLabel(L10n.text("transcript.title"))
        // Edit › Find in Transcript: the system's find bar over the text, ignoring case and accents.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(textScrolled(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true

        empty.textColor = .secondaryLabelColor
        empty.font = .systemFont(ofSize: 12)
        empty.alignment = .center
        // It wraps to the panel's width rather than asking for its text's.
        empty.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        textOnlyNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textOnlyNote.isHidden = true
        let note = NSStackView(views: [textOnlyNote])
        note.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 4, right: 14)
        let grip = ResizeGrip { [weak self] dy in self?.dragHeight(by: dy) } ended: { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(Double(self.heightConstraint.constant), forKey: "transcript.height")
        }
        grip.setAccessibilityLabel(L10n.text("transcript.resize.ax"))
        grip.toolTip = L10n.text("transcript.resize.help")
        let stack = NSStackView(views: [grip, header, note, scroll, empty])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 110),
            grip.heightAnchor.constraint(equalToConstant: 6),
            heightConstraint,
        ])
        languageChanged(nil)
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
        progress.isHidden = !running && !asking
        progress.isIndeterminate = asking && !running
        if asking && !running { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        progress.doubleValue = job?.progress ?? 0
        // While it runs, the button that started it stops it (COMFORT 7); while a paid route asks, it waits.
        transcribeButton.isEnabled = !asking || running
        transcribeButton.title = running ? L10n.text("job.stop") : session.project.transcripts.isEmpty ? L10n.text("transcript.transcribe") : L10n.text("transcript.transcribeAgain")
        transcribeButton.toolTip = running ? L10n.text("job.stop.help", L10n.text("transcript.working")) : nil
        if placed.isEmpty {
            empty.isHidden = false
            scroll.isHidden = true
            if running {
                empty.stringValue = switch job.flatMap({ JobRegistry.shared.engineOf[$0.id] }) {
                case .openai?: L10n.text("transcript.working.openai")
                case .bergetPianissimo?: L10n.text("transcript.working.berget")
                default: L10n.text("transcript.working")
                }
            } else if !session.project.transcripts.isEmpty, job.map({ $0.status == .done }) ?? true {
                // Transcribed, but nothing that plays now has words: cut away, or every such track muted.
                empty.stringValue = L10n.text("transcript.empty.nothingAudible")
            } else if let job, job.status == .cancelled {
                // A paid request had left: "nothing changed" would sit beside "may have been charged" (the status bar).
                empty.stringValue = JobRegistry.shared.mayHaveBeenCharged(job.id) ? L10n.text("transcript.stopped.paid") : L10n.text("job.stopped")
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
        textOnlyNote.isHidden = !session.project.transcripts.contains { $0.textOnly == true } || placed.isEmpty
        if session.isPlaying, !wasPlaying { readerScrolledAt = nil }
        wasPlaying = session.isPlaying
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
        let normal: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: textSize), .foregroundColor: NSColor(white: 1, alpha: 0.88)]
        let names = session.project.speakers
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: textSize - 2, weight: .semibold), .foregroundColor: Theme.neon]
        let italic = NSFontManager.shared.convert(NSFont.systemFont(ofSize: textSize), toHaveTrait: .italicFontMask)
        let untimed = Set(p.transcripts.filter { $0.textOnly == true }.flatMap { $0.words.map(\.id) })
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
            let filler = Project.fillerWords.contains(w.word.text.lowercased().trimmingCharacters(in: .punctuationCharacters))
            if filler {
                // Filler words dimmed: Edit › Remove Filler Words takes these out.
                attrs[.foregroundColor] = NSColor(white: 1, alpha: 0.5)
                attrs[.font] = italic
            }
            let unsure = (w.word.confidence ?? 1) < 0.6
            if unsure {
                // Unsure words: dotted underline, so they're easy to check.
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
                attrs[.underlineColor] = Theme.marker
            }
            // On hover: when the word is heard, and how sure the recogniser was (never a time it doesn't know).
            if w.word.untimed != true, !untimed.contains(w.word.id) {
                let at = formatTime(p.seconds(w.start))
                var tip = w.word.confidence.map { c -> String in
                    let percent = String(Int((c * 100).rounded()))
                    return unsure ? L10n.text("transcript.word.unsure", at, percent) : L10n.text("transcript.word.sure", at, percent)
                } ?? L10n.text("transcript.word.at", at)
                if filler { tip += "\n" + L10n.text("transcript.word.filler") }
                attrs[.toolTip] = tip
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

    /// The word under the playhead gets a soft neon background while playing. In the short gaps between words it
    /// stays on the word just said (LitWord: no blinking four to six times a second in fast speech).
    private func lightPlayingWord() {
        guard let lm = textView.layoutManager else { return }
        let i = session.isPlaying
            ? LitWord.index(at: session.playhead, starts: wordStarts, ends: wordEnds, lit: litWord, bridge: session.project.frames(1.0 / 3))
            : nil
        guard i != litWord else { return }
        if let old = litWord, old < ranges.count { lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: ranges[old]) }
        litWord = i
        if let i, i < ranges.count {
            lm.addTemporaryAttribute(.backgroundColor, value: Theme.neon.withAlphaComponent(0.28), forCharacterRange: ranges[i])
            // Follow the playing word, unless the reader scrolled in the last 5 s (or since playback began).
            // With Reduce Motion the text moves only when the word would leave the view, not with every word.
            let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let shown = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: ranges[i], actualCharacterRange: nil), in: textView.textContainer!)
                .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
            if readerScrolledAt.map({ Date().timeIntervalSince($0) > 5 }) ?? true, !reduce || !textView.visibleRect.contains(shown) {
                scrollingToWord = true
                textView.scrollRangeToVisible(ranges[i])
                scrollingToWord = false
            }
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
        // No timeline selection, or none over a word: no words stay highlighted (Delete would take them).
        func clear() {
            let now = textView.selectedRange()
            guard now.length > 0 else { return }
            updatingSelection = true
            textView.setSelectedRange(NSRange(location: now.location, length: 0))
            updatingSelection = false
        }
        guard let sel = session.selection, !placed.isEmpty else { clear(); return }
        let inside = placed.indices.filter { placed[$0].start < sel.upperBound && placed[$0].end > sel.lowerBound }
        guard let first = inside.first, let last = inside.last else { clear(); return }
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
        // Only spaces or a speaker's name: no word, so no audio is selected either.
        guard let first = idx.first, let last = idx.last else { session.selection = nil; return }
        session.selection = placed[first].start..<placed[last].end
    }

    /// Delete: the selected words go, with the pauses between them.
    func deleteSelectedWords() {
        let ids = selectedWordIndices().map { JSONValue.string(placed[$0].word.id.uuidString) }
        guard !ids.isEmpty else { session.say(L10n.text("reason.selectWord"), .info); return }
        session.perform("delete_words", ["words": .array(ids), "bridge": .number(0.3)])
    }

    /// The line under an empty transcript says where it will be transcribed; the choice is kept for next time, and
    /// the languages it can't do are greyed out, saying why.
    @objc func engineChanged(_ sender: Any?) {
        UserDefaults.standard.set(selectedEngine.rawValue, forKey: "transcript.engine")
        languageChanged(nil)
        refresh()
    }

    @objc func languageChanged(_ sender: Any?) {
        let allowed = selectedEngine.languages
        for item in language.itemArray {
            let code = String((item.representedObject as? String ?? "").prefix(2))
            let ok = allowed?.contains(code) ?? true
            item.isEnabled = ok
            item.toolTip = ok ? nil : L10n.text("transcript.language.notForEngine", engine.titleOfSelectedItem ?? "")
        }
        // A language the engine can't do isn't left chosen.
        if language.selectedItem?.isEnabled == false, let i = language.itemArray.firstIndex(where: \.isEnabled) { language.selectItem(at: i) }
    }

    @objc private func textScrolled(_ note: Notification) {
        if !scrollingToWord, !updatingSelection { readerScrolledAt = Date() }
    }

    /// ⌘+ and ⌘− while the transcript has the keys; ⌘0 back to 14 pt.
    func changeTextSize(by step: CGFloat?) {
        let size = step.map { min(28, max(10, textSize + $0)) } ?? 14
        guard size != textSize else { return }
        textSize = size
        UserDefaults.standard.set(Double(size), forKey: "transcript.textSize")
        shown = nil
        shownVersion = -1
        rebuild()
        lightPlayingWord()
        mirrorSelection()
    }

    /// The grip at the top edge: up makes the panel taller, leaving the timeline at least 180 pt.
    private func dragHeight(by dy: CGFloat) {
        let room = (superview?.bounds.height ?? 800) - 300
        heightConstraint.constant = min(max(110, room), max(110, heightConstraint.constant + dy))
    }

    /// Double-click or Return on a word: Edit › Correct Word for it.
    func correctSelectedWord() {
        guard !selectedWordIndices().isEmpty else { return }
        NSApp.sendAction(#selector(EditorWindowController.correctWord(_:)), to: nil, from: textView)
    }

    /// The find bar (⌘F), or the next match (⌘G).
    func showFind(next: Bool) {
        window?.makeFirstResponder(textView)
        let action = NSMenuItem()
        action.tag = (next ? NSTextFinder.Action.nextMatch : NSTextFinder.Action.showFindInterface).rawValue
        textView.performTextFinderAction(action)
    }

    @objc func transcribe(_ sender: Any?) {
        if let job = JobRegistry.shared.latest("transcribe", document: session.agentID), !job.isFinished {
            JobRegistry.shared.stop(job.id, in: session)
            return
        }
        let code = language.selectedItem?.representedObject as? String ?? "sv-SE"
        UserDefaults.standard.set(code, forKey: "transcript.language")
        let locale = Locale(identifier: code)
        switch selectedEngine {
        case .openai:
            guard !asking else { return }
            asking = true
            Task { await transcribeAtOpenAI(locale); asking = false }
        case .bergetPianissimo:
            guard !asking else { return }
            asking = true
            Task { await transcribeAtBerget(locale); asking = false }
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
        alert.returnNeverPays()
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
        alert.returnNeverPays()
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
        // Return corrects the selected word, as a double-click does.
        if event.keyCode == 36 || event.keyCode == 76 {
            MainActor.assumeIsolated { panel?.correctSelectedWord() }
            return
        }
        // Space plays and stops, as on the timeline.
        if event.charactersIgnoringModifiers == " " {
            MainActor.assumeIsolated { panel?.session.togglePlay() }
            return
        }
        super.keyDown(with: event)
    }

    /// Edit › Delete and Cut act on the selected words' audio here too (the text view is read-only, so its own
    /// versions were grey while words were selected). Copy stays the text's.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { MainActor.assumeIsolated { panel?.correctSelectedWord() } }
    }

    /// View › Zoom In, Zoom Out and Zoom to Fit act on what has the keys: here, the text's size.
    @objc func zoomIn(_ sender: Any?) { MainActor.assumeIsolated { panel?.changeTextSize(by: 2) } }
    @objc func zoomOut(_ sender: Any?) { MainActor.assumeIsolated { panel?.changeTextSize(by: -2) } }
    @objc func zoomToFit(_ sender: Any?) { MainActor.assumeIsolated { panel?.changeTextSize(by: nil) } }

    @objc override func delete(_ sender: Any?) { MainActor.assumeIsolated { panel?.deleteSelectedWords() } }
    @objc override func cut(_ sender: Any?) { MainActor.assumeIsolated { panel?.session.perform("cut") } }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(delete(_:)) || item.action == #selector(cut(_:)) {
            let ok = MainActor.assumeIsolated { panel?.session.selection != nil }
            item.toolTip = ok ? nil : L10n.text("reason.selectWord")
            return ok
        }
        return super.validateMenuItem(item)
    }

    /// A word's context menu: the registry's word commands (Correct, Delete, Remove Filler Words, Overdub…),
    /// named and checked as in the menu bar, with Copy for the text.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = CommandCenter.contextMenu(.word)
        menu.insertItem(.separator(), at: 0)
        menu.insertItem(NSMenuItem(title: L10n.text("edit.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: ""), at: 0)
        return menu
    }
}

/// The transcript panel's top edge, dragged to make it taller or shorter.
final class ResizeGrip: NSView {
    private let drag: (CGFloat) -> Void
    private let ended: () -> Void
    private var last: CGFloat?

    init(drag: @escaping (CGFloat) -> Void, ended: @escaping () -> Void) {
        self.drag = drag
        self.ended = ended
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 1, alpha: 0.08).setFill()
        NSRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1).fill()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }

    override func mouseDown(with event: NSEvent) { last = NSEvent.mouseLocation.y }

    override func mouseDragged(with event: NSEvent) {
        let y = NSEvent.mouseLocation.y
        if let last { drag(y - last) }
        last = y
    }

    override func mouseUp(with event: NSEvent) {
        last = nil
        ended()
    }
}
