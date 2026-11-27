import Foundation
import Testing
@testable import JammerCore
import JammerEngine

/// What opening a large document costs, step by step, and how its waveforms are read (the coordinator, 2026-11-27:
/// in the app every track said "Reading waveform… 0 %" for more than 20 s). Only with JAMMER_BIG_PROJECT set to a
/// .jammer package (Big.jammer: 24 tracks of an hour from 8 sources); prints what it measures and checks that the
/// progress moves and that at most two sources are read at once.
@Suite("Opening a large document", .enabled(if: ProcessInfo.processInfo.environment["JAMMER_BIG_PROJECT"] != nil))
struct BigOpenBench {
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [(String, Int, Double, Double)] = []   // what, source, seconds since start, value
        func add(_ what: String, _ source: Int, _ t: Double, _ v: Double = 0) { lock.withLock { events.append((what, source, t, v)) } }
        var all: [(String, Int, Double, Double)] { lock.withLock { events } }
        private var running = 0
        private(set) var most = 0
        func began() { lock.withLock { running += 1; most = max(most, running) } }
        func ended() { lock.withLock { running -= 1 } }
    }

    func ms(_ t0: Date) -> String { String(format: "%.0f ms", Date().timeIntervalSince(t0) * 1_000) }

    @Test("Open, plan and history, then every source's peaks through two at a time: time to the first percent and to done")
    func open() async throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JAMMER_BIG_PROJECT"]!)
        var t0 = Date()
        let project = try ProjectPackage.read(FileWrapper(url: url), packageURL: url)
        print("BIGOPEN read the package: \(ms(t0)); \(project.tracks.count) tracks, \(project.sources.count) sources, \(project.tracks.reduce(0) { $0 + $1.clips.count }) clips, \(Int(project.seconds(project.length))) s")
        let pool = SourcePool()
        t0 = Date()
        _ = PlanCompiler.compile(project, pool: pool)
        print("BIGOPEN plan: \(ms(t0))")
        t0 = Date()
        _ = try History(root: project)
        print("BIGOPEN history: \(ms(t0))")

        // The first draw before any peaks are there, as the timeline made it on the main thread (WaveformMetalView:
        // columnValues with allowRaw = !needsFiles, true when the whole hour is in view), and as it does now (false:
        // the main thread never reads the files). The whole hour across 1 500 columns.
        for allowRaw in [true, false] {
            t0 = Date()
            var read = 0
            for t in project.tracks.indices {
                let cols = Waveform.columns(project, track: t, start: 0, framesPerColumn: Double(project.length) / 1_500, count: 1_500,
                                            peaks: [:], pool: pool, allowRaw: allowRaw)
                read += cols.first?.filter { $0 != .empty }.count ?? 0
            }
            print("BIGOPEN first draw without peaks, allowRaw \(allowRaw): \(ms(t0)) (\(read) columns with something)")
        }

        // The peaks as the app reads them (EditorSession.loadPeaks), built anew (no cache), two at a time.
        let limit = TaskLimit(2)
        let log = Log()
        let start = Date()
        await withTaskGroup(of: Void.self) { group in
            for (i, ref) in project.sources.enumerated() {
                let file = SourcePool.resolve(ref), info = ref.info
                group.addTask {
                    log.add("queued", i, Date().timeIntervalSince(start))
                    _ = await limit.run {
                        await Stoppable.run(priority: .utility) { stopped -> PeakIndex? in
                            log.began()
                            defer { log.ended() }
                            log.add("start", i, Date().timeIntervalSince(start))
                            guard let src = AudioFileReader.openSource(info, at: file) else { return nil }
                            defer { jm_source_release(src) }
                            let built = PeakIndex.build(reading: { at, n in
                                var out = [Float](repeating: 0, count: n * info.channels)
                                let got = Int(jm_source_read(src, at, Int64(n), &out))
                                if got < n { out.removeLast((n - got) * info.channels) }
                                return out
                            }, channels: info.channels, frames: info.frames, progress: { p in
                                log.add("progress", i, Date().timeIntervalSince(start), p)
                                return !stopped()
                            })
                            log.add("done", i, Date().timeIntervalSince(start))
                            return built
                        }.value
                    }
                }
            }
        }
        let events = log.all
        for i in project.sources.indices {
            let mine = events.filter { $0.1 == i }
            let startT = mine.first { $0.0 == "start" }?.2 ?? .nan
            let firstPercent = mine.first { $0.0 == "progress" && $0.3 >= 0.01 }?.2 ?? .nan
            let doneT = mine.first { $0.0 == "done" }?.2 ?? .nan
            let values = mine.filter { $0.0 == "progress" }.map(\.3)
            print(String(format: "BIGOPEN source %d: waited %.2f s, 1 %% at %.2f s, done at %.2f s, %d progress calls", i, startT, firstPercent, doneT, values.count))
            #expect(values == values.sorted() && (values.last ?? 0) >= 0.999, "source \(i)'s progress moves up to done")
        }
        print(String(format: "BIGOPEN all peaks: %.2f s; at most %d at once", Date().timeIntervalSince(start), log.most))
        #expect(log.most <= 2)
    }
}
