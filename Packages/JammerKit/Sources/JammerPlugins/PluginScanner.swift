import Foundation

/// Finds VST 3 and CLAP plugins without letting them into Jämmer's process: each bundle is
/// loaded by a helper (`jammer-plugin-probe`) that prints what it found and exits. A bundle
/// that crashes the helper or hangs it past the time limit is recorded as failed, and the
/// scan goes on. Results are remembered per bundle and modification date, so only new and
/// changed bundles are loaded again.
public enum PluginFormat: String, Codable, Sendable, CaseIterable { case vst3, clap }

public struct ScannedPlugin: Codable, Sendable, Equatable {
    public var format: PluginFormat
    /// The format's own identity: a CLAP plugin id, or a VST 3 class id as 32 hex digits.
    public var id: String
    public var name: String
    public var vendor: String
    public var version: String
    public var features: [String]
    public var bundle: String
}

public enum ProbeOutcome: Sendable, Equatable {
    case found([ScannedPlugin])
    /// The helper died while the bundle was loaded (the signal, e.g. 6 for abort, 11 for a bad access).
    case crashed(signal: Int32)
    case timedOut
    /// Loaded without incident but isn't a usable plugin of that format.
    case invalid(String)

    public var failure: String? {
        switch self {
        case .found: nil
        case .crashed: "crashed"
        case .timedOut: "timed_out"
        case .invalid: "invalid"
        }
    }
}

public struct PluginScanner: Sendable {
    public var probe: URL
    /// Seconds one bundle may take to load and answer.
    public var timeout: Double

    /// Folders the helper may read besides the bundle it is given (the plugin folders).
    public var readable: [URL]

    public init(probe: URL, timeout: Double = 20, readable: [URL] = PluginScanner.pluginFolders(.vst3) + PluginScanner.pluginFolders(.clap)) {
        self.probe = probe
        self.timeout = timeout
        self.readable = readable
    }

    /// Where each format's plugins are installed: the user's folder, then the Mac's.
    public static func pluginFolders(_ format: PluginFormat) -> [URL] {
        let name = format == .vst3 ? "VST3" : "CLAP"
        return [URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Audio/Plug-Ins/\(name)"), URL(fileURLWithPath: "/Library/Audio/Plug-Ins/\(name)")]
    }

    static let sandboxExec = "/usr/bin/sandbox-exec"

    /// What the helper is confined to while a plugin's code runs in it: no network, nothing
    /// written anywhere, and of the user's files only the plugin folders and the bundle itself.
    /// (The system, frameworks and the helper stay readable, or nothing could load; names and
    /// sizes of files can be seen, since finding a bundle means walking down to it, but not what is in them.)
    func profile(for bundle: URL) -> String {
        // realpath, not Foundation's resolving: that one drops "/private", and the sandbox sees the real path.
        func real(_ u: URL) -> String { realpath(u.path, nil).map { p in defer { free(p) }; return String(cString: p) } ?? u.path }
        func q(_ u: URL) -> String { "\"" + real(u).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let allowed = ([bundle, probe] + readable).map { "(allow file-read* (subpath \(q($0))))" }.joined(separator: "\n")
        return """
        (version 1)
        (allow default)
        (deny network*)
        (deny file-write*)
        (allow file-write* (literal "/dev/null") (literal "/dev/stdout") (literal "/dev/stderr"))
        (deny file-read* (subpath "/Users") (subpath "/Volumes") (subpath "/private/var/folders") (subpath "/private/tmp") (subpath "/Library/Application Support"))
        (allow file-read-metadata)
        \(allowed)
        """
    }

    /// Loads one bundle in the helper. Never throws and never blocks longer than `timeout` (plus a moment to kill).
    public func probe(_ bundle: URL, format: PluginFormat) -> ProbeOutcome {
        guard FileManager.default.isExecutableFile(atPath: probe.path) else { return .invalid("The scanner helper is missing.") }
        // Without the confinement there is no scan: third-party code isn't loaded unconfined.
        guard FileManager.default.isExecutableFile(atPath: Self.sandboxExec) else { return .invalid("This Mac has no sandbox-exec, so plugins can't be scanned safely.") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.sandboxExec)
        process.arguments = ["-p", profile(for: bundle), probe.path, format.rawValue, bundle.path]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        // The plugin gets no keys or tokens that happen to be in Jämmer's environment.
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory()]
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        // Read while it runs, so a chatty plugin can't fill the pipe and stall itself.
        let collected = Collected()
        out.fileHandleForReading.readabilityHandler = { h in collected.append(h.availableData, to: \.out) }
        err.fileHandleForReading.readabilityHandler = { h in collected.append(h.availableData, to: \.err) }
        defer {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
        }
        do { try process.run() } catch { return .invalid("The scanner helper couldn't be started: \(error.localizedDescription)") }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            // It hangs: ask, then insist. SIGKILL can't be ignored.
            process.terminate()
            if done.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                done.wait()
            }
            return .timedOut
        }
        collected.append(out.fileHandleForReading.readDataToEndOfFile(), to: \.out)
        collected.append(err.fileHandleForReading.readDataToEndOfFile(), to: \.err)
        if process.terminationReason == .uncaughtSignal { return .crashed(signal: process.terminationStatus) }
        let (stdout, stderr) = collected.take()
        guard process.terminationStatus == 0 else {
            let why = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return .invalid(why.isEmpty ? "The helper exited with \(process.terminationStatus)." : String(why.prefix(200)))
        }
        struct Answer: Decodable {
            struct P: Decodable { var id: String; var name: String?; var vendor: String?; var version: String?; var features: [String]? }
            var plugins: [P]
        }
        // What a plugin prints is data, never trusted further than its shape.
        guard let line = String(decoding: stdout, as: UTF8.self).split(separator: "\n").last(where: { $0.hasPrefix("{") }),
              let answer = try? JSONDecoder().decode(Answer.self, from: Data(line.utf8)) else {
            return .invalid("The helper's answer couldn't be read.")
        }
        guard !answer.plugins.isEmpty else { return .invalid("The bundle has no plugins.") }
        return .found(answer.plugins.map {
            ScannedPlugin(format: format, id: String($0.id.prefix(256)), name: String(($0.name ?? $0.id).prefix(256)), vendor: String(($0.vendor ?? "").prefix(256)),
                          version: String(($0.version ?? "").prefix(64)), features: ($0.features ?? []).prefix(32).map { String($0.prefix(64)) }, bundle: bundle.path)
        })
    }

    final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        var out = Data(), err = Data()
        func append(_ d: Data, to key: ReferenceWritableKeyPath<Collected, Data>) {
            guard !d.isEmpty else { return }
            // The answer is the last line, so when a plugin floods the output it is the tail that is kept.
            lock.withLock {
                self[keyPath: key].append(d)
                if self[keyPath: key].count > 1 << 20 { self[keyPath: key] = Data(self[keyPath: key].suffix(1 << 18)) }
            }
        }
        func take() -> (Data, Data) { lock.withLock { (out, err) } }
    }
}
