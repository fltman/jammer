import Foundation
import Testing
@testable import JammerCore

/// Set by the work at its first look.
final class Begun: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func mark() { lock.lock(); flag = true; lock.unlock() }
    var yes: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

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
        // Stopped once the work has begun (not after a time: a loaded Mac took 46 s over a 50 ms wait, 2026-11-26),
        // and the work, which would run 30 s, ends at its next look.
        let begun = Begun()
        let outer = Task { await Stoppable.run { stopped in Self.steps(limit: 3_000) { begun.mark(); return stopped() } } }
        while !begun.yes { try? await Task.sleep(for: .milliseconds(5)) }
        outer.cancel()
        let (n, stopped) = await outer.value
        #expect(stopped && n < 3_000, "stopped after \(n) steps")
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

@Suite("Peaks built in turn, stoppable, and a cache never trusted further than it holds together")
struct PeakWorkTests {
    func folder() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "jammer-peaks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test("A cached index reads back; one whose count doesn't fit its frames, with a value that isn't a number, or cut short is built again")
    func cacheRead() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let samples = (0..<10_000).map { Float(sin(Double($0) * 0.01)) }
        let index = try #require(PeakIndex.build(reading: { at, n in Array(samples[Int(at)..<min(samples.count, Int(at) + n)]) }, channels: 1, frames: 10_000))
        let good = dir.appending(path: "good.peaks")
        try index.write(to: good)
        #expect(PeakIndex.read(from: good)?.frames == 10_000)
        var data = try Data(contentsOf: good)
        // Frames that call for another count than the file holds (the header at 12…19).
        var bad = data
        bad.replaceSubrange(12..<20, with: withUnsafeBytes(of: UInt64(100_000).littleEndian) { Data($0) })
        try bad.write(to: dir.appending(path: "count.peaks"))
        #expect(PeakIndex.read(from: dir.appending(path: "count.peaks")) == nil)
        // A value that isn't a number.
        data.replaceSubrange(28..<32, with: withUnsafeBytes(of: Float.nan.bitPattern.littleEndian) { Data($0) })
        try data.write(to: dir.appending(path: "nan.peaks"))
        #expect(PeakIndex.read(from: dir.appending(path: "nan.peaks")) == nil)
        try Data(try Data(contentsOf: good).prefix(40)).write(to: dir.appending(path: "short.peaks"))
        #expect(PeakIndex.read(from: dir.appending(path: "short.peaks")) == nil)
    }

    @Test("The cache's key changes when the file does (its size or its date)")
    func cacheKey() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "a.wav")
        let w = try WAVWriter(url: url, options: .init(encoding: .int16, channels: 1, sampleRate: 48_000))
        try w.write([Float](repeating: 0.1, count: 4_800)); try w.finish()
        let info = try AudioFileReader.info(at: url)
        let before = PeakIndex.cacheKey(for: url, info: info)
        #expect(PeakIndex.cacheKey(for: url, info: info) == before, "the same file, the same key")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: url.path)
        #expect(PeakIndex.cacheKey(for: url, info: info) != before, "touched: another key")
    }

    @Test("A build stopped half way gives no index")
    func stoppedBuild() {
        var asked = 0
        let index = PeakIndex.build(reading: { _, n in [Float](repeating: 0.2, count: n) }, channels: 1, frames: 48_000 * 600, progress: { _ in
            asked += 1
            return asked < 3
        })
        #expect(index == nil && asked == 3)
    }

    @Test("At most two at a time, every one run, in order of arrival")
    func limit() async {
        let limit = TaskLimit(2)
        let counter = Counter2()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await limit.run {
                        counter.enter()
                        try? await Task.sleep(for: .milliseconds(20))
                        counter.leave()
                    }
                }
            }
        }
        #expect(counter.most == 2 && counter.done == 8)
    }

    @Test("Progress at most four times a second")
    func throttle() {
        let t = Throttle(perSecond: 4)
        let t0 = Date()
        let passed = (0..<1_000).filter { t.ready(now: t0.addingTimeInterval(Double($0) / 1_000)) }.count
        #expect(passed == 4, "\(passed) in one second")
    }
}

final class Counter2: @unchecked Sendable {
    private let lock = NSLock()
    private var now = 0
    private(set) var most = 0, done = 0
    func enter() { lock.withLock { now += 1; most = max(most, now) } }
    func leave() { lock.withLock { now -= 1; done += 1 } }
}
