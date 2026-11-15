import Foundation
import JammerCore

/// Folders the user has said agents may read from and write to (Settings › Agents). The
/// agent API otherwise never touches paths; batch does, so every path it's given must lie
/// inside one of these after symlinks and ".." are resolved.
public struct FolderPolicy: Sendable {
    public var allowed: [URL]

    public init(allowed: [URL]) {
        self.allowed = allowed.map { $0.resolvingSymlinksInPath().standardizedFileURL }
    }

    /// The real location of `path`; for a path that doesn't exist yet, of its nearest existing parent.
    public static func canonical(_ path: String) -> URL {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
            tail.insert(url.lastPathComponent, at: 0)
            url.deleteLastPathComponent()
        }
        url = url.resolvingSymlinksInPath()
        for c in tail { url.appendPathComponent(c) }
        return url.standardizedFileURL
    }

    public func allows(_ url: URL) -> Bool {
        let p = url.path
        return allowed.contains { p == $0.path || p.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }
    }
}

public struct BatchError: Error, LocalizedError, Equatable {
    public var reason: String
    public var message: String
    public init(_ reason: String, _ message: String) {
        self.reason = reason
        self.message = message
    }
    public var errorDescription: String? { message }
}

public struct BatchRequest: Sendable {
    public struct JobStep: Sendable, Equatable {
        public var op: String
        public var params: [String: JSONValue]
        public init(op: String, params: [String: JSONValue] = [:]) {
            self.op = op
            self.params = params
        }
    }

    public var inputs: [URL]
    public var steps: [Step]
    public var jobs: [JobStep]
    public var export: EncodedExportOptions
    public var chapters: Bool
    public var output: URL
    public var suffix: String
    public var overwrite: Bool
    /// The loudness the files are delivered at, when the request gives one (`export.targetLUFS`)
    /// or ends its steps with a loudness preset. With it, mp3 and aac are measured after
    /// encoding and corrected (`LoudnessDelivery`), unless `compensate` is false.
    public var loudnessTarget: LoudnessDelivery.Target?
    public var compensate = true

    public init(inputs: [URL], steps: [Step] = [], jobs: [JobStep] = [], export: EncodedExportOptions = .init(format: .wav, bitDepth: 24),
                chapters: Bool = true, output: URL, suffix: String = " (Jämmer)", overwrite: Bool = false) {
        self.inputs = inputs
        self.steps = steps
        self.jobs = jobs
        self.export = export
        self.chapters = chapters
        self.output = output
        self.suffix = suffix
        self.overwrite = overwrite
    }

    public static let audioExtensions: Set<String> = ["wav", "wave", "bwf", "aif", "aiff", "aifc", "flac", "mp3", "m4a", "aac", "caf", "ogg", "opus"]
    public static let jobOps: Set<String> = ["restore", "transcribe", "diarize", "separate"]

    /// Where the result of `input` goes.
    public func destination(for input: URL) -> URL {
        output.appending(path: input.deletingPathExtension().lastPathComponent + suffix).appendingPathExtension(export.format.fileExtension)
    }

    /// Refuses a request whose outputs would land on one of its inputs, whatever `overwrite` says.
    public func checkSources() throws {
        let sources = Set(inputs.map { FolderPolicy.canonical($0.path).path })
        if let clash = inputs.first(where: { sources.contains(FolderPolicy.canonical(destination(for: $0).path).path) }) {
            throw BatchError("would_overwrite_source", "\(destination(for: clash).lastPathComponent) is one of the files being processed; batch never writes over its input. Use a suffix or another output folder.")
        }
    }

    /// From an API body. With `policy`, every path must lie in a folder the user allowed.
    public static func parse(_ body: [String: Any], policy: FolderPolicy?) throws -> BatchRequest {
        let known: Set<String> = ["files", "folder", "steps", "jobs", "export", "output", "suffix", "overwrite", "allowPaid"]
        if let k = body.keys.first(where: { !known.contains($0) }) { throw BatchError("bad_request", "Unknown field \"\(k)\". batch takes: \(known.sorted().joined(separator: ", ")).") }
        func checked(_ path: String, _ what: String) throws -> URL {
            guard path.hasPrefix("/") else { throw BatchError("bad_request", "\(what) must be an absolute path.") }
            let url = FolderPolicy.canonical(path)
            if let policy, !policy.allows(url) {
                throw BatchError("folder_not_allowed", "\(path) isn't in a folder agents may use. The user allows folders in Jämmer › Settings… › Agents.")
            }
            return url
        }
        var inputs: [URL] = []
        if let files = body["files"] as? [String] { inputs += try files.map { try checked($0, "files") } }
        if let folder = body["folder"] as? String {
            let dir = try checked(folder, "folder")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for n in names.sorted() where audioExtensions.contains((n as NSString).pathExtension.lowercased()) {
                inputs.append(try checked(dir.appending(path: n).path, "folder"))
            }
        }
        guard !inputs.isEmpty else { throw BatchError("bad_request", "Give files (absolute paths) or a folder with audio in it.") }
        guard let out = body["output"] as? String else { throw BatchError("bad_request", "batch needs an output folder.") }
        var steps: [Step] = []
        if let raw = body["steps"] as? [Any], !raw.isEmpty {
            do {
                steps = try AgentAPI.parseSteps(try JSONSerialization.data(withJSONObject: ["steps": raw])).steps
            } catch let e as AgentAPI.APIError { throw BatchError("bad_request", e.message) }
            for s in steps { do { try StepRunner.validate(s) } catch { throw BatchError("bad_request", error.localizedDescription) } }
        }
        var jobs: [JobStep] = []
        for item in (body["jobs"] as? [[String: Any]]) ?? [] {
            guard let op = item["op"] as? String, jobOps.contains(op) else { throw BatchError("bad_request", "jobs take op \(jobOps.sorted().joined(separator: ", ")).") }
            var params: [String: JSONValue] = [:]
            for (k, v) in (item["params"] as? [String: Any]) ?? [:] { if let j = JSONValue(v) { params[k] = j } }
            jobs.append(JobStep(op: op, params: params))
        }
        let e = (body["export"] as? [String: Any]) ?? [:]
        guard let format = ExportFormat(rawValue: (e["format"] as? String) ?? "wav"), ExportFormat.available.contains(format) else {
            throw BatchError("bad_request", "export.format must be one of \(ExportFormat.available.map(\.rawValue).joined(separator: ", ")).")
        }
        let defaults: [ExportFormat: Int] = [.aac: 192_000, .opus: 96_000, .mp3: 160_000]
        let depth = (e["bitDepth"] as? Int) ?? 24
        if format.isLossless, !format.bitDepths.contains(depth) { throw BatchError("bad_request", "\(format.rawValue) takes \(format.bitDepths.map(String.init).joined(separator: " or ")) bits.") }
        var request = BatchRequest(inputs: inputs, steps: steps, jobs: jobs,
                                   export: .init(format: format, bitDepth: depth, bitRate: (e["bitRate"] as? Int) ?? defaults[format] ?? 160_000),
                                   chapters: (e["chapters"] as? Bool) ?? true, output: try checked(out, "output"),
                                   suffix: (body["suffix"] as? String) ?? " (Jämmer)", overwrite: (body["overwrite"] as? Bool) ?? false)
        if let unknown = e.keys.first(where: { !exportKeys.contains($0) }) {
            throw BatchError("bad_request", "Unknown export field \"\(unknown)\". export takes: \(exportKeys.sorted().joined(separator: ", ")).")
        }
        if let t = e["targetLUFS"] {
            guard let n = t as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), (-40.0 ... -5.0).contains(n.doubleValue) else {
                throw BatchError("bad_request", "export.targetLUFS must be a number between -40 and -5.")
            }
            guard !format.isLossless else {
                throw BatchError("bad_request", "export.targetLUFS is for mp3, aac and opus, where the encoder changes the loudness. Set the level of a \(format.rawValue) with a loudness_preset or normalize step.")
            }
            request.loudnessTarget = .init(integrated: n.doubleValue)
        } else if let last = steps.last, last.op == "loudness_preset", let preset = LoudnessPreset(rawValue: last.params["preset"]?.string ?? "") {
            request.loudnessTarget = .init(integrated: preset.integrated, ceiling: preset.truePeakCeiling)
        }
        if let c = e["compensate"] {
            guard let b = c as? Bool else { throw BatchError("bad_request", "export.compensate must be true or false.") }
            request.compensate = b
        }
        try request.checkSources()
        return request
    }
    static let exportKeys: Set<String> = ["format", "bitDepth", "bitRate", "chapters", "targetLUFS", "compensate"]
}

public struct BatchResult: Sendable, Equatable {
    public struct Failure: Sendable, Equatable {
        public var file: String
        public var reason: String
        public var message: String
    }
    public var outputs: [String] = []
    /// Per output, in the same order: the integrated loudness of what was written (LUFS), and
    /// whether a loudness step stopped short of its target because of the peaks (no limiter yet).
    public var loudness: [Double?] = []
    public var limitedByPeak: [Bool] = []
    /// Per output: the gain put in before a lossy encoder so the file as delivered meets the
    /// target (0 when nothing was needed or nothing was asked), and whether `loudness` was
    /// measured on the written file ("file") or is the mix's because the file couldn't be read back ("mix").
    public var compensatedDB: [Double] = []
    public var loudnessFrom: [String] = []
    public var failed: [Failure] = []
    public var skipped: [String] = []

    public var json: [String: JSONValue] {
        ["done": .number(Double(outputs.count)), "outputs": .array(outputs.map { .string($0) }), "skipped": .array(skipped.map { .string($0) }),
         "loudness": .array(loudness.map { $0.map { .number(($0 * 10).rounded() / 10) } ?? .null }), "limitedByPeak": .array(limitedByPeak.map { .bool($0) }),
         "compensatedDB": .array(compensatedDB.map { .number($0) }), "loudnessFrom": .array(loudnessFrom.map { .string($0) }),
         "failed": .array(failed.map { .string("\($0.file): \($0.reason): \($0.message)") })]
    }
}

public enum BatchRunner {
    /// Runs transcribe, restore, diarize and separate on a project without a window (the app supplies it).
    public typealias JobHook = @Sendable (BatchRequest.JobStep, Project, SourcePool) async throws -> Project

    /// Each file: open without a window, run the steps and jobs, export beside nothing of
    /// the user's: into `output`, never over an input. One file failing doesn't stop the rest.
    public static func run(_ request: BatchRequest, media: URL, job: JobHook? = nil,
                           progress: @Sendable (Double) -> Void = { _ in }, cancelled: @Sendable () -> Bool = { false }) async -> BatchResult {
        var result = BatchResult()
        try? FileManager.default.createDirectory(at: request.output, withIntermediateDirectories: true)
        for (i, input) in request.inputs.enumerated() {
            if cancelled() { break }
            let dest = request.destination(for: input)
            if FileManager.default.fileExists(atPath: dest.path), !request.overwrite {
                result.skipped.append(input.path)
                progress(Double(i + 1) / Double(request.inputs.count))
                continue
            }
            do {
                let imported: AudioImporter.Result
                do { imported = try AudioImporter.importFile(input, mediaFolder: media) } catch {
                    throw BatchError("unreadable", error.localizedDescription)
                }
                var state = EditState(project: Project(source: imported.source), pool: SourcePool(), media: media)
                let pool = state.pool!
                let results = StepRunner.run(request.steps, on: &state) { p, r in LoudnessMeter.measure(PlanCompiler.mixBlocking(p, pool: pool), r) }
                if let f = results.first(where: { $0.status == .failed }) { throw BatchError(f.reason ?? "step_failed", f.error ?? "A step failed.") }
                var project = state.project
                for j in request.jobs {
                    guard let job else { throw BatchError("not_available", "\(j.op) isn't available here.") }
                    project = try await job(j, project, pool)
                }
                let delivery = try deliver(project, pool: pool, to: dest, request: request, media: media)
                result.outputs.append(dest.path)
                result.loudness.append(delivery.loudness ?? LoudnessMeter.measure(PlanCompiler.mixBlocking(project, pool: pool), 0..<project.length).integrated)
                result.loudnessFrom.append(delivery.loudness != nil ? "file" : "mix")
                result.compensatedDB.append(delivery.compensatedDB)
                result.limitedByPeak.append(delivery.limitedByPeak || results.contains { $0.info["limitedByPeak"] == 1 })
            } catch {
                let b = error as? BatchError
                result.failed.append(.init(file: input.path, reason: b?.reason ?? "failed", message: error.localizedDescription))
            }
            progress(Double(i + 1) / Double(request.inputs.count))
        }
        return result
    }

    /// Writes the file and reads it back: a lossy encoder can change the loudness, so the
    /// number reported is the file's. With a target, mp3 and aac are corrected and encoded again.
    static func deliver(_ project: Project, pool: SourcePool, to url: URL, request: BatchRequest, media: URL) throws -> LoudnessDelivery {
        if let target = request.loudnessTarget, request.compensate, request.export.format.loudnessIsCompensated {
            return try LoudnessDelivery.deliver(target, encode: { gain in
                var p = project
                if gain != 0 { try p.changeGain(0..<p.length, by: gain) }
                try export(p, pool: pool, to: url, request: request)
            }, measure: { EncodedWriter.measureWritten(url, scratch: media) })
        }
        try export(project, pool: pool, to: url, request: request)
        let m = EncodedWriter.measureWritten(url, scratch: media)
        return LoudnessDelivery(loudness: m?.integrated, truePeak: m?.truePeak, compensatedDB: 0, encodes: 1, limitedByPeak: false)
    }

    static func export(_ project: Project, pool: SourcePool, to url: URL, request: BatchRequest) throws {
        guard project.length > 0 else { throw BatchError("empty", "Nothing is left to export.") }
        let plan = PlanCompiler.mixBlocking(project, pool: pool)
        let range: Range<Frame> = 0..<project.length
        // Written under another name first, so a failed export never leaves half a file where a good one was.
        let tmp = url.deletingLastPathComponent().appending(path: ".\(UUID().uuidString.prefix(8)).\(url.pathExtension)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        if request.export.format == .wav {
            var o = WAVWriter.Options(encoding: request.export.bitDepth == 16 ? .int16 : (request.export.bitDepth == 32 ? .float32 : .int24),
                                      channels: project.channels, sampleRate: project.sampleRate)
            o.markers = project.markers.map { FileMarker(position: $0.position, length: $0.length, name: $0.cueLabel) }
            o.bext = project.sources.first?.info.bext
            o.ixml = project.sources.first?.info.ixml
            let w = try WAVWriter(url: tmp, options: o)
            try plan.render(range) { try w.write($0) }
            try w.finish()
        } else {
            var o = request.export
            if request.chapters {
                let chapters = project.chapters(in: range)
                if o.format == .mp3 { o.id3 = ChapterFormats.id3Tag(chapters, title: url.deletingPathExtension().lastPathComponent) } else { o.chapters = chapters }
                o.language = project.transcripts.first?.language
            }
            try EncodedWriter.export(plan, range: range, to: tmp, options: o)
        }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
    }
}
