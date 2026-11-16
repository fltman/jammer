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
    /// The helper loaded the bundle and said it isn't a usable plugin of that format. A verdict about
    /// the bundle.
    case invalid(String)
    /// No answer got through: the helper is missing or couldn't be started, it ended without saying
    /// anything that can be read, or with a status that isn't one of its own. Says nothing about the
    /// plugin; the bundle is tried again at the next scan.
    case unanswered(String)

    public var failure: String? {
        switch self {
        case .found: nil
        case .crashed: "crashed"
        case .timedOut: "timed_out"
        case .invalid: "invalid"
        case .unanswered: "scan_failed"
        }
    }

    /// Reasons that are about the scan and not about the plugin: tried again at every scan.
    public static let retried: Set<String> = ["timed_out", "scan_failed"]
    public var detail: String? {
        switch self {
        case .found, .timedOut: nil
        case .crashed(let signal): "signal \(signal)"
        case .invalid(let why), .unanswered(let why): why
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


    func profile(for bundle: URL) -> String { Confinement.profile(readable: [bundle, probe] + readable) }

    /// Loads one bundle in the helper. Never throws and never blocks longer than `timeout` (plus a moment to kill).
    public func probe(_ bundle: URL, format: PluginFormat) -> ProbeOutcome {
        guard FileManager.default.isExecutableFile(atPath: probe.path) else { return .unanswered("The scanner helper is missing.") }
        // Without the confinement there is no scan: third-party code isn't loaded unconfined.
        guard FileManager.default.isExecutableFile(atPath: Confinement.sandboxExec) else { return .unanswered("This Mac has no sandbox-exec, so plugins can't be scanned safely.") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Confinement.sandboxExec)
        process.arguments = ["-p", profile(for: bundle), probe.path, format.rawValue, bundle.path]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        // The plugin gets no keys or tokens that happen to be in Jämmer's environment.
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory()]
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        // Read while it runs, so a chatty plugin can't fill the pipe and stall itself. One reader per
        // pipe, each reading to the end and saying when it is there: the verdict below is not taken
        // until both have stored everything. (Before 2026-11-16 a handler read in the background while
        // the caller also read after the exit, and on a busy Mac the verdict could be taken between the
        // handler's read and its storing: a good plugin then gave "0 bytes" and was called invalid.)
        let collected = Collected()
        let readers = DispatchGroup()
        func read(_ pipe: Pipe, into key: ReferenceWritableKeyPath<Collected, Data>) {
            readers.enter()
            let handle = pipe.fileHandleForReading
            Thread.detachNewThread {
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }   // the end: every writer has closed it
                    collected.append(chunk, to: key)
                }
                readers.leave()
            }
        }
        do { try process.run() } catch { return .unanswered("The scanner helper couldn't be started: \(error.localizedDescription)") }
        // Our own copies of the writing ends are closed, or the readers would never see the end.
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()
        read(out, into: \.out)
        read(err, into: \.err)
        if done.wait(timeout: .now() + timeout) == .timedOut {
            // It hangs: ask, then insist. SIGKILL can't be ignored.
            process.terminate()
            if done.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                done.wait()
            }
            return .timedOut
        }
        if process.terminationReason == .uncaughtSignal { return .crashed(signal: process.terminationStatus) }
        // The helper is gone, so its ends of the pipes are closed and the readers finish at once. A
        // plugin that left a child of its own holding a pipe open is not waited for longer than this.
        let complete = readers.wait(timeout: .now() + 5) == .success
        let (stdout, stderr) = collected.take()
        let said = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // The helper's own way of saying "this isn't a plugin": status 2 and the reason. That is a
        // verdict about the bundle. Any other status is the scan not getting an answer.
        if process.terminationStatus == Self.notAPlugin { return .invalid(said.isEmpty ? "The helper found no plugin in the bundle." : String(said.prefix(200))) }
        guard process.terminationStatus == 0 else {
            return .unanswered("The helper ended with status \(process.terminationStatus)\(said.isEmpty ? "" : ": " + String(said.prefix(200)))")
        }
        struct Answer: Decodable {
            struct P: Decodable { var id: String; var name: String?; var vendor: String?; var version: String?; var features: [String]? }
            var plugins: [P]
        }
        // What a plugin prints is data, never trusted further than its shape.
        guard let line = String(decoding: stdout, as: UTF8.self).split(separator: "\n").last(where: { $0.hasPrefix("{") }),
              let answer = try? JSONDecoder().decode(Answer.self, from: Data(line.utf8)) else {
            // It ended well and there is nothing to read as an answer: not something a plugin did.
            return .unanswered("The helper's answer couldn't be read (\(stdout.count) bytes out, \(stderr.count) bytes of errors\(complete ? "" : ", its output was still open")).")
        }
        guard !answer.plugins.isEmpty else { return .invalid("The bundle has no plugins.") }
        return .found(answer.plugins.map {
            ScannedPlugin(format: format, id: String($0.id.prefix(256)), name: String(($0.name ?? $0.id).prefix(256)), vendor: String(($0.vendor ?? "").prefix(256)),
                          version: String(($0.version ?? "").prefix(64)), features: ($0.features ?? []).prefix(32).map { String($0.prefix(64)) }, bundle: bundle.path)
        })
    }

    /// The status the helper ends with when it loaded the bundle and it isn't a plugin (see PluginProbe).
    static let notAPlugin: Int32 = 2

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

/// What a helper is confined to while a plugin's code runs in it: no network, nothing written
/// anywhere, and of the user's files only what is listed (the plugin folders, the bundle).
/// The system, frameworks and the helper stay readable, or nothing could load; names and sizes
/// of files can be seen, since finding a bundle means walking down to it, but not what is in them.
public enum Confinement {
    public static let sandboxExec = "/usr/bin/sandbox-exec"
    public static var available: Bool { FileManager.default.isExecutableFile(atPath: sandboxExec) }

    public static func profile(readable: [URL]) -> String {
        // realpath, not Foundation's resolving: that one drops "/private", and the sandbox sees the real path.
        func real(_ u: URL) -> String { realpath(u.path, nil).map { p in defer { free(p) }; return String(cString: p) } ?? u.path }
        func q(_ u: URL) -> String { "\"" + real(u).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let allowed = readable.map { "(allow file-read* (subpath \(q($0))))" }.joined(separator: "\n")
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
}
