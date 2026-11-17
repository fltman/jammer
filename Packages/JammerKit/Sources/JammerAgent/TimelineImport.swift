import Foundation
import JammerCore

/// `POST /api/v1/import/fcpxml` and `/api/v1/import/timeline`: an agent names a timeline file by path.
/// Like batch, the file and every media file it points at must lie in a folder the user allowed; checked
/// before anything is opened as audio. `formats`: the extensions this route reads (`nil`: every timeline
/// format). `unpackTo`: where audio inside a DAWproject is unpacked (Jämmer's own media folder, allowed).
public enum TimelineImport {
    public static let extensions = ["fcpxml", "fcpxmld", "edl", "otio", "dawproject"]

    public static func check(_ body: [String: Any], policy: FolderPolicy?, formats: [String]? = ["fcpxml", "fcpxmld"],
                             unpackTo: URL = FileManager.default.temporaryDirectory.appending(path: "jammer-dawproject")) throws -> FCPXMLImport.Timeline {
        let route = formats == nil ? "import/timeline" : "import/fcpxml"
        let fields = formats == nil ? ["path", "rate"] : ["path"]
        if let unknown = body.keys.first(where: { !fields.contains($0) && $0 != AgentAPI.rationale }) {
            throw BatchError("bad_request", "Unknown field \"\(unknown)\". \(route) takes: \(fields.joined(separator: ", ")).")
        }
        let readable = formats ?? extensions
        guard let path = body["path"] as? String, path.hasPrefix("/") else {
            throw BatchError("bad_request", "path is required: the absolute path of " + (formats == nil ? "an .fcpxml, .edl, .otio or .dawproject file." : "an .fcpxml file."))
        }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard readable.contains(ext) else {
            throw BatchError("bad_request", "\(route) reads \(readable.map { "." + $0 }.joined(separator: ", ")) files; \(URL(fileURLWithPath: path).lastPathComponent) isn't one" + (formats == nil ? "." : " (import/timeline reads EDL, OTIO and DAWproject too)."))
        }
        var rate: Timecode.Rate?
        if let r = body["rate"] {
            guard ext == "edl" else { throw BatchError("bad_request", "rate is for an EDL only: the other formats say their own times.") }
            guard let s = r as? String, let v = Timecode.Rate(rawValue: s) else {
                throw BatchError("bad_request", "rate must be one of \(Timecode.Rate.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            rate = v
        }
        let url = FolderPolicy.canonical(path)
        func allowed(_ u: URL) -> Bool { policy?.allows(u) ?? true }
        guard allowed(url) else {
            throw BatchError("folder_not_allowed", "\(path) isn't in a folder agents may use. The user allows folders in Jämmer › Settings… › Agents.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw BatchError("not_found", "There is no file at \(path).") }
        let base = url.deletingLastPathComponent(), name = url.deletingPathExtension().lastPathComponent
        let timeline: FCPXMLImport.Timeline
        do {
            switch ext {
            case "edl":
                guard let data = FileManager.default.contents(atPath: url.path), data.count < 32 << 20 else { throw FCPXMLImport.ImportError.unreadable("it is far larger than an edit decision list.") }
                // Lists are ASCII in practice; older ones Latin-1.
                let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
                timeline = try EDL.read(text, base: base, name: name, rate: rate)
            case "otio":
                guard let data = FileManager.default.contents(atPath: url.path) else { throw FCPXMLImport.ImportError.unreadable("it couldn't be read.") }
                timeline = try OTIO.read(data, base: base, name: name)
            case "dawproject":
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw FCPXMLImport.ImportError.unreadable("it couldn't be read.") }
                timeline = try DAWproject.read(data, base: base, name: name, unpackTo: unpackTo.appending(path: UUID().uuidString))
            default:
                // Final Cut's own bundles (.fcpxmld) keep the XML inside.
                timeline = try FCPXMLImport.read(isDirectory.boolValue ? url.appending(path: "Info.fcpxml") : url)
            }
        } catch let error as FCPXMLImport.ImportError { throw BatchError(error.reason, error.localizedDescription) }
        let own = FolderPolicy.canonical(unpackTo.path).path + "/"
        for media in timeline.media where !FolderPolicy.canonical(media.path).path.hasPrefix(own) && !allowed(FolderPolicy.canonical(media.path)) {
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

/// `POST /api/v1/documents/{id}/export/timeline`: the document's clips as an EDL, OTIO or DAWproject file,
/// as bytes. Nothing is rendered: the file names the audio files the clips play.
public enum TimelineExport {
    public struct File: Sendable { public var data: Data; public var contentType: String; public var fileExtension: String; public var warnings: [String] }

    public static func make(_ project: Project, name: String, body: [String: Any], appVersion: String) throws -> File {
        if let unknown = body.keys.first(where: { $0 != "format" && $0 != AgentAPI.rationale }) {
            throw BatchError("bad_request", "Unknown field \"\(unknown)\". export/timeline takes: format.")
        }
        guard let s = body["format"] as? String, let format = TimelineFormat(rawValue: s.lowercased()) else {
            throw BatchError("bad_request", "format must be one of \(TimelineFormat.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return try make(project, name: name, format: format, appVersion: appVersion)
    }

    public static func make(_ project: Project, name: String, format: TimelineFormat, appVersion: String) throws -> File {
        guard project.tracks.contains(where: { !$0.clips.isEmpty }) else { throw BatchError("empty", "The document has no clips to write.") }
        let t = ExchangeTimeline(project, name: name)
        switch format {
        case .edl:
            do {
                let w = try EDL.write(t)
                return File(data: Data(w.text.utf8), contentType: "text/plain; charset=utf-8", fileExtension: "edl", warnings: w.warnings)
            } catch let e as ExportError { throw BatchError("too_many_events", e.localizedDescription) }
        case .otio:
            let w = try OTIO.write(t)
            return File(data: w.data, contentType: "application/json", fileExtension: "otio", warnings: w.warnings)
        case .dawproject:
            let w = DAWproject.write(t, appVersion: appVersion)
            return File(data: w.data, contentType: "application/zip", fileExtension: "dawproject", warnings: w.warnings)
        }
    }
}
