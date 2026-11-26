import Foundation
import Testing
@testable import JammerCore

@Suite("Stopping work that runs detached")
struct StoppableTests {
    /// Steps of 10 ms until `stopped` says so, or `limit` steps.
    static func steps(limit: Int, _ stopped: () -> Bool) -> Int {
        var n = 0
        while n < limit, !stopped() { Thread.sleep(forTimeInterval: 0.01); n += 1 }
        return n
    }

    @Test("Before: work in a detached task reads Task.isCancelled as false, so a stop of the task awaiting it never reaches it (the plugin scan)")
    func detachedIgnoresTheStop() async {
        let outer = Task { await Task.detached { Self.steps(limit: 40) { Task.isCancelled } }.value }
        try? await Task.sleep(for: .milliseconds(50))
        outer.cancel()
        #expect(await outer.value == 40, "ran every step")
    }

    @Test("Stoppable.run: the stop reaches the work at its next look, and is said")
    func stops() async {
        let outer = Task { await Stoppable.run { stopped in Self.steps(limit: 500, stopped) } }
        try? await Task.sleep(for: .milliseconds(50))
        outer.cancel()
        let (n, stopped) = await outer.value
        #expect(stopped && n < 100, "stopped after \(n) steps")
        let (all, never) = await Stoppable.run { stopped in Self.steps(limit: 3, stopped) }
        #expect(all == 3 && !never, "not stopped: done, and said so")
    }
}

@Suite("Edit › Stop Job: what it stops")
struct StopChoiceTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Another app's wait (newest, listed last) gives way to the document's own newest work, a job or a wait")
    func ownFirst() {
        let caption = StopChoice.Candidate(id: "turn", kind: .otherApp, started: t0.addingTimeInterval(30))
        let job = StopChoice.Candidate(id: "transcribe", kind: .job, started: t0.addingTimeInterval(20))
        let export = StopChoice.Candidate(id: "export", kind: .wait, started: t0.addingTimeInterval(10))
        #expect(StopChoice.pick([export, job, caption])?.id == "transcribe", "the newest of the document's own")
        #expect(StopChoice.pick([job, export, caption].reversed())?.id == "transcribe", "whatever the order they are listed in")
        let later = StopChoice.Candidate(id: "preview", kind: .wait, started: t0.addingTimeInterval(25))
        #expect(StopChoice.pick([job, later, caption])?.id == "preview")
    }

    @Test("Only another app's wait: that is stopped; nothing going: nothing")
    func otherOnly() {
        let caption = StopChoice.Candidate(id: "turn", kind: .otherApp, started: t0)
        #expect(StopChoice.pick([caption])?.id == "turn")
        #expect(StopChoice.pick([]) == nil)
    }
}
