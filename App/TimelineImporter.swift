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
                let timeline = try TimelineImport.check(["path": url.path], policy: nil)
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
