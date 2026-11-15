import Foundation

/// One VST 3 or CLAP plugin, running in a helper process of its own (`jammer-plugin-host`).
/// Jämmer never loads the plugin's code: it sends blocks of sound down a pipe and reads them
/// back. If the helper dies or stops answering, this object says so (`died`), every later
/// block passes through unprocessed, and nothing else is affected.
public final class PluginHostProcess: @unchecked Sendable {
    public struct Parameter: Sendable, Equatable {
        public var id: UInt32
        public var name: String
        public var module: String
        public var min: Double, max: Double, value: Double, initial: Double
        public var stepped: Bool, readonly: Bool, hidden: Bool

        public init(id: UInt32, name: String, module: String, min: Double, max: Double, value: Double, initial: Double, stepped: Bool, readonly: Bool, hidden: Bool) {
            self.id = id
            self.name = name
            self.module = module
            self.min = min
            self.max = max
            self.value = value
            self.initial = initial
            self.stepped = stepped
            self.readonly = readonly
            self.hidden = hidden
        }
    }

    public enum Death: Sendable, Equatable {
        /// The helper was killed by a signal (the plugin crashed).
        case crashed(signal: Int32)
        /// No answer within the time limit; the helper was killed.
        case hung
        /// The helper went away without a signal (it exited, or was told to).
        case exited

        public var description: String {
            switch self {
            case .crashed: "crashed"
            case .hung: "stopped answering"
            case .exited: "quit"
            }
        }
    }

    public struct StartError: Error, LocalizedError, Equatable {
        public var message: String
        public var errorDescription: String? { message }
    }

    public let format: PluginFormat
    public let channels: Int
    public let maxFrames: Int
    public private(set) var latency = 0
    public private(set) var parameters: [Parameter] = []
    /// Set once, when the helper is found dead or hung. Read from any thread.
    public var died: Death? { lock.withLock { death } }
    /// Called once (on whatever thread noticed) when the helper dies while in use.
    public var onDeath: (@Sendable (Death) -> Void)?
    /// The helper's process id, for tests that kill it.
    public var processIdentifier: Int32 { process.processIdentifier }

    private let process = Process()
    private let toHelper: FileHandle, fromHelper: FileHandle
    private let lock = NSLock()
    private var death: Death?
    private let timeout: Double
    private var blockBytes: [UInt8] = []

    /// Starts the helper, confined (no network, no writes, of the user's files only `readable`
    /// and the bundle), and opens the plugin in it. Throws with the plugin's own reason when it won't start.
    public init(helper: URL, format: PluginFormat, bundle: URL, id: String, sampleRate: Double, channels: Int, maxFrames: Int = 512,
                readable: [URL] = PluginScanner.pluginFolders(.vst3) + PluginScanner.pluginFolders(.clap), timeout: Double = 10) throws {
        self.format = format
        self.channels = channels
        self.maxFrames = maxFrames
        self.timeout = timeout
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw StartError(message: "The plugin host helper is missing.") }
        guard Confinement.available else { throw StartError(message: "This Mac has no sandbox-exec, so plugins can't be run safely.") }
        let input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: Confinement.sandboxExec)
        process.arguments = ["-p", Confinement.profile(readable: [bundle, helper] + readable), helper.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // No keys or tokens from Jämmer's environment reach the plugin.
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory()]
        toHelper = input.fileHandleForWriting
        fromHelper = output.fileHandleForReading
        // Writing to a helper that has died must be an error here, not a signal that kills Jämmer.
        _ = fcntl(toHelper.fileDescriptor, F_SETNOSIGPIPE, 1)
        do { try process.run() } catch { throw StartError(message: "The plugin host helper couldn't be started: \(error.localizedDescription)") }
        var open = Data()
        for part in [format.rawValue, bundle.path, id] { open.append(Data(part.utf8)); open.append(0) }
        withUnsafeBytes(of: sampleRate) { open.append(contentsOf: $0) }
        withUnsafeBytes(of: Int32(channels)) { open.append(contentsOf: $0) }
        withUnsafeBytes(of: Int32(maxFrames)) { open.append(contentsOf: $0) }
        let (status, answer): (UInt32, Data)
        do { (status, answer) = try lock.withLock { try call(1, open) } } catch {
            let d = died
            throw StartError(message: "The plugin \(d?.description ?? "failed") while it was being loaded.")
        }
        guard status == 0 else {
            shutDown()
            throw StartError(message: String(decoding: answer, as: UTF8.self))
        }
        describe(answer)
    }

    deinit { shutDown() }

    // MARK: Sound

    /// One block, planar: `input[c]` and `output[c]` hold `frames` samples each. False when the
    /// plugin didn't process it (it failed, or its helper is dead); the output is then the input.
    @discardableResult
    public func process(_ input: UnsafePointer<UnsafePointer<Float>>, _ output: UnsafePointer<UnsafeMutablePointer<Float>>, frames: Int) -> Bool {
        func passThrough() { for c in 0..<channels where UnsafePointer(output[c]) != input[c] { output[c].update(from: input[c], count: frames) } }
        guard frames > 0 else { return true }
        return lock.withLock {
            guard death == nil, frames <= maxFrames else { passThrough(); return false }
            let bytes = 4 + channels * frames * 4
            var payload = Data(count: bytes)
            payload.withUnsafeMutableBytes { b in
                b.storeBytes(of: Int32(frames), as: Int32.self)
                for c in 0..<channels { memcpy(b.baseAddress! + 4 + c * frames * 4, input[c], frames * 4) }
            }
            guard let (status, answer) = try? call(2, payload), answer.count == bytes else { passThrough(); return false }
            guard status == 0 else { passThrough(); return false }
            answer.withUnsafeBytes { b in
                for c in 0..<channels { memcpy(output[c], b.baseAddress! + 4 + c * frames * 4, frames * 4) }
            }
            return true
        }
    }

    public func reset() { lock.withLock { _ = try? call(3, Data()) } }

    // MARK: Parameters and state

    @discardableResult
    public func set(_ id: UInt32, to value: Double) -> Bool {
        var payload = Data()
        withUnsafeBytes(of: id) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: value) { payload.append(contentsOf: $0) }
        return lock.withLock { (try? call(4, payload))?.0 == 0 }
    }

    /// Reads the parameters again (their current values, and the latency).
    public func refresh() {
        lock.withLock {
            if let (status, answer) = try? call(5, Data()), status == 0 { describe(answer) }
        }
    }

    public func saveState() -> Data? { lock.withLock { (try? call(6, Data())).flatMap { $0.0 == 0 ? $0.1 : nil } } }

    @discardableResult
    public func loadState(_ data: Data) -> Bool { lock.withLock { (try? call(7, data))?.0 == 0 } }

    // MARK: The pipe

    private struct Dead: Error {}

    /// One request and its answer. Called with the lock held. Throws when the helper is dead or
    /// doesn't answer in time (it is then killed and marked).
    private func call(_ op: UInt32, _ payload: Data) throws -> (UInt32, Data) {
        guard death == nil else { throw Dead() }
        var frame = Data()
        withUnsafeBytes(of: op) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(payload.count)) { frame.append(contentsOf: $0) }
        frame.append(payload)
        guard writeAll(frame) else { markDead(hung: false); throw Dead() }
        let deadline = Date().addingTimeInterval(timeout)
        guard let head = readExactly(8, deadline: deadline) else { throw Dead() }
        let status = head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let length = head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
        guard length <= 64 << 20 else { markDead(hung: false); throw Dead() }
        guard let body = length == 0 ? Data() : readExactly(Int(length), deadline: deadline) else { throw Dead() }
        return (status, body)
    }

    private func writeAll(_ data: Data) -> Bool {
        data.withUnsafeBytes { b -> Bool in
            var at = 0
            while at < b.count {
                let n = write(toHelper.fileDescriptor, b.baseAddress! + at, b.count - at)
                if n < 0 { if errno == EINTR { continue }; return false }
                at += n
            }
            return true
        }
    }

    private func readExactly(_ count: Int, deadline: Date) -> Data? {
        var data = Data(count: count), at = 0
        let fd = fromHelper.fileDescriptor
        while at < count {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let wait = Swift.max(0, deadline.timeIntervalSinceNow)
            let ready = poll(&p, 1, Int32(wait * 1000))
            if ready == 0 { markDead(hung: true); return nil }
            if ready < 0 { if errno == EINTR { continue }; markDead(hung: false); return nil }
            let n = data.withUnsafeMutableBytes { read(fd, $0.baseAddress! + at, count - at) }
            if n == 0 { markDead(hung: false); return nil }          // the pipe closed: the helper is gone
            if n < 0 { if errno == EINTR { continue }; markDead(hung: false); return nil }
            at += n
        }
        return data
    }

    /// Called with the lock held, once.
    private func markDead(hung: Bool) {
        guard death == nil else { return }
        if hung {
            // It may be stuck for good: SIGKILL can't be ignored.
            kill(process.processIdentifier, SIGKILL)
            death = .hung
        } else {
            // Give the kernel a moment to report how it ended.
            let until = Date().addingTimeInterval(1)
            while process.isRunning, Date() < until { usleep(2_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL); death = .hung }
            else { death = process.terminationReason == .uncaughtSignal ? .crashed(signal: process.terminationStatus) : .exited }
        }
        if let death, let onDeath { onDeath(death) }
    }

    private func shutDown() {
        lock.withLock {
            if death == nil, process.isRunning {
                _ = try? call(8, Data())
                death = death ?? .exited
            }
        }
        try? toHelper.close()
        if process.isRunning {
            let until = Date().addingTimeInterval(1)
            while process.isRunning, Date() < until { usleep(2_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    /// `jph_param` as the helper sends it (the C struct's layout; a test pins it).
    static let parameterSize = 560

    private func describe(_ d: Data) {
        guard d.count >= 8 else { return }
        d.withUnsafeBytes { b in
            latency = Int(b.loadUnaligned(as: Int32.self))
            let n = Int(b.loadUnaligned(fromByteOffset: 4, as: Int32.self))
            guard n >= 0, d.count >= 8 + n * Self.parameterSize else { return }
            func text(_ offset: Int) -> String {
                let raw = UnsafeRawBufferPointer(rebasing: b[offset..<(offset + 256)])
                return String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            parameters = (0..<n).map { i in
                let o = 8 + i * Self.parameterSize
                func f(_ at: Int) -> Double { b.loadUnaligned(fromByteOffset: o + at, as: Double.self) }
                func flag(_ at: Int) -> Bool { b[o + at] != 0 }
                return Parameter(id: b.loadUnaligned(fromByteOffset: o, as: UInt32.self), name: text(o + 4), module: text(o + 260),
                                 min: f(520), max: f(528), value: f(536), initial: f(544), stepped: flag(552), readonly: flag(553), hidden: flag(554))
            }
        }
    }
}
