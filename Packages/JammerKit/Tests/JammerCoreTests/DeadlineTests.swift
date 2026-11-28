import Foundation
import Testing
@testable import JammerCore

/// The first of a piece of work and a time limit (the-apps COMFORT.md 7b3c2e1): answered at the limit even when the
/// work goes on and doesn't stop when cancelled, and once only.
@Suite("Deadline: the first of the work and the limit, answered once")
struct DeadlineTests {
    /// Work that ignores cancellation and finishes only when released.
    final class Held: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: CheckedContinuation<Void, Never>?
        private var released = false
        private(set) var finished = false
        func wait() async {
            await withCheckedContinuation { c in
                lock.lock()
                if released { lock.unlock(); c.resume() } else { waiting = c; lock.unlock() }
            }
            lock.withLock { finished = true }
        }
        func release() { lock.lock(); released = true; let w = waiting; waiting = nil; lock.unlock(); w?.resume() }
    }

    @Test("Work held past the limit: nil at the limit, while the work still runs; the work, released later, changes nothing")
    func heldPastTheLimit() async throws {
        // (Held until after the answer: a task group would never answer here, since it waits for the work. No
        // wall-clock bound: the full suite keeps Swift's shared threads busy enough to delay any answer.)
        let held = Held()
        let answer: String? = await Deadline.first(within: 0.2) { await held.wait(); return "late" }
        #expect(answer == nil)
        #expect(!held.finished, "the answer came while the work was still held")
        held.release()
        try await Task.sleep(for: .milliseconds(100))
        #expect(held.finished, "and ends later without a second answer (a second resume would trap)")
    }

    @Test("Work quicker than the limit: its value")
    func quickWork() async {
        let answer: Int? = await Deadline.first(within: 60) { 42 }
        #expect(answer == 42)
    }

    @Test("Many at once, each answered once")
    func many() async {
        await withTaskGroup(of: Int?.self) { g in
            for i in 0..<200 { g.addTask { await Deadline.first(within: i % 2 == 0 ? 0.01 : 1) { try? await Task.sleep(for: .milliseconds(i % 2 == 0 ? 200 : 1)); return i } } }
            var answers = 0
            for await _ in g { answers += 1 }
            #expect(answers == 200)
        }
    }
}
