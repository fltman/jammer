import Foundation
import os

/// Step timings for the performance pass (Debug builds only; nothing in a release): each step is an os_signpost
/// interval (Instruments shows them under the subsystem com.brattoo.jammer, category perf) and a line in the system
/// log, "perf <step> <detail> <ms> ms", which a GUI check reads back with `log show`.
enum Perf {
    #if DEBUG
    static let signposter = OSSignposter(subsystem: "com.brattoo.jammer", category: "perf")
    static let log = Logger(subsystem: "com.brattoo.jammer", category: "perf")
    #endif

    /// Times `work` as the step `name`.
    @discardableResult
    static func measure<T>(_ name: StaticString, _ detail: @autoclosure () -> String = "", _ work: () throws -> T) rethrows -> T {
        #if DEBUG
        let span = Span(name)
        defer { span.end(detail()) }
        #endif
        return try work()
    }

    #if DEBUG
    @MainActor private static var counts: [String: Int] = [:]
    @MainActor private static var countedSince = ProcessInfo.processInfo.systemUptime
    #endif

    /// How often something happens (a view drawn, say): counted, and said in the log at most once a second while it
    /// happens, "perf count <name> <n> in <s> s".
    @MainActor static func count(_ name: String) {
        #if DEBUG
        counts[name, default: 0] += 1
        let now = ProcessInfo.processInfo.systemUptime
        guard now - countedSince >= 1 else { return }
        for (what, n) in counts.sorted(by: { $0.key < $1.key }) {
            log.notice("perf count \(what, privacy: .public) \(n) in \(now - countedSince, format: .fixed(precision: 2), privacy: .public) s")
        }
        counts = [:]
        countedSince = now
        #endif
    }

    /// A step that ends somewhere else (an async job).
    struct Span: @unchecked Sendable {
        #if DEBUG
        let name: StaticString
        let state: OSSignpostIntervalState
        let started: UInt64
        #endif
        init(_ name: StaticString) {
            #if DEBUG
            self.name = name
            state = Perf.signposter.beginInterval(name, id: Perf.signposter.makeSignpostID())
            started = DispatchTime.now().uptimeNanoseconds
            #endif
        }
        func end(_ detail: String = "") {
            #if DEBUG
            Perf.signposter.endInterval(name, state)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
            Perf.log.notice("perf \(String(describing: name), privacy: .public) \(detail, privacy: .public) \(ms, format: .fixed(precision: 1), privacy: .public) ms")
            #endif
        }
    }
}
