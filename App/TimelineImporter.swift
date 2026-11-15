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
            s.status = "Imported \(result.project.tracks.count) tracks, \(result.clips) clips" + (w > 0 ? " (\(w) note\(w == 1 ? "" : "s"): \(result.warnings[0].message)\(w > 1 ? " …" : ""))" : "")
        }
        return (doc.session, result)
    }

    /// The menu command: the user picks the file, so no folder rule applies.
    static func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "fcpxml"), .init(filenameExtension: "fcpxmld"), .xml].compactMap { $0 }
        panel.message = "Choose a Final Cut Pro XML file (from Flimmer, Final Cut Pro or DaVinci Resolve). Its sound opens as a new document; the files it uses aren't changed."
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
                    alert.messageText = "This timeline uses audio from other folders"
                    alert.informativeText = "“\(url.lastPathComponent)” names \(outside.count) audio file\(outside.count == 1 ? "" : "s") outside its own folder:\n\n"
                        + outside.prefix(6).map { "• " + ($0.path as NSString).abbreviatingWithTildeInPath }.joined(separator: "\n")
                        + (outside.count > 6 ? "\n… and \(outside.count - 6) more" : "")
                        + "\n\nIf the timeline is your own, or you trust where it came from, use them. Otherwise import without: those clips are left out, and nothing outside the timeline's folder is read."
                    alert.addButton(withTitle: "Import Without Them")
                    alert.addButton(withTitle: "Use These Files")
                    if alert.runModal() == .alertFirstButtonReturn {
                        let drop = Set(outside)
                        for i in timeline.tracks.indices { timeline.tracks[i].clips.removeAll { drop.contains($0.media) } }
                        timeline.warnings.append(.init(code: "outside", message: "\(outside.count) file\(outside.count == 1 ? "" : "s") outside the timeline's folder \(outside.count == 1 ? "wasn't" : "weren't") read.", clip: nil))
                    }
                }
                _ = try await open(timeline)
            } catch {
                let alert = NSAlert()
                alert.messageText = "The timeline couldn't be imported"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}
