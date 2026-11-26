import AppKit
import AVFoundation
import JammerAgent
import JammerAudio
import JammerCore

/// A recording going on now: where its takes go, what of each file comes first, and when it stops by itself.
struct RecordingNow {
    /// Where the takes go on the timeline: the punch-in, or the playhead.
    var start: Frame
    var since: Date
    /// Played before the punch-in, and the input's own delay: skipped at the head of each file.
    var sourceStart: Frame
    /// A punch: the takes are this long, and the recording stops by itself just after.
    var length: Frame?
    var documentID: UUID
    var warnedRoom = false
}

/// Recording in the window (the sketch the coordinator approved, 2026-11-25): tracks armed in their headers, each with
/// its input, their input meters, Transport › Record (⌘R) and Stop, a steady indicator; a selection is a punch, played
/// into from a pre-roll; every take over a stretch is kept and one chosen (a clip's menu lists them); a journal under
/// the document's id brings the takes back after a crash. Only the person in the window arms, records, deletes a take
/// or opens the microphone: the agent API reads the state and chooses among takes (set_take), nothing else (SIBLINGS §5).
extension EditorSession {
    /// The Debug-only test input (`-testInput sine|silence`): recording without a device, never asking for the microphone.
    static var testInput: Recorder.Source? {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "testInput") {
        case "sine": return .sine
        case "silence": return .silence
        default: return nil
        }
        #else
        return nil
        #endif
    }

    /// Played before a punch-in, so the take starts in time with what came before it (seconds; 2 unless set).
    static var prerollSeconds: Double {
        let v = UserDefaults.standard.double(forKey: "recordPreroll")
        return v > 0 ? min(v, 10) : 2
    }

    /// Where unfinished recordings' journals are kept.
    static var journalFolder: URL { AppData.folder.appending(path: "Recording") }

    /// Arms a track, or disarms it. The first arm finds the input: the test input, or the Mac's default input device at
    /// the document's sample rate, after macOS's microphone question (asked once, answered by the user).
    func toggleArm(_ track: UUID) async {
        if armed[track] != nil {
            armed[track] = nil
            rearm()
            return
        }
        guard recording == nil else { say(L10n.text("record.armWhileRecording"), .info); return }
        if let t = project.tracks.first(where: { $0.id == track }), t.locked { say(L10n.text("record.locked", t.name), .info); return }
        if recorder == nil {
            guard let made = await makeRecorder() else { return }
            recorder = made
        }
        guard let r = recorder else { return }
        // The next input channel nobody has, one channel; the menu beside the button changes it.
        let used = Set(armed.values.map(\.first))
        let first = (0..<r.deviceChannels).first { !used.contains($0) } ?? 0
        armed[track] = Recorder.Arm(track: track, first: first, channels: 1)
        rearm()
    }

    /// The input of an armed track: channel `first` (0-based), one or two channels.
    func setInput(_ track: UUID, first: Int, channels: Int) {
        guard armed[track] != nil else { return }
        armed[track] = Recorder.Arm(track: track, first: first, channels: channels)
        rearm()
    }

    private func rearm() {
        guard let r = recorder else { return }
        let arms = project.tracks.compactMap { armed[$0.id] }
        do {
            try r.arm(arms)
        } catch {
            armed = [:]
            say(L10n.error(error), .error)
        }
        if arms.isEmpty { recorder = nil }
    }

    private func makeRecorder() async -> Recorder? {
        if let test = Self.testInput { inputLatency = 0; return Recorder(source: test, deviceChannels: 2, sampleRate: project.sampleRate) }
        guard let device = InputDevices.defaultDevice() else { say(L10n.text("record.noInput"), .error); return nil }
        guard device.sampleRate == project.sampleRate else {
            say(L10n.text("record.rate", device.name, L10n.number(device.sampleRate, 0), L10n.number(project.sampleRate, 0)), .error)
            return nil
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            Recorder.noteDeviceRequest()
            guard await AVCaptureDevice.requestAccess(for: .audio) else { say(L10n.text("record.denied"), .error); return nil }
        default:
            say(L10n.text("record.denied"), .error)
            return nil
        }
        inputLatency = Frame(device.latency)
        return Recorder(source: .device(device.id), deviceChannels: device.channels, sampleRate: project.sampleRate)
    }

    nonisolated private static func freeSpace(_ folder: URL) -> Int64? {
        (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    private var armedChannels: Int { armed.values.reduce(0) { $0 + $1.channels } }

    /// Why Record can't start now, or nil.
    var recordRefusal: String? {
        if recording != nil { return nil }
        if armed.isEmpty { return L10n.text("reason.armFirst") }
        if let free = Self.freeSpace(MediaStore.folder), CaptureWriter.secondsLeft(free: free, channels: armedChannels, sampleRate: project.sampleRate) < 120 {
            return L10n.text("record.noRoom")
        }
        return nil
    }

    /// Transport › Record: every armed track records while the others play; again (or Space) to stop. With a
    /// selection it is a punch: played from a pre-roll before it, the takes as long as the selection, stopped by itself.
    func toggleRecording() {
        if recording != nil { stopRecording(); return }
        if let why = recordRefusal { say(why, .error); NSSound.beep(); return }
        guard let r = recorder else { return }
        let punch = selection.flatMap { $0.isEmpty ? nil : $0 }
        let start = punch?.lowerBound ?? playhead
        let playFrom = punch.map { max(0, $0.lowerBound - Frame(Self.prerollSeconds * project.sampleRate)) } ?? start
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stamp = f.string(from: Date())
        let folder = MediaStore.folder
        let names = Dictionary(uniqueKeysWithValues: project.tracks.map { ($0.id, FileNames.safe("\($0.name) \(stamp)", ext: "wav")) })
        let id = documentIdentity()
        let sourceStart = (start - playFrom) + inputLatency
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try r.record(into: folder, name: { names[$0] ?? FileNames.safe("Take \(stamp)", ext: "wav") }, freeSpace: { Self.freeSpace(folder) }) { [weak self] ending in
                Task { @MainActor in self?.stopRecording(ending) }
            }
        } catch {
            say(L10n.error(error), .error)
            return
        }
        // The journal: a crash from here on loses at most the last second (the writer's checkpoints).
        let journal = RecordingJournal(documentID: id, documentPath: document?.fileURL?.path,
                                       takes: r.armed.map { .init(track: $0.track, path: folder.appending(path: names[$0.track] ?? "").path, channels: $0.channels) },
                                       at: start, sourceStart: sourceStart, length: punch.map { $0.upperBound - $0.lowerBound },
                                       sampleRate: project.sampleRate, started: Date())
        do { try journal.write(in: Self.journalFolder) } catch { say(L10n.text("record.noJournal", error.localizedDescription), .warning) }
        recording = RecordingNow(start: start, since: Date(), sourceStart: sourceStart, length: journal.length, documentID: id)
        play(from: playFrom)
        recordTimer?.invalidate()
        recordTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordingTick() }
        }
    }

    /// Four times a second while recording: the punch-out, the disk's last ten minutes said once, and the playhead
    /// where nothing plays.
    private func recordingTick() {
        guard let rec = recording, let r = recorder else { recordTimer?.invalidate(); recordTimer = nil; return }
        // Past the document's end, or in a new document, there is nothing to play and playback stops at once: the
        // playhead follows what has been recorded instead, so the take is seen to grow where it will lie.
        if !isPlaying { playhead = rec.start + max(0, Frame(r.recordedFrames) - rec.sourceStart) }
        if let length = rec.length, r.recordedFrames >= Int64(rec.sourceStart + length + Frame(0.2 * project.sampleRate)) {
            stopRecording()
            return
        }
        if !rec.warnedRoom, let free = Self.freeSpace(MediaStore.folder),
           CaptureWriter.secondsLeft(free: free, channels: armedChannels, sampleRate: project.sampleRate) < 600 {
            recording?.warnedRoom = true
            say(L10n.text("record.room10"), .warning)
        }
    }

    /// Ends the recording: the takes go onto their tracks as one undo step, each kept among the takes of its stretch.
    func stopRecording(_ ending: CaptureWriter.Ending? = nil) {
        guard let rec = recording, let r = recorder else { return }
        recording = nil
        recordTimer?.invalidate()
        recordTimer = nil
        if isPlaying { stop() }
        guard let (takes, end) = r.stopRecording() else { return }
        var p = project
        var dropped: Int64 = 0, laid = 0
        for take in takes where take.frames > 0 {
            guard let info = try? AudioFileReader.info(at: take.url) else { continue }
            let usable = Frame(info.frames) - rec.sourceStart
            guard usable > 0 else { continue }
            let source = SourceRef(name: take.url.deletingPathExtension().lastPathComponent, path: take.url.path, info: info)
            let frames = rec.length.map { min($0, usable) } ?? usable
            if (try? p.recordTake(source, frames: frames, at: rec.start, onTrack: take.track, sourceStart: rec.sourceStart)) != nil { laid += 1 }
            dropped += take.dropped
        }
        commit(p, action: L10n.text("record.action"))
        StorageScanner.note(self)
        RecordingJournal.remove(rec.documentID, in: Self.journalFolder)
        switch ending ?? end {
        case .diskFull: say(L10n.text("record.diskFull", formatTime(Double(takes.first?.frames ?? 0) / project.sampleRate)), .warning)
        case .failed(let why): say(L10n.text("record.failed", why), .error)
        case .stopped where dropped > 0: say(L10n.text("record.dropped", L10n.number(Double(dropped) / project.sampleRate * 1_000, 0)), .warning)
        case .stopped: say(L10n.count("record.done", laid), .success)
        }
    }

    /// The indicator's time, m:ss (whole seconds: the indicator stays still between them).
    static func recordedTime(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3_600 ? String(format: "%d:%02d:%02d", s / 3_600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// The input meter of an armed track (linear peak since the meters last looked).
    func inputPeak(_ track: UUID) -> Float? { armed[track] != nil ? recorder?.peak(track) : nil }

    // MARK: Takes

    /// The takes of the stretch a clip belongs to: it plays one of them, or lies where they were recorded.
    func takeGroup(ofClip id: UUID) -> (track: Track, group: TakeGroup)? {
        guard let (t, i) = project.clipLocation(id) else { return nil }
        let track = project.tracks[t], clip = track.clips[i]
        guard let g = track.takes.first(where: { g in g.takes.contains { $0.sourceID == clip.sourceID } })
                ?? track.takes.first(where: { $0.start < clip.end && $0.end > clip.start }) else { return nil }
        return (track, g)
    }

    /// A clip's menu, with its takes when it was recorded more than once: each one to choose (the chosen checked),
    /// and Delete Take for the one playing (in the window only).
    func addTakeItems(to menu: NSMenu, clip: UUID) {
        guard let (track, g) = takeGroup(ofClip: clip), !g.takes.isEmpty else { return }
        menu.addItem(.separator())
        let header = NSMenuItem(title: L10n.text("take.menu"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for take in g.takes.sorted(by: { $0.number < $1.number }) {
            let item = ClosureMenuItem(L10n.text("take.item", String(take.number), formatTime(Double(take.length) / project.sampleRate))) { [weak self] in
                self?.perform("set_take", ["track": .string(track.id.uuidString), "group": .string(g.id.uuidString), "take": .string(take.id.uuidString)],
                              saying: L10n.text("take.chosen", String(take.number)))
            }
            item.state = take.id == g.chosen ? .on : .off
            item.isEnabled = !track.locked
            menu.addItem(item)
        }
        if let chosen = g.chosenTake {
            let delete = ClosureMenuItem(L10n.text("take.delete", String(chosen.number))) { [weak self] in
                self?.deleteTake(chosen.id, of: g.id, onTrack: track.id)
            }
            delete.isEnabled = !track.locked
            menu.addItem(delete)
        }
    }

    /// Delete Take (the window's only): one undo step; the file stays in the media folder until Storage clears it.
    func deleteTake(_ take: UUID, of group: UUID, onTrack track: UUID) {
        var p = project
        do {
            let number = p.tracks.first { $0.id == track }?.takes.first { $0.id == group }?.takes.first { $0.id == take }?.number ?? 0
            try p.deleteTake(take, of: group, onTrack: track)
            commit(p, action: L10n.text("take.action.delete"))
            say(L10n.text("take.deleted", String(number)), .success)
        } catch {
            say(L10n.error(error), .error)
        }
    }

    // MARK: After a crash

    /// Opened with a journal its id left (a recording that didn't end: Jämmer or the Mac stopped): offers the takes
    /// back, laid where they were recorded as one undo step. Later keeps the journal for next time; Forget removes
    /// only the journal (the files stay in the media folder).
    func offerUnfinishedRecording(in window: NSWindow) {
        guard recording == nil, let id = project.documentID, let journal = RecordingJournal.left(by: id, in: Self.journalFolder) else { return }
        let alert = NSAlert()
        alert.messageText = L10n.text("recover.title")
        let when = DateFormatter.localizedString(from: journal.started, dateStyle: .medium, timeStyle: .short)
        if let was = journal.documentPath, was != document?.fileURL?.path {
            alert.informativeText = L10n.text("recover.textMoved", when, was)
        } else {
            alert.informativeText = L10n.text("recover.text", when)
        }
        alert.addButton(withTitle: L10n.text("recover.putBack"))
        alert.addButton(withTitle: L10n.text("recover.later"))
        alert.addButton(withTitle: L10n.text("recover.forget"))
        alert.beginSheetModal(for: window) { [weak self] answer in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch answer {
                case .alertFirstButtonReturn: self.putBack(journal)
                case .alertThirdButtonReturn: RecordingJournal.remove(id, in: Self.journalFolder)
                default: break
                }
            }
        }
    }

    private func putBack(_ journal: RecordingJournal) {
        var p = project
        var laid = 0
        for found in journal.recover() {
            let url = URL(fileURLWithPath: found.take.path)
            guard p.tracks.contains(where: { $0.id == found.take.track }), let info = try? AudioFileReader.info(at: url) else { continue }
            let source = SourceRef(name: url.deletingPathExtension().lastPathComponent, path: url.path, info: info)
            if (try? p.recordTake(source, frames: found.frames, at: journal.at, onTrack: found.take.track, sourceStart: journal.sourceStart)) != nil { laid += 1 }
        }
        commit(p, action: L10n.text("record.action"))
        StorageScanner.note(self)
        RecordingJournal.remove(journal.documentID, in: Self.journalFolder)
        say(L10n.count("recover.done", laid), laid > 0 ? .success : .warning)
    }
}

/// A menu item that runs a closure (the take list: its items change with the document).
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("not from a nib") }
    @objc private func fire() { run() }
}
