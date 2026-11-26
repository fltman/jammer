import Darwin
import Foundation
import Testing
@testable import JammerCore

/// A large made-up project, measured (the performance pass, 2026-11-26). Runs only when JAMMER_PERF_DIR names a folder
/// to work in, never in the gate: it writes about 230 MB of generated sound there (tones and noise, nothing fetched)
/// and keeps the saved project, `Big.jammer`, for the GUI run. One hour, 24 tracks, about 400 clips, 60 markers and
/// a transcript of some 6 000 words. Prints one line per measurement, "PERF <what> <figure>".
@Suite("Performance on a large project")
struct PerformanceBench {
    static func ms(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 }
    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        return r == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }

    @Test("Build, save, open, plan, peaks, waveform columns, render and an edit, measured")
    func measure() throws {
        guard let dirPath = ProcessInfo.processInfo.environment["JAMMER_PERF_DIR"] else { return }
        let dir = URL(fileURLWithPath: dirPath)
        let media = dir.appending(path: "media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let rate = 48_000.0, sourceFrames = Int(rate * 300)
        func line(_ what: String, _ figure: String) { print("PERF \(what) \(figure)") }

        // Eight sources of five minutes each: a tone of its own, a slow swell and some noise.
        var t0 = Self.now()
        var sources: [SourceRef] = []
        var rng = SystemRandomNumberGenerator()
        for s in 0..<8 {
            let url = media.appending(path: "source-\(s).wav")
            if !FileManager.default.fileExists(atPath: url.path) {
                let w = try WAVWriter(url: url, options: .init(encoding: .int16, channels: 1, sampleRate: rate))
                let hz = 110.0 * Double(s + 1)
                var block = [Float](repeating: 0, count: 48_000)
                for start in stride(from: 0, to: sourceFrames, by: block.count) {
                    for i in 0..<block.count {
                        let t = Double(start + i) / rate
                        block[i] = Float(0.25 * sin(2 * .pi * hz * t) * (0.6 + 0.4 * sin(2 * .pi * t / 17)) + Double.random(in: -0.02...0.02, using: &rng))
                    }
                    try w.write(block)
                }
                try w.finish()
            }
            sources.append(SourceRef(name: "source \(s)", path: url.path, info: try AudioFileReader.info(at: url)))
        }
        line("sources", String(format: "%.0f ms (8 × 5 min, mono, 16-bit)", Self.ms(t0)))

        // 24 tracks to an hour, clips of 2–4 minutes from the sources, a second's gap between them.
        var project = Project(sampleRate: rate, channels: 2, sources: sources)
        let hour = Frame(rate * 3_600)
        var clips = 0
        for t in 0..<24 {
            var track = Track(name: "Track \(t + 1)")
            var at: Frame = 0, k = t
            while at < hour {
                let length = min(Frame(rate * Double(120 + (k * 37) % 120)), hour - at)
                let src = sources[k % sources.count]
                let offset = Frame((k * 7_919) % max(1, sourceFrames - Int(length)))
                track.clips.append(Clip(sourceID: src.id, sourceStart: offset, start: at, length: min(length, Frame(sourceFrames) - offset)))
                at += length + Frame(rate)
                k += 1; clips += 1
            }
            project.tracks.append(track)
        }
        for m in 0..<60 { _ = project.addMarker(at: Frame(rate * 60) * Frame(m), name: "Minute \(m)") }
        for src in sources {
            let words = (0..<750).map { i in Word(text: ["och", "sedan", "ljudet", "klipps", "här"][i % 5], start: Frame(rate * 0.4) * Frame(i), end: Frame(rate * 0.4) * Frame(i) + Frame(rate * 0.3)) }
            project.setTranscript(SourceTranscript(sourceID: src.id, language: "sv-SE", engine: "bench", words: words))
        }
        line("project", "\(project.tracks.count) tracks, \(clips) clips, \(project.markers.count) markers, \(project.transcripts.reduce(0) { $0 + $1.words.count }) words")

        // Save: the package as the window writes it.
        let package = dir.appending(path: "Big.jammer")
        try? FileManager.default.removeItem(at: package)
        t0 = Self.now()
        let wrapper = try ProjectPackage.fileWrapper(project, existingMedia: nil)
        try wrapper.write(to: package, options: .atomic, originalContentsURL: nil)
        line("save", String(format: "%.0f ms", Self.ms(t0)))

        // Open: read the package back, then the plan that plays it (the sources opened).
        t0 = Self.now()
        let read = try ProjectPackage.read(try FileWrapper(url: package), packageURL: package)
        let openRead = Self.ms(t0)
        let pool = SourcePool()
        t0 = Self.now()
        var plan = PlanCompiler.compile(read, pool: pool)
        line("open", String(format: "read %.0f ms, plan %.0f ms", openRead, Self.ms(t0)))

        // Peaks: what the waveform is drawn from, for every source.
        t0 = Self.now()
        var peaks: [UUID: PeakIndex] = [:]
        for src in sources {
            peaks[src.id] = PeakIndex.build(reading: { pool.read(src, from: $0, count: $1) }, channels: 1, frames: src.info.frames)
        }
        line("peaks", String(format: "%.0f ms for 8 sources (40 min of sound)", Self.ms(t0)))

        // Waveform columns for a 2 000-column view of all 24 tracks: fitted (the whole hour), and close (2 s).
        for (what, fpc) in [("fit", Double(hour) / 2_000), ("close", rate * 2 / 2_000)] {
            t0 = Self.now()
            for t in 0..<24 { _ = Waveform.columns(read, track: t, start: Double(hour) / 3, framesPerColumn: fpc, count: 2_000, peaks: peaks, pool: pool) }
            line("columns.\(what)", String(format: "%.1f ms for 24 tracks", Self.ms(t0)))
        }

        // Playback: rendering 10 s of all 24 tracks; the share of real time it takes is what playing costs.
        t0 = Self.now()
        _ = plan.render(from: Frame(rate * 600), frames: Int(rate * 10))
        let renderMs = Self.ms(t0)
        line("render", String(format: "10 s in %.0f ms (%.1f %% of real time)", renderMs, renderMs / 100))

        // An edit: one clip's gain, and the plan made again.
        var edited = read
        edited.tracks[5].clips[3].gainDB = -3
        t0 = Self.now()
        plan = PlanCompiler.compile(edited, pool: pool)
        line("edit", String(format: "plan again %.0f ms", Self.ms(t0)))
        line("memory", String(format: "%.0f MB resident", Self.residentMB()))
        #expect(clips > 350)
    }
}
