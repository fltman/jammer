import AppKit
import JammerCore
import JammerSpeech

/// Overdub in the window and for the agent API: the same steps (OverdubService), in the order the series' rule 9
/// asks for. The user's own ElevenLabs key, in the Keychain (account "elevenlabs").
extension EditorSession {
    static func elevenLabs() -> ElevenLabs { ElevenLabs(key: { Keychain.get("elevenlabs") }) }

    /// Checks the attestation and the consent (nothing leaves the Mac until they hold), clones the voice from
    /// `samples`, and keeps it in the document with its record: one undo step.
    func cloneVoice(name: String, kind: VoiceAttestation.Kind?, adult: Bool, consent: ClosedRange<Double>,
                    samples: [ClosedRange<Double>]) async throws -> (ClonedVoice, needsVerification: Bool) {
        let (attestation, files) = try OverdubService.prepareClone(project, plan: plan, kind: kind, adult: adult, consent: consent, samples: samples)
        guard Keychain.get("elevenlabs") != nil else { throw ElevenLabs.NoKey() }
        let made = try await OverdubService(provider: Self.elevenLabs()).clone(name: name, attestation: attestation, samples: samples, files: files)
        // No stop check here on purpose: a voice ElevenLabs has made is always kept on record, so that it can be
        // deleted from Jämmer rather than left behind in the account.
        var p = project
        p.voices.append(made.0)
        commit(p, action: L10n.text("overdub.undo.clone", name))
        return made
    }

    /// Says `text` in `voice` and puts it in place of `range` on `track`: one undo step.
    func overdub(voice: ClonedVoice, range: Range<Frame>, text: String, model: String, track: Int) async throws -> SourceRef {
        let p0 = project
        let trackID = p0.tracks[track].id
        let before = p0.placedWords(in: max(0, range.lowerBound - p0.frames(10))..<range.lowerBound).map(\.word.text).joined(separator: " ")
        let after = p0.placedWords(in: range.upperBound..<min(p0.length, range.upperBound + p0.frames(10))).map(\.word.text).joined(separator: " ")
        let source = try await OverdubService(provider: Self.elevenLabs()).speak(voice, text: text, model: model, previous: before, next: after,
                                                                                 sampleRate: p0.sampleRate, folder: MediaStore.folder)
        // Stopped while the answer came: the speech is not put in (it was paid for; the caller says so).
        try Task.checkCancellation()
        var p = project
        // The place changed while the speech was made (paid): it goes on a new muted track there as a take, and nothing
        // made meanwhile is touched (COMFORT 59, 77).
        guard p.unchanged(range, track: trackID, since: p0), let i = p.tracks.firstIndex(where: { $0.id == trackID }) else {
            p.addTake(source, at: range.lowerBound, name: L10n.text("overdub.take"))
            commit(p, action: L10n.text("overdub.undo.overdub"))
            say(L10n.text("overdub.keptAsTake"), .warning)
            return source
        }
        try p.overdub(range, track: i, with: source, words: text, language: p.transcripts.first?.language ?? "en")
        commit(p, action: L10n.text("overdub.undo.overdub"))
        return source
    }

    /// Deletes the voice at the provider; the record of its consent stays, marked deleted.
    func deleteVoice(_ id: UUID) async throws {
        guard let v = project.voices.first(where: { $0.id == id }), v.deleted == nil else { return }
        try await Self.elevenLabs().delete(voiceID: v.providerVoiceID)
        var p = project
        if let i = p.voices.firstIndex(where: { $0.id == id }) { p.voices[i].deleted = Date() }
        commit(p, action: L10n.text("overdub.undo.delete", v.name))
    }

    /// The track that has sound where `t` is.
    func speechTrack(at t: Frame) -> Int? { project.tracks.firstIndex { $0.clips.contains { $0.start <= t && $0.end > t } } }

    /// What went wrong, in the window's words.
    static func overdubProblem(_ e: Error) -> String {
        if let o = e as? OverdubError { return L10n.error(o) }
        if e is ElevenLabs.NoKey { return L10n.text("overdub.noKey") }
        if let f = e as? ElevenLabs.Failure { return f.status == 401 ? L10n.text("overdub.keyRejected") : L10n.text("overdub.providerSaid", String(f.status), f.message) }
        return e.localizedDescription
    }
}

extension EditorWindowController {
    private func label(_ text: String, width: CGFloat = 380, small: Bool = true) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        if small { l.font = .systemFont(ofSize: NSFont.smallSystemFontSize) }
        l.preferredMaxLayoutWidth = width
        l.frame.size = l.sizeThatFits(NSSize(width: width, height: 600))
        return l
    }

    /// Audio › Clone Voice…: the selection is where the person says the consent sentence.
    @objc func cloneVoice(_ sender: Any?) {
        Task { await askToClone() }
    }

    private func askToClone() async {
        let p = session.project
        guard !p.transcripts.isEmpty else { session.say(L10n.error(OverdubError.noTranscript), .error); return }
        let sentence = Overdub.consentSentence(language: p.transcripts.first?.language ?? "en")
        guard let sel = session.selection else { session.say(L10n.text("overdub.clone.selectConsent", sentence), .error); return }
        let consent = p.seconds(sel.lowerBound)...p.seconds(sel.upperBound)
        let samples = p.voiceSamples(around: consent)

        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        name.placeholderString = L10n.text("overdub.clone.name")
        name.setAccessibilityLabel(L10n.text("overdub.clone.name"))
        name.setAccessibilityIdentifier("overdub.clone.name")
        let whose = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 380, height: 26))
        whose.addItems(withTitles: [L10n.text("overdub.clone.whose.choose"), L10n.text("overdub.clone.whose.own"), L10n.text("overdub.clone.whose.consent")])
        whose.setAccessibilityLabel(L10n.text("overdub.clone.whose.ax"))
        whose.setAccessibilityIdentifier("overdub.clone.whose")
        let adult = NSButton(checkboxWithTitle: L10n.text("overdub.clone.adult"), target: nil, action: nil)
        adult.setAccessibilityIdentifier("overdub.clone.adult")
        adult.sizeToFit()
        let said = label(L10n.text("overdub.clone.heard", sentence))
        let total = samples.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        let sends = label(L10n.text("overdub.clone.sends", L10n.number(total, 0), L10n.count("overdub.clone.pieces", samples.count)))
        let terms = label(L10n.text("overdub.terms"))
        let unknown = UnknownPriceBox(service: "elevenlabs", name: "ElevenLabs")

        let alert = NSAlert()
        alert.messageText = L10n.text("overdub.clone.title")
        alert.informativeText = L10n.text("overdub.clone.text")
        alert.addButton(withTitle: L10n.text("button.send"))
        alert.addButton(withTitle: L10n.text("button.cancel"))
        alert.returnNeverPays()
        UnknownPriceBox.place([name, whose, adult, said, sends, terms, unknown.view], in: alert)
        unknown.gate(alert.buttons[0])
        let answer: NSApplication.ModalResponse
        if let w = window { answer = await alert.beginSheetModal(for: w) } else { answer = alert.runModal() }
        guard answer == .alertFirstButtonReturn else { return }
        unknown.sent()
        let kind: VoiceAttestation.Kind? = whose.indexOfSelectedItem == 1 ? .own : whose.indexOfSelectedItem == 2 ? .ownerConsent : nil
        let who = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        session.say(L10n.text("overdub.clone.working"), .progress)
        // The request can be stopped from the status bar (COMFORT 7); once it has gone, ElevenLabs may already have
        // made the voice and charged, and the line says so.
        let session = self.session, isAdult = adult.state == .on, voiceName = who.isEmpty ? L10n.text("overdub.clone.unnamed") : who
        let request = Task { try await session.cloneVoice(name: voiceName, kind: kind, adult: isAdult, consent: consent, samples: samples) }
        let wait = session.beginWait(L10n.text("overdub.clone.working")) { request.cancel() }
        defer { session.endWait(wait) }
        do {
            let (voice, verify) = try await request.value
            session.say(verify ? L10n.text("overdub.clone.verify", voice.name) : L10n.text("overdub.clone.done", voice.name), verify ? .warning : .success)
        } catch where request.isCancelled {
            session.say(L10n.text("overdub.clone.stopped"), .warning)
        } catch {
            session.say(EditorSession.overdubProblem(error), .error)
        }
    }

    /// Audio › Overdub…: the selected words said again, in a cloned voice.
    @objc func overdubSelection(_ sender: Any?) {
        Task { await askToOverdub() }
    }

    private func askToOverdub() async {
        let p = session.project
        let voices = p.voices.filter { $0.deleted == nil }
        guard let first = voices.first else { session.say(L10n.text("overdub.noVoice"), .error); return }
        guard let sel = session.selection, let track = session.speechTrack(at: sel.lowerBound) else { session.say(L10n.text("overdub.selectWords"), .error); return }
        let pick = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        pick.addItems(withTitles: voices.map(\.name))
        pick.setAccessibilityLabel(L10n.text("overdub.voice.ax"))
        pick.setAccessibilityIdentifier("overdub.voice")
        let model = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        model.addItems(withTitles: Overdub.models)
        model.setAccessibilityLabel(L10n.text("overdub.model.ax"))
        let text = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 60))
        text.stringValue = p.placedWords(in: sel).map(\.word.text).joined(separator: " ")
        text.setAccessibilityLabel(L10n.text("overdub.text.ax"))
        text.setAccessibilityIdentifier("overdub.text")
        let note = label(L10n.text("overdub.ask.note"))
        let unknown = UnknownPriceBox(service: "elevenlabs", name: "ElevenLabs")
        let alert = NSAlert()
        alert.messageText = L10n.text("overdub.ask.title")
        alert.informativeText = L10n.text("overdub.ask.text", L10n.number(p.seconds(sel.lowerBound), 2), L10n.number(p.seconds(sel.upperBound), 2))
        alert.addButton(withTitle: L10n.text("button.send"))
        alert.addButton(withTitle: L10n.text("button.cancel"))
        alert.returnNeverPays()
        UnknownPriceBox.place([pick, text, model, note, unknown.view], in: alert)
        unknown.gate(alert.buttons[0])
        let answer: NSApplication.ModalResponse
        if let w = window { answer = await alert.beginSheetModal(for: w) } else { answer = alert.runModal() }
        guard answer == .alertFirstButtonReturn else { return }
        unknown.sent()
        let voice = voices.indices.contains(pick.indexOfSelectedItem) ? voices[pick.indexOfSelectedItem] : first
        session.say(L10n.text("overdub.working", voice.name), .progress)
        let session = self.session, words = text.stringValue, chosenModel = model.titleOfSelectedItem ?? Overdub.models[0]
        let request = Task { try await session.overdub(voice: voice, range: sel, text: words, model: chosenModel, track: track) }
        let wait = session.beginWait(L10n.text("overdub.working", voice.name)) { request.cancel() }
        defer { session.endWait(wait) }
        do {
            _ = try await request.value
            session.say(L10n.text("overdub.done", voice.name), .success)
        } catch where request.isCancelled {
            session.say(L10n.text("job.mayHaveBeenCharged", "ElevenLabs"), .warning)
        } catch {
            session.say(EditorSession.overdubProblem(error), .error)
        }
    }

    /// Audio › Delete Cloned Voice…: at the provider; the record of consent stays.
    @objc func deleteClonedVoice(_ sender: Any?) {
        Task {
            let voices = session.project.voices.filter { $0.deleted == nil }
            guard !voices.isEmpty else { session.say(L10n.text("overdub.noVoice"), .error); return }
            let pick = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
            pick.addItems(withTitles: voices.map(\.name))
            pick.setAccessibilityLabel(L10n.text("overdub.voice.ax"))
            let alert = NSAlert()
            alert.messageText = L10n.text("overdub.delete.title")
            alert.informativeText = L10n.text("overdub.delete.text")
            alert.addButton(withTitle: L10n.text("overdub.delete.button"))
            alert.addButton(withTitle: L10n.text("button.cancel"))
            alert.returnNeverPays()
            alert.accessoryView = pick
            let answer: NSApplication.ModalResponse
            if let w = window { answer = await alert.beginSheetModal(for: w) } else { answer = alert.runModal() }
            guard answer == .alertFirstButtonReturn, voices.indices.contains(pick.indexOfSelectedItem) else { return }
            let v = voices[pick.indexOfSelectedItem]
            do { try await session.deleteVoice(v.id); session.say(L10n.text("overdub.delete.done", v.name), .success) }
            catch { session.say(EditorSession.overdubProblem(error), .error) }
        }
    }
}
