import Foundation

/// The first of a piece of work and a time limit, answered once (the-apps COMFORT.md 7b3c2e1, Glimmer's finding):
/// a task group with the work and a timer in it doesn't answer at the limit, since a group returns only when every
/// child has, and work that doesn't stop when cancelled (a model's answer, a request) holds it as long as it runs.
/// Here a continuation is resumed by whichever comes first and never again; the work is cancelled at the limit and
/// whatever it gives later is dropped.
public enum Deadline {
    /// `work`'s value, or nil if `seconds` pass first.
    public static func first<T: Sendable>(within seconds: Double, _ work: @escaping @Sendable () async -> T?) async -> T? {
        let once = Once<T?>()
        return await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            once.continuation = c
            let job = Task { once.resume(with: await work()) }
            // The limit on a dispatch queue, not a task: it fires even while Swift's shared threads are all busy
            // (seen in the full test suite, where a task's sleep came 40 s late).
            let timer = DispatchWorkItem { if once.resume(with: nil) { job.cancel() } }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + max(0, seconds), execute: timer)
            once.afterFirst { timer.cancel() }
        }
    }

    /// Resumed by the first caller only.
    private final class Once<V: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        /// Set before either task starts.
        var continuation: CheckedContinuation<V, Never>?
        private var onFirst: (() -> Void)?
        /// Run once the answer is given: now, if it already has been.
        func afterFirst(_ f: @escaping () -> Void) {
            lock.lock()
            if done { lock.unlock(); f(); return }
            onFirst = f
            lock.unlock()
        }
        /// True for the one call that answered.
        @discardableResult func resume(with value: V) -> Bool {
            lock.lock()
            guard !done, let c = continuation else { lock.unlock(); return false }
            done = true
            continuation = nil
            let after = onFirst
            onFirst = nil
            lock.unlock()
            c.resume(returning: value)
            after?()
            return true
        }
    }
}
