import AppKit
import JammerAgent
import JammerCore

/// The commands the registry added to the window (the comfort block, 2026-11-25): the ones the sweep found
/// missing from the menus though an operation existed (Deselect All, Correct Word, Remove Filler Words, Find in
/// the transcript, markers, the Track menu), and focus mode.
extension EditorWindowController {
    @objc func deselectAllCommand(_ sender: Any?) { session.perform("deselect") }

    /// Edit › Find in Transcript (⌘F): the transcript's find bar, which ignores case and accents.
    @objc func findInTranscript(_ sender: Any?) {
        if transcript.isHidden { toggleTranscript(nil) }
        transcript.showFind(next: false)
    }

    @objc func findNextInTranscript(_ sender: Any?) {
        if transcript.isHidden { toggleTranscript(nil) }
        transcript.showFind(next: true)
    }

    /// Edit › Correct Word…: the first selected word, its text changed as one undo step.
    @objc func correctWord(_ sender: Any?) {
        guard let window, let word = session.project.placedWords(in: session.selection).first else { return }
        let field = NSTextField(string: word.word.text)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        let alert = NSAlert()
        alert.messageText = L10n.text("edit.correctWord.title")
        alert.informativeText = L10n.text("edit.correctWord.text", word.word.text)
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.text("button.ok"))
        alert.addButton(withTitle: L10n.text("button.cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] answer in
            let text = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard answer == .alertFirstButtonReturn, !text.isEmpty, text != word.word.text else { return }
            self?.session.perform("correct_word", ["word": .string(word.word.id.uuidString), "text": .string(text)])
        }
        // The field has the keys at once, with the word selected, so typing replaces it (an alert's own layout
        // otherwise gives the first button the focus).
        alert.window.makeFirstResponder(field)
        field.selectText(nil)
    }

    /// Edit › Remove Filler Words: every eh, ehm, öh… the transcript has, deleted from the audio as one step.
    @objc func removeFillerWords(_ sender: Any?) {
        let fillers = session.project.placedWords().filter {
            Project.fillerWords.contains($0.word.text.lowercased().trimmingCharacters(in: .punctuationCharacters))
        }
        guard !fillers.isEmpty else { session.say(L10n.text("edit.removeFillers.none"), .info); return }
        session.perform("delete_words", ["words": .array(fillers.map { .string($0.word.id.uuidString) })])
    }

    /// View › Focus Mode: the side panels hidden, the timeline and the omnibar kept; again to bring them back.
    @objc func toggleFocusMode(_ sender: Any?) {
        guard let split = window?.contentView as? NSSplitView, split.arrangedSubviews.count > 1 else { return }
        let assistantPanel = split.arrangedSubviews[1]
        if let before = focusMode {
            assistantPanel.isHidden = !before.assistant
            if before.assistant { split.setPosition(split.frame.width - 320, ofDividerAt: 0) }
            transcript.isHidden = !before.transcript
            toolPaletteView?.isHidden = !before.palette
            focusMode = nil
        } else {
            focusMode = (!assistantPanel.isHidden, !transcript.isHidden, !(toolPaletteView?.isHidden ?? true))
            assistantPanel.isHidden = true
            transcript.isHidden = true
            toolPaletteView?.isHidden = true
        }
    }

    /// A tool chosen from the palette, View › Tool or its letter. A spectral tool shows the spectrogram, any other
    /// the waveform: each tool works where it can act.
    func chooseTool(_ id: String) {
        guard let t = Commands.tools.first(where: { $0.id == id }) else { return }
        if t.spectral, !Operations.spectralFreeform, id != "box" { NSSound.beep(); return }
        session.tool = id
        if t.spectral != timeline.showsSpectrogram { toggleSpectrogram(nil) }
        session.status = L10n.text("tool.help", L10n.text(t.title), t.letter.uppercased())
        timeline.overlayNeedsDisplay()
    }

    @objc func chooseToolCommand(_ sender: Any?) {
        if let id = (sender as? NSMenuItem)?.representedObject as? String { chooseTool(id) }
    }

    @objc func toggleToolPalette(_ sender: Any?) {
        guard let v = toolPaletteView else { return }
        v.isHidden.toggle()
        UserDefaults.standard.set(!v.isHidden, forKey: "toolPalette.visible")
        (sender as? NSMenuItem)?.title = L10n.text(v.isHidden ? "view.toolPalette" : "view.hideToolPalette")
    }

    /// Edit › Stop Job: the newest job this document runs; the others go on.
    @objc func stopJob(_ sender: Any?) {
        if let wait = session.shownWaits.last { wait.stop(); return }
        guard let job = JobRegistry.shared.running(document: session.agentID).last else { return }
        JobRegistry.shared.stop(job.id, in: session)
    }

    /// Edit › Split at Playhead (⌘B): every track's clip under the playhead in two.
    @objc func splitAtPlayhead(_ sender: Any?) { session.perform("split") }

    @objc func transcribeCommand(_ sender: Any?) {
        if transcript.isHidden { toggleTranscript(nil) }
        transcript.transcribe(nil)
    }

    @objc func goToEnd(_ sender: Any?) { session.seek(session.project.length) }

    @objc func previousMarker(_ sender: Any?) {
        let at = session.playhead
        if let m = session.project.markers.map(\.position).filter({ $0 < at }).max() { session.seek(m) }
    }

    @objc func nextMarker(_ sender: Any?) {
        let at = session.playhead
        if let m = session.project.markers.map(\.position).filter({ $0 > at }).min() { session.seek(m) }
    }

    /// Track › Rename Track…
    @objc func renameTrack(_ sender: Any?) {
        guard let window, let track = currentTrack else { return }
        let field = NSTextField(string: track.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        let alert = NSAlert()
        alert.messageText = L10n.text("track.rename.title")
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.text("button.ok"))
        alert.addButton(withTitle: L10n.text("button.cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] answer in
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard answer == .alertFirstButtonReturn, !name.isEmpty, name != track.name else { return }
            self?.session.perform("set_track", ["track": .string(track.id.uuidString), "name": .string(name)])
        }
    }

    @objc func toggleTrackMute(_ sender: Any?) {
        guard let track = currentTrack else { return }
        session.perform("set_track", ["track": .string(track.id.uuidString), "muted": .bool(!track.isMuted)])
    }

    @objc func toggleTrackLock(_ sender: Any?) {
        guard let track = currentTrack else { return }
        session.perform("set_track", ["track": .string(track.id.uuidString), "locked": .bool(!track.locked)])
    }

    @objc func duplicateTrack(_ sender: Any?) {
        guard let track = currentTrack else { return }
        session.perform("duplicate_track", ["track": .string(track.id.uuidString), "name": .string(L10n.text("track.copyName", track.name))])
    }

    @objc func moveTrackUp(_ sender: Any?) { moveTrack(by: -1) }
    @objc func moveTrackDown(_ sender: Any?) { moveTrack(by: 1) }
    private func moveTrack(by n: Int) {
        guard let track = currentTrack else { return }
        session.perform("move_track", ["track": .string(track.id.uuidString), "by": .number(Double(n))])
    }

    /// Track › Delete Track: one undo step, so it isn't asked about (⌘Z brings it back with everything on it).
    @objc func deleteTrack(_ sender: Any?) {
        guard let track = currentTrack else { return }
        session.perform("remove_track", ["track": .string(track.id.uuidString)], saying: L10n.text("track.deleted", track.name))
    }

    /// Solo is a way of listening, not part of the document: never an undo step.
    @objc func toggleTrackSolo(_ sender: Any?) {
        guard let track = currentTrack else { return }
        var s = session.solo
        if s.contains(track.id) { s.remove(track.id) } else { s.insert(track.id) }
        session.setSolo(s)
    }
}
