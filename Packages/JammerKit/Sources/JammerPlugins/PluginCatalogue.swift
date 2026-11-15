import Foundation

/// What a scan found, kept between launches: per bundle and modification date, so only new
/// and changed bundles are loaded again, and a bundle that crashed or hung isn't tried again
/// until it changes (or the user asks).
public struct PluginCatalogue: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var bundle: String
        public var format: PluginFormat
        public var modified: Date
        public var plugins: [ScannedPlugin]
        /// "crashed", "timed_out" or "invalid" when the bundle gave nothing.
        public var failure: String?
        public var detail: String?
    }

    public struct Failure: Sendable, Equatable {
        public var name: String
        public var format: PluginFormat
        /// "crashed", "timed_out", "invalid", or "blocked" (switched off after it took Jämmer down).
        public var reason: String
    }

    public var entries: [Entry] = []
    /// Plugin ids ("clap:…", "vst3:…") switched off after a crash while they were in use.
    /// Only the user switches one on again, in the app.
    public var blocked: Set<String> = []

    public init() {}

    public static func key(_ p: ScannedPlugin) -> String { "\(p.format.rawValue):\(p.id)" }

    /// The plugins that can be used: found, and not blocked.
    public var plugins: [ScannedPlugin] { entries.flatMap(\.plugins).filter { !blocked.contains(Self.key($0)) } }

    public var failed: [Failure] {
        entries.compactMap { e in e.failure.map { Failure(name: URL(fileURLWithPath: e.bundle).deletingPathExtension().lastPathComponent, format: e.format, reason: $0) } }
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
            if !force, let old = known[url.path], old.modified == modified, old.format == format {
                next.append(old)
            } else {
                probed += 1
                switch scanner.probe(url, format: format) {
                case .found(let plugins): next.append(Entry(bundle: url.path, format: format, modified: modified, plugins: plugins))
                case .crashed(let signal): next.append(Entry(bundle: url.path, format: format, modified: modified, plugins: [], failure: "crashed", detail: "signal \(signal)"))
                case .timedOut: next.append(Entry(bundle: url.path, format: format, modified: modified, plugins: [], failure: "timed_out"))
                case .invalid(let why): next.append(Entry(bundle: url.path, format: format, modified: modified, plugins: [], failure: "invalid", detail: why))
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
