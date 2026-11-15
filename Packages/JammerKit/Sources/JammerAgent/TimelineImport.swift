import Foundation
import JammerCore

/// `POST /api/v1/import/fcpxml`: an agent names a timeline file by path. Like batch, the file
/// and every media file it points at must lie in a folder the user allowed; checked before
/// anything is opened as audio.
public enum TimelineImport {
    public static func check(_ body: [String: Any], policy: FolderPolicy?) throws -> FCPXMLImport.Timeline {
        if let unknown = body.keys.first(where: { $0 != "path" }) {
            throw BatchError("bad_request", "Unknown field \"\(unknown)\". import/fcpxml takes: path.")
        }
        guard let path = body["path"] as? String, path.hasPrefix("/") else {
            throw BatchError("bad_request", "path is required: the absolute path of an .fcpxml file.")
        }
        let url = FolderPolicy.canonical(path)
        func allowed(_ u: URL) -> Bool { policy?.allows(u) ?? true }
        guard allowed(url) else {
            throw BatchError("folder_not_allowed", "\(path) isn't in a folder agents may use. The user allows folders in Jämmer › Settings… › Agents.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw BatchError("not_found", "There is no file at \(path).") }
        // Final Cut's own bundles (.fcpxmld) keep the XML inside.
        let file = isDirectory.boolValue ? url.appending(path: "Info.fcpxml") : url
        let timeline: FCPXMLImport.Timeline
        do { timeline = try FCPXMLImport.read(file) } catch { throw BatchError(error.reason, error.localizedDescription) }
        for media in timeline.media where !allowed(FolderPolicy.canonical(media.path)) {
            throw BatchError("folder_not_allowed", "The timeline uses \(media.path), which isn't in a folder agents may use. The user allows folders in Jämmer › Settings… › Agents.")
        }
        return timeline
    }

    /// The `import` part of the answer.
    public static func json(_ r: FCPXMLImport.Result) -> [String: Any] {
        func r3(_ v: Double) -> Double { (v * 1_000).rounded() / 1_000 }
        return ["tracks": r.project.tracks.count, "clips": r.clips, "sources": r.project.sources.count,
                "shots": r.shots.filter { !$0.name.isEmpty }.map { ["name": $0.name, "start": r3($0.start.seconds), "duration": r3($0.duration.seconds)] as [String: Any] },
                "flimmer": r.flimmerExportVersion.map { ["exportVersion": $0] as Any } ?? NSNull(),
                "warnings": r.warnings.map { w in
                    var d: [String: Any] = ["code": w.code, "message": w.message]
                    if let c = w.clip { d["clip"] = c }
                    return d
                }]
    }
}
