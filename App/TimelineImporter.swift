import AppKit
import JammerAgent
import JammerCore

/// Opens a film timeline (FCPXML) as a new untitled document: the sound as tracks, the
/// pictures as shot markers. From File › Import Final Cut Pro XML… and from the agent API.
@MainActor
enum TimelineImporter {
    static func open(_ timeline: FCPXMLImport.Timeline) async throws -> (session: EditorSession?, imported: FCPXMLImport.Result) {
        let result: FCPXMLImport.Result
        do {
            result = try await Task.detached(priority: .userInitiated) { try FCPXMLImport.build(timeline, mediaFolder: MediaStore.folder) }.value
        } catch let e as FCPXMLImport.ImportError {
            throw BatchError(e.reason, e.localizedDescription)
        }
        guard let controller = NSDocumentController.shared as? JammerDocumentController else {
            throw BatchError("internal", "The document controller isn't Jämmer's.")
        }
        let doc = controller.open(result.project, name: result.name)
        if let s = doc.session {
            let w = result.warnings.count
            let done = L10n.text("import.done", L10n.count("import.tracks", result.project.tracks.count), L10n.count("import.clips", result.clips))
            s.status = w > 0 ? L10n.text("import.done.notes", done, L10n.count("import.notes", w), result.warnings[0].message + (w > 1 ? " …" : "")) : done
        }
        return (doc.session, result)
    }

    /// The menu command: the user picks the file, so no folder rule applies.
    static func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "fcpxml"), .init(filenameExtension: "fcpxmld"), .xml].compactMap { $0 }
        panel.message = L10n.text("import.panel.message")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                var timeline = try TimelineImport.check(["path": url.path], policy: nil)
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
                        timeline.warnings.append(.init(code: "outside", message: "\(outside.count) file\(outside.count == 1 ? "" : "s") outside the timeline's folder \(outside.count == 1 ? "wasn't" : "weren't") read.", clip: nil))
                    }
                }
                _ = try await open(timeline)
            } catch {
                let alert = NSAlert()
                alert.messageText = L10n.text("import.failed.title")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}
