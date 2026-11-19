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

public struct BatchError: Error, LocalizedError, Equatable, KeyedFailure {
    public var reason: String
    public var message: String
    /// The message by its key, for a window (`message` is its English, for the API).
    public var keyed: KeyedMessage?
    public init(_ reason: String, _ message: String) {
        self.reason = reason
        self.message = message
    }
    public init(_ reason: String, _ said: Said) {
        self.init(reason, said.text)
        keyed = said.keyed
    }
    /// Another error, with its own key when it has one.
    public init(_ reason: String, wrapping error: Error) {
        self.init(reason, Said.of(error))
    }
    public var errorDescription: String? { message }
}

public struct BatchRequest: Sendable {
    public struct JobStep: Sendable, Equatable {
        public var op: String
        public var params: [String: JSONValue]
        /// Set only by `parse` when the request allowed a paid job (allowPaid and allowUnknownPrice: an agent's
        /// word, or the window's question answered). The runner refuses a paid job without it, so no other
        /// way of making a request can send audio to a paid service unasked (SIBLINGS, "Betalt kräver alltid en fråga").
        public internal(set) var paidAllowed = false
        public init(op: String, params: [String: JSONValue] = [:]) {
            self.op = op
            self.params = params
        }
        /// A job that sends audio to a paid service: transcribe with a paid engine.
        public var isPaid: Bool { op == "transcribe" && BatchRequest.paidEngines.contains(params["engine"]?.string ?? "auto") }
    }

    /// The transcription engines a provider charges for (the app's `SpeechEngines.Choice.paid`; a test keeps them together).
    public static let paidEngines: Set<String> = ["openai"]

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
    /// The files' sample rate when it is to differ from each source's own (`export.sampleRate`).
    public var sampleRate: Double?
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
            throw BatchError("would_overwrite_source", Said("error.batch.one_files_being_processed", "%@ is one of the files being processed; batch never writes over its input. Use a suffix or another output folder.", "\(destination(for: clash).lastPathComponent)"))
        }
    }

    /// From an API body. With `policy`, every path must lie in a folder the user allowed.
    static let fields: Set<String> = ["files", "folder", "steps", "jobs", "export", "output", "suffix", "overwrite", "allowPaid", "allowUnknownPrice"]

    public static func parse(_ body: [String: Any], policy: FolderPolicy?) throws -> BatchRequest {
        let known = fields
        if let k = body.keys.first(where: { !known.contains($0) && $0 != AgentAPI.rationale }) { throw BatchError("bad_request", Said("error.batch.unknown_field_1_batch", "Unknown field \"%1$@\". batch takes: %2$@.", "\(k)", "\(known.sorted().joined(separator: ", "))")) }
        func checked(_ path: String, _ what: String) throws -> URL {
            guard path.hasPrefix("/") else { throw BatchError("bad_request", Said("error.batch.absolute_path", "%@ must be an absolute path.", "\(what)")) }
            let url = FolderPolicy.canonical(path)
            if let policy, !policy.allows(url) {
                throw BatchError("folder_not_allowed", Said("error.batch.isn_t_folder_agents", "%@ isn't in a folder agents may use. The user allows folders in Jämmer › Settings… › Agents.", "\(path)"))
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
        guard !inputs.isEmpty else { throw BatchError("bad_request", Said("error.batch.give_files_absolute_paths", "Give files (absolute paths) or a folder with audio in it.")) }
        guard let out = body["output"] as? String else { throw BatchError("bad_request", Said("error.batch.batch_needs_output_folder", "batch needs an output folder.")) }
        var steps: [Step] = []
        if let raw = body["steps"] as? [Any], !raw.isEmpty {
            do {
                steps = try AgentAPI.parseSteps(try JSONSerialization.data(withJSONObject: ["steps": raw])).steps
            } catch let e as AgentAPI.APIError { throw BatchError("bad_request", e.message) }
            for s in steps { do { try StepRunner.validate(s) } catch { throw BatchError("bad_request", error.localizedDescription) } }
        }
        var jobs: [JobStep] = []
        for item in (body["jobs"] as? [[String: Any]]) ?? [] {
            guard let op = item["op"] as? String, jobOps.contains(op) else { throw BatchError("bad_request", Said("error.batch.jobs_take_op", "jobs take op %@.", "\(jobOps.sorted().joined(separator: ", "))")) }
            // A job says what it is and with what, and nothing else; and only what that job takes.
            if let k = item.keys.sorted().first(where: { !["op", "params", AgentAPI.rationale].contains($0) }) { throw BatchError("bad_request", Said("error.batch.job_has_field_takes", "A job has no field \"%@\". It takes: op, params.", "\(k)")) }
            let takes = Operations.endpoints.first { $0.name == op }.map { Set($0.params.map(\.name)) }
            var params: [String: JSONValue] = [:]
            for (k, v) in (item["params"] as? [String: Any]) ?? [:] {
                if let takes, !takes.contains(k), k != AgentAPI.rationale { throw BatchError("bad_request", Said("error.batch.job_1_has_parameter", "The job %1$@ has no parameter \"%2$@\". It takes: %3$@.", "\(op)", "\(k)", "\(takes.sorted().joined(separator: ", "))")) }
                guard let j = JSONValue(v) else { throw BatchError("bad_request", Said("error.batch.job_1_2_number", "The job %1$@: \"%2$@\" must be a number, string, boolean or list.", "\(op)", "\(k)")) }
                if k != AgentAPI.rationale { params[k] = j }
            }
            jobs.append(JobStep(op: op, params: params))
        }
        // A paid job runs only on the request's word: allowPaid, and allowUnknownPrice (Jämmer can't read the
        // provider's price). The window asks before it gives them; an agent passes them itself.
        if let paid = jobs.first(where: \.isPaid) {
            let engine = paid.params["engine"]?.string ?? ""
            guard body["allowPaid"] as? Bool == true else {
                throw BatchError("paid_not_allowed", Said("error.batch.paidNotAllowed", "The job transcribe with engine %@ uploads the audio to its provider, which charges the user's account. Pass \"allowPaid\": true to run it.", engine))
            }
            guard body["allowUnknownPrice"] as? Bool == true else {
                throw BatchError("unknown_price", Said("error.batch.unknownPrice", "Jämmer doesn't know what engine %@ costs (its provider charges by its own price list). Pass \"allowUnknownPrice\": true as well to run it.", engine))
            }
            for i in jobs.indices where jobs[i].isPaid { jobs[i].paidAllowed = true }
        }
        if let given = body["export"], !(given is [String: Any]) { throw BatchError("bad_request", Said("error.batch.export_object", "export must be an object.")) }
        let e = (body["export"] as? [String: Any]) ?? [:]
        if let k = e.keys.sorted().first(where: { !exportKeys.contains($0) && $0 != AgentAPI.rationale }) {
            throw BatchError("bad_request", Said("error.batch.export_has_field_1", "export has no field \"%1$@\". It takes: %2$@.", "\(k)", "\(exportKeys.sorted().joined(separator: ", "))"))
        }
        guard let format = ExportFormat(rawValue: (e["format"] as? String) ?? "wav"), ExportFormat.available.contains(format) else {
            throw BatchError("bad_request", Said("error.batch.export_format_one", "export.format must be one of %@.", "\(ExportFormat.available.map(\.rawValue).joined(separator: ", "))"))
        }
        let defaults: [ExportFormat: Int] = [.aac: 192_000, .opus: 96_000, .mp3: 160_000]
        let depth = (e["bitDepth"] as? Int) ?? 24
        if format.isLossless, !format.bitDepths.contains(depth) { throw BatchError("bad_request", Said("error.batch.1_takes_2_bits", "%1$@ takes %2$@ bits.", "\(format.rawValue)", "\(format.bitDepths.map(String.init).joined(separator: " or "))")) }
        var request = BatchRequest(inputs: inputs, steps: steps, jobs: jobs,
                                   export: .init(format: format, bitDepth: depth, bitRate: (e["bitRate"] as? Int) ?? defaults[format] ?? 160_000),
                                   chapters: (e["chapters"] as? Bool) ?? true, output: try checked(out, "output"),
                                   suffix: (body["suffix"] as? String) ?? " (Jämmer)", overwrite: (body["overwrite"] as? Bool) ?? false)
        if let unknown = e.keys.first(where: { !exportKeys.contains($0) && $0 != AgentAPI.rationale }) {
            throw BatchError("bad_request", Said("error.batch.unknown_export_field_1", "Unknown export field \"%1$@\". export takes: %2$@.", "\(unknown)", "\(exportKeys.sorted().joined(separator: ", "))"))
        }
        if let t = e["targetLUFS"] {
            guard let n = t as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), (-40.0 ... -5.0).contains(n.doubleValue) else {
                throw BatchError("bad_request", Said("error.batch.export_targetlufs_number_between", "export.targetLUFS must be a number between -40 and -5."))
            }
            guard !format.isLossless else {
                throw BatchError("bad_request", Said("error.batch.export_targetlufs_mp3_aac", "export.targetLUFS is for mp3, aac and opus, where the encoder changes the loudness. Set the level of a %@ with a loudness_preset or normalize step.", "\(format.rawValue)"))
            }
            request.loudnessTarget = .init(integrated: n.doubleValue)
        } else if let last = steps.last, last.op == "loudness_preset", let preset = LoudnessPreset(rawValue: last.params["preset"]?.string ?? "") {
            request.loudnessTarget = .init(integrated: preset.integrated, ceiling: preset.truePeakCeiling)
        }
        if let c = e["compensate"] {
            guard let b = c as? Bool else { throw BatchError("bad_request", Said("error.batch.export_compensate_true_false", "export.compensate must be true or false.")) }
            request.compensate = b
        }
        if let v = e["sampleRate"] {
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), SampleRateConversion.rates.contains(n.doubleValue) else {
                throw BatchError("bad_request", Said("error.batch.export_samplerate_one", "export.sampleRate must be one of %@.", "\(SampleRateConversion.ratesList)"))
            }
            if format == .opus, n.doubleValue != 48_000 { throw BatchError("bad_request", Said("error.batch.opus_always_written_48000", "opus is always written at 48000 Hz; leave export.sampleRate out or give 48000.")) }
            guard SampleRateConversion.factory != nil else { throw BatchError("bad_request", Said("error.batch.sample_rate_conversion_isn", "Sample rate conversion isn't available in this build.")) }
            request.sampleRate = n.doubleValue
        }
        try request.checkSources()
        return request
    }
    static let exportKeys: Set<String> = ["format", "bitDepth", "bitRate", "chapters", "targetLUFS", "compensate", "sampleRate"]
}

public struct BatchResult: Sendable, Equatable {
    public struct Failure: Sendable, Equatable {
        public var file: String
        public var reason: String
        public var message: String
    }
    public var outputs: [String] = []
    /// Per output, in the same order: the integrated loudness of what was written (LUFS), and
    /// whether a loudness step stopped short of its target because of the peaks (the step was run without `limit`).
    public var loudness: [Double?] = []
    public var limitedByPeak: [Bool] = []
    /// Per output: the gain put in before a lossy encoder so the file as delivered meets the
    /// target (0 when nothing was needed or nothing was asked), and whether `loudness` was
    /// measured on the written file ("file") or is the mix's because the file couldn't be read back ("mix").
    public var compensatedDB: [Double] = []
    public var loudnessFrom: [String] = []
    public var failed: [Failure] = []
    public var skipped: [String] = []
    /// What went in short: files that were cut off and opened with what was there.
    public var warnings: [String] = []

    public var json: [String: JSONValue] {
        ["done": .number(Double(outputs.count)), "outputs": .array(outputs.map { .string($0) }), "skipped": .array(skipped.map { .string($0) }),
         "loudness": .array(loudness.map { $0.map { .number(($0 * 10).rounded() / 10) } ?? .null }), "limitedByPeak": .array(limitedByPeak.map { .bool($0) }),
         "compensatedDB": .array(compensatedDB.map { .number($0) }), "loudnessFrom": .array(loudnessFrom.map { .string($0) }),
         "warnings": .array(warnings.map { .string($0) }),
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
                if let w = imported.warning { result.warnings.append(w) }
                var state = EditState(project: Project(source: imported.source), pool: SourcePool(), media: media)
                let pool = state.pool!
                let results = StepRunner.run(request.steps, on: &state) { p, r in LoudnessMeter.measure(PlanCompiler.mixBlocking(p, pool: pool), r) }
                if let f = results.first(where: { $0.status == .failed }) { throw BatchError(f.reason ?? "step_failed", f.error ?? "A step failed.") }
                var project = state.project
                for j in request.jobs {
                    guard let job else { throw BatchError("not_available", Said("error.batch.isn_t_available_here", "%@ isn't available here.", "\(j.op)")) }
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

    /// With a limiter on the master (a recipe can put one there) the file is measured as written and
    /// written again further under the ceiling until it holds, as an export from the app is.
    static func export(_ project: Project, pool: SourcePool, to url: URL, request: BatchRequest) throws {
        guard project.length > 0 else { throw BatchError("empty", Said("error.batch.nothing_left_export", "Nothing is left to export.")) }
        guard let ceiling = project.master.limiter?.ceilingDB else {
            return try exportOnce(project, pool: pool, to: url, request: request, masterMargin: Mixer.masterMargins[0])
        }
        // Checked under another name, so a file over the ceiling never stands where a good one was.
        let trial = url.deletingLastPathComponent().appending(path: ".\(UUID().uuidString.prefix(8)).checked.\(url.pathExtension)")
        defer { try? FileManager.default.removeItem(at: trial) }
        var peak = Double.infinity
        for margin in Mixer.exportMargins {
            try exportOnce(project, pool: pool, to: trial, request: request, masterMargin: margin)
            guard let measured = EncodedWriter.measureWritten(trial, scratch: FileManager.default.temporaryDirectory) else {
                throw BatchError(MasterCeilingError.reason, MasterCeilingError(ceilingDB: ceiling, truePeakDB: nil).localizedDescription)
            }
            peak = measured.truePeak
            if peak <= ceiling {
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: trial, to: url)
                return
            }
        }
        throw BatchError(MasterCeilingError.reason, MasterCeilingError(ceilingDB: ceiling, truePeakDB: peak).localizedDescription)
    }

    private static func exportOnce(_ project: Project, pool: SourcePool, to url: URL, request: BatchRequest, masterMargin: Double) throws {
        let original = project
        var project = project
        var plan = PlanCompiler.mixBlocking(project, pool: pool, masterMargin: masterMargin)
        var range: Range<Frame> = 0..<project.length
        // Written under another name first, so a failed export never leaves half a file where a good one was.
        let tmp = url.deletingLastPathComponent().appending(path: ".\(UUID().uuidString.prefix(8)).\(url.pathExtension)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Another sample rate: the mix converted once, and the file made from that. Markers move with it; chapters are in seconds.
        let converted = url.deletingLastPathComponent().appending(path: ".\(UUID().uuidString.prefix(8)).converted.wav")
        defer { try? FileManager.default.removeItem(at: converted) }
        if let rate = request.sampleRate, rate != project.sampleRate {
            let scale = rate / project.sampleRate
            var p = Project(source: try SampleRateConversion.render(plan, range: range, to: rate, into: converted))
            p.markers = original.markers.map { m in var m = m; m.position = Frame((Double(m.position) * scale).rounded()); m.length = Frame((Double(m.length) * scale).rounded()); return m }
            p.transcripts = []
            project = p
            plan = PlanCompiler.compile(p, pool: SourcePool())
            range = 0..<p.length
        }
        if request.export.format == .wav {
            var o = WAVWriter.Options(encoding: request.export.bitDepth == 16 ? .int16 : (request.export.bitDepth == 32 ? .float32 : .int24),
                                      channels: project.channels, sampleRate: project.sampleRate)
            o.markers = project.markers.map { FileMarker(position: $0.position, length: $0.length, name: $0.cueLabel) }
            o.bext = original.sources.first?.info.bext
            o.ixml = original.sources.first?.info.ixml
            let w = try WAVWriter(url: tmp, options: o)
            try plan.render(range) { try w.write($0) }
            try w.finish()
        } else {
            var o = request.export
            if request.chapters {
                let chapters = original.chapters(in: 0..<original.length)
                if o.format == .mp3 { o.id3 = ChapterFormats.id3Tag(chapters, title: url.deletingPathExtension().lastPathComponent) } else { o.chapters = chapters }
                o.language = original.transcripts.first?.language
            }
            try EncodedWriter.export(plan, range: range, to: tmp, options: o)
        }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
    }
}
