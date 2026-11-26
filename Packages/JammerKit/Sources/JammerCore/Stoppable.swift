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
