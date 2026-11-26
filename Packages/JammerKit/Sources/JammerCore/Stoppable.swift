import Foundation

/// Work moved off the caller's thread that a Stop must still reach. A `Task.detached` is never cancelled with the
/// task that awaits it, so `Task.isCancelled` read inside it is always false: a stop asked of the caller never got
/// to the work (the plugin scan, 2026-11-26). Here the caller's cancellation sets a flag the work reads.
public enum Stoppable {
    public final class Signal: @unchecked Sendable {
        private let lock = NSLock()
        private var set = false
        public init() {}
        public func stop() { lock.withLock { set = true } }
        public var isSet: Bool { lock.withLock { set } }
    }

    /// Runs `work` detached; it is given a function that says whether the awaiting task has been stopped since.
    /// Returns what the work returned, and whether a stop came.
    public static func run<T: Sendable>(priority: TaskPriority = .utility,
                                        _ work: @escaping @Sendable (_ stopped: @escaping @Sendable () -> Bool) -> T) async -> (value: T, stopped: Bool) {
        let signal = Signal()
        let value = await withTaskCancellationHandler {
            await Task.detached(priority: priority) { work { signal.isSet } }.value
        } onCancel: {
            signal.stop()
        }
        return (value, signal.isSet)
    }
}

/// What Edit › Stop Job (⌘.) stops: the frontmost document's own newest work (a wait in its window, or a job of its),
/// and what Jämmer does for another app (Flimmer's live captions) only when the document has nothing of its own going.
public enum StopChoice {
    public enum Kind: Equatable, Sendable { case wait, job, otherApp }
    public struct Candidate: Equatable, Sendable {
        public var id: String
        public var kind: Kind
        public var started: Date
        public init(id: String, kind: Kind, started: Date) { self.id = id; self.kind = kind; self.started = started }
    }

    public static func pick(_ candidates: [Candidate]) -> Candidate? {
        if let newest = candidates.filter({ $0.kind != .otherApp }).max(by: { $0.started < $1.started }) { return newest }
        return candidates.first { $0.kind == .otherApp }
    }
}


/// At most `limit` of a kind of work at once (the waveforms' peaks, 2026-11-26: eight sources built all together at a
/// document's opening crowded each other and the main actor). The rest wait their turn, in order.
public actor TaskLimit {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    public init(_ limit: Int) { self.limit = max(1, limit) }

    public func run<T: Sendable>(_ work: @Sendable () async -> T) async -> T {
        if running >= limit { await withCheckedContinuation { waiting.append($0) } } else { running += 1 }
        defer { if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() } }
        return await work()
    }
}

/// Says whether enough time has passed since it last said yes: progress sent on at most so many times a second, not
/// for every chunk of work (each one a hop to the main actor).
public final class Throttle: @unchecked Sendable {
    private let interval: TimeInterval
    private let lock = NSLock()
    private var last = Date.distantPast
    public init(perSecond: Double) { interval = 1 / perSecond }
    public func ready(now: Date = Date()) -> Bool {
        lock.withLock {
            guard now.timeIntervalSince(last) >= interval else { return false }
            last = now
            return true
        }
    }
}
