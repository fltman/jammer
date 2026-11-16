import Foundation

/// What a scan found, kept between launches: per bundle and modification date, so only new
/// and changed bundles are loaded again, and a bundle that crashed the helper or isn't a plugin isn't
/// tried again until it changes (or the user asks). A scan that got no answer (out of time, or the
/// helper said nothing) is no verdict: that bundle is tried again at every scan, and a plugin that an
/// earlier scan found stays listed meanwhile.
public struct PluginCatalogue: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var bundle: String
        public var format: PluginFormat
        public var modified: Date
        public var plugins: [ScannedPlugin]
        /// "crashed", "timed_out", "scan_failed" or "invalid" when the bundle gave nothing.
        public var failure: String?
        public var detail: String?
        /// For a bundle that is listed from an earlier, good scan: what the latest scan of it came to
        /// instead, and how many scans in a row have failed. One failed scan doesn't take a plugin away.
        public var scanFailure: String?
        public var scanDetail: String?
        public var failedScans: Int?
        /// Scans passed over since the bundle last ran out of time (see `scansBetweenRetries`).
        public var scansSkipped: Int?

        public init(bundle: String, format: PluginFormat, modified: Date, plugins: [ScannedPlugin], failure: String? = nil, detail: String? = nil) {
            self.bundle = bundle
            self.format = format
            self.modified = modified
            self.plugins = plugins
            self.failure = failure
            self.detail = detail
        }
    }

    public struct Failure: Sendable, Equatable {
        public var name: String
        public var format: PluginFormat
        /// "crashed", "timed_out", "scan_failed", "invalid", or "blocked" (switched off after it took Jämmer down).
        public var reason: String
        /// True when the plugin is still listed from an earlier scan that went well.
        public var kept = false
    }

    /// A verdict about the plugin itself replaces a good one only when it has come this many scans running.
    public static let scansBeforeAVerdictSticks = 2
    /// A bundle that has run out of time this many scans running is then tried only at every
    /// `scansBetweenRetries`-th scan (or when a scan is forced, which is what the user's "scan again"
    /// does), so a plugin that hangs doesn't cost its time limit at every start.
    public static let timeoutsBeforeBackingOff = 2
    public static let scansBetweenRetries = 5

    public var entries: [Entry] = []
    /// Plugin ids ("clap:…", "vst3:…") switched off after a crash while they were in use.
    /// Only the user switches one on again, in the app.
    public var blocked: Set<String> = []

    public init() {}

    public static func key(_ p: ScannedPlugin) -> String { "\(p.format.rawValue):\(p.id)" }

    /// The plugins that can be used: found, and not blocked.
    public var plugins: [ScannedPlugin] { entries.flatMap(\.plugins).filter { !blocked.contains(Self.key($0)) } }

    public var failed: [Failure] {
        entries.compactMap { e in (e.failure ?? e.scanFailure).map { Failure(name: URL(fileURLWithPath: e.bundle).deletingPathExtension().lastPathComponent, format: e.format, reason: $0, kept: e.failure == nil) } }
            + entries.flatMap(\.plugins).filter { blocked.contains(Self.key($0)) }.map { Failure(name: $0.name, format: $0.format, reason: "blocked") }
    }

    public func plugin(_ key: String) -> ScannedPlugin? { plugins.first { Self.key($0) == key } }

    /// The bundles of one format in its folders (also inside vendor subfolders), by path.
    public static func bundles(_ format: PluginFormat, in folders: [URL]) -> [URL] {
        var out: [URL] = []
        for folder in folders {
            guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walk where url.pathExtension.lowercased() == format.rawValue {
                out.append(url)
                walk.skipDescendants()   // a bundle is one plugin file, whatever is inside it
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Brings the catalogue up to date: probes bundles that are new or changed (all of them
    /// with `force`), keeps what is known about the rest, drops bundles that are gone.
    /// Returns how many bundles were loaded.
    @discardableResult
    public mutating func scan(with scanner: PluginScanner, folders: [PluginFormat: [URL]], force: Bool = false,
                              progress: (Double) -> Void = { _ in }, cancelled: () -> Bool = { false }) -> Int {
        var found: [(URL, PluginFormat)] = []
        for format in PluginFormat.allCases { found += Self.bundles(format, in: folders[format] ?? []).map { ($0, format) } }
        let known = Dictionary(entries.map { ($0.bundle, $0) }, uniquingKeysWith: { a, _ in a })
        var next: [Entry] = [], probed = 0
        for (i, (url, format)) in found.enumerated() {
            let modified = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
            if cancelled() {
                // Stopped half way: what was known stays known.
                if let old = known[url.path] { next.append(old) }
                continue
            }
            // What is known is kept, except where the last scan didn't get an answer (out of time, or the
            // helper said nothing): that says nothing about the plugin and is tried again every time.
            if !force, let old = known[url.path], old.modified == modified, old.format == format,
               !(old.failure.map(ProbeOutcome.retried.contains) ?? false), old.scanFailure == nil {
                next.append(old)
            } else if !force, var old = known[url.path], old.modified == modified, old.format == format, (old.failure ?? old.scanFailure) == "timed_out",
                      (old.failedScans ?? 0) >= Self.timeoutsBeforeBackingOff, (old.scansSkipped ?? 0) < Self.scansBetweenRetries - 1 {
                // It has hung twice or more: passed over this time.
                old.scansSkipped = (old.scansSkipped ?? 0) + 1
                next.append(old)
            } else {
                probed += 1
                let outcome = scanner.probe(url, format: format)
                if case .found(let plugins) = outcome {
                    next.append(Entry(bundle: url.path, format: format, modified: modified, plugins: plugins))
                } else if let reason = outcome.failure {
                    // A plugin that has been read as good isn't lost to one failed scan: it stays listed, the
                    // failure is noted beside it, and it is scanned again next time. A verdict about the
                    // plugin itself (it crashed the helper, it isn't a plugin) takes its place when it comes
                    // twice running; running out of time never does.
                    if let old = known[url.path], old.format == format, !old.plugins.isEmpty {
                        let failures = (old.failedScans ?? 0) + 1
                        if !ProbeOutcome.retried.contains(reason), failures >= Self.scansBeforeAVerdictSticks {
                            next.append(Entry(bundle: url.path, format: format, modified: modified, plugins: [], failure: reason, detail: outcome.detail))
                        } else {
                            var kept = old
                            kept.scanFailure = reason
                            kept.scanDetail = outcome.detail
                            kept.failedScans = failures
                            kept.scansSkipped = nil
                            next.append(kept)
                        }
                    } else {
                        var entry = Entry(bundle: url.path, format: format, modified: modified, plugins: [], failure: reason, detail: outcome.detail)
                        // How many scans running the same bundle has given the same answer.
                        if let old = known[url.path], old.modified == modified, old.failure == reason { entry.failedScans = (old.failedScans ?? 1) + 1 } else { entry.failedScans = 1 }
                        next.append(entry)
                    }
                }
            }
            progress(Double(i + 1) / Double(found.count))
        }
        entries = next
        return probed
    }

    // MARK: On disk

    public static func load(_ url: URL) -> PluginCatalogue {
        guard let data = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(PluginCatalogue.self, from: data) else { return PluginCatalogue() }
        return c
    }

    public func save(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
