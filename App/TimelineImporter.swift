import AppKit
import JammerAgent
import JammerCore
import UniformTypeIdentifiers

/// Opens a timeline (FCPXML, CMX 3600 EDL, OpenTimelineIO or DAWproject) as a new untitled document: the
/// sound as tracks, the pictures or markers as shot markers. From File › Import Timeline… and the agent API.
@MainActor
enum TimelineImporter {
    static func open(_ timeline: FCPXMLImport.Timeline) async throws -> (session: EditorSession?, imported: FCPXMLImport.Result) {
        let result: FCPXMLImport.Result
        do {
            result = try await Task.detached(priority: .userInitiated) { try FCPXMLImport.build(timeline, mediaFolder: MediaStore.folder) }.value
        } catch let e as FCPXMLImport.ImportError {
            throw BatchError(e.reason, wrapping: e)
        }
        guard let controller = NSDocumentController.shared as? JammerDocumentController else {
            throw BatchError("internal", Said("error.batch.document_controller_isn_t", "The document controller isn't Jämmer's."))
        }
        let doc = controller.open(result.project, name: result.name)
        if let s = doc.session {
            let w = result.warnings.count
            let done = L10n.text("import.done", L10n.count("import.tracks", result.project.tracks.count), L10n.count("import.clips", result.clips))
            s.status = w > 0 ? L10n.text("import.done.notes", done, L10n.count("import.notes", w), (result.warnings[0].keyed.map(L10n.message) ?? result.warnings[0].message) + (w > 1 ? " …" : "")) : done
        }
        return (doc.session, result)
    }

    /// A frame rate's name: "25 fps", "29.97 fps drop-frame", its number in the Mac's region.
    static func rateTitle(_ r: Timecode.Rate) -> String {
        let p = r.perSecond, fps = Double(p.num) / Double(p.den)
        let n = L10n.number(fps, fps.rounded() == fps ? 0 : (r == .fps23976 ? 3 : 2))
        return r.dropsFrames ? L10n.text("timecode.rate.drop", n) : L10n.text("timecode.rate", n)
    }

    /// An EDL doesn't say its frame rate: asked, with its FCM line's choice first (drop-frame lists say so).
    static func askRate(_ url: URL) -> Timecode.Rate? {
        let head = (try? FileHandle(forReadingFrom: url).read(upToCount: 4_096)).flatMap { $0 }.map { String(decoding: $0, as: UTF8.self).uppercased() } ?? ""
        let drop = head.contains("FCM: DROP FRAME")
        let alert = NSAlert()
        alert.messageText = L10n.text("import.edl.rate.title")
        alert.informativeText = L10n.text("import.edl.rate.text", url.lastPathComponent)
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 26), pullsDown: false)
        let rates = Timecode.Rate.allCases
        for r in rates { popup.addItem(withTitle: rateTitle(r)) }
        popup.selectItem(at: rates.firstIndex(of: drop ? .fps2997drop : .fps25) ?? 0)
        popup.setAccessibilityLabel(L10n.text("import.edl.rate.title"))
        alert.accessoryView = popup
        alert.addButton(withTitle: L10n.text("import.edl.rate.import"))
        alert.addButton(withTitle: L10n.text("button.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return rates[popup.indexOfSelectedItem]
    }

    /// The menu command: the user picks the file, so no folder rule applies.
    static func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = (TimelineImport.extensions.map { UTType(filenameExtension: $0) } + [.xml]).compactMap { $0 }
        panel.message = L10n.text("import.panel.message")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var body: [String: Any] = ["path": url.path]
        if url.pathExtension.lowercased() == "edl" {
            guard let rate = askRate(url) else { return }
            body["rate"] = rate.rawValue
        }
        Task {
            do {
                var timeline = try TimelineImport.check(body, policy: nil, formats: nil, unpackTo: MediaStore.folder.appending(path: "Unpacked"))
                // The user chose the timeline, not every file it names. Media beside it (in its own
                // folder) comes along; media elsewhere on the Mac is asked about first.
                let home = SourcePool.real(url.deletingLastPathComponent()).path + "/"
                let outside = timeline.media.filter { !SourcePool.real($0).path.hasPrefix(home) && FileManager.default.fileExists(atPath: $0.path) }
                if !outside.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = L10n.text("import.outside.title")
                    let shown = outside.prefix(6).map { "• " + ($0.path as NSString).abbreviatingWithTildeInPath }.joined(separator: "\n")
                        + (outside.count > 6 ? "\n" + L10n.text("ask.more", String(outside.count - 6)) : "")
                    alert.informativeText = L10n.text("import.outside.text", url.lastPathComponent, L10n.count("access.ask.files", outside.count), shown)
                    alert.addButton(withTitle: L10n.text("import.outside.without"))
                    alert.addButton(withTitle: L10n.text("access.ask.use"))
                    if alert.runModal() == .alertFirstButtonReturn {
                        let drop = Set(outside)
                        for i in timeline.tracks.indices { timeline.tracks[i].clips.removeAll { drop.contains($0.media) } }
                        timeline.warnings.append(.init(code: "outside", message: counted(outside.count, Said("import.note.outside.one", "1 file outside the timeline's folder wasn't read."), Said("import.note.outside.other", "%@ files outside the timeline's folder weren't read.", "\(outside.count)")), clip: nil))
                    }
                }
                _ = try await open(timeline)
            } catch {
                let alert = NSAlert()
                alert.messageText = L10n.text("import.failed.title")
                alert.informativeText = L10n.error(error)
                alert.runModal()
            }
        }
    }
}
