import Foundation
import JammerEngine
import Testing
@testable import JammerCore

/// The multi-hour stress test: a 3-hour stereo WAV through everything the app does
/// with it. Off by default (it writes two files of about 2 GB); run `scripts/stress.sh`.
///
///     JAMMER_STRESS=1            run it
///     JAMMER_STRESS_HOURS=3      length of the file
///     JAMMER_STRESS_DIR=…        where the files go (default: the temporary folder)
///     JAMMER_STRESS_REPORT=…     also write the timings there as Markdown
@Suite("Stress", .enabled(if: ProcessInfo.processInfo.environment["JAMMER_STRESS"] != nil))
struct StressTests {
    let env = ProcessInfo.processInfo.environment
    let sr = 48_000.0
    let channels = 2

    final class Report {
        var rows: [(String, String, String)] = []
        func add(_ what: String, _ value: String, _ note: String = "") {
            rows.append((what, value, note))
            print("STRESS  \(what): \(value)\(note.isEmpty ? "" : "  (\(note))")")
        }
        var markdown: String {
            "| Step | Result | Notes |\n|---|---|---|\n" + rows.map { "| \($0.0) | \($0.1) | \($0.2) |" }.joined(separator: "\n") + "\n"
        }
    }

    static func time<T>(_ body: () throws -> T) rethrows -> (T, Double) {
        let start = ContinuousClock.now
        let r = try body()
        let d = ContinuousClock.now - start
        return (r, Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
    }

    static func maxRSS() -> String {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return String(format: "%.0f MB", Double(u.ru_maxrss) / 1_048_576)
    }

    static func ms(_ s: Double) -> String { String(format: "%.2f ms", s * 1_000) }
    static func sec(_ s: Double) -> String { String(format: "%.1f s", s) }

    /// Speech-like: bursts of shaped noise with pauses, every value an exact 16-bit step.
    static func fill(_ out: inout [Float], from frame: Int64, frames: Int, channels: Int, sampleRate: Double, seed: inout UInt64) {
        for i in 0..<frames {
            let t = Double(frame + Int64(i)) / sampleRate
            let phrase = t.truncatingRemainder(dividingBy: 2.7)
            let talking = phrase < 2.0
            let env = talking ? 0.25 * (0.6 + 0.4 * sin(2 * .pi * 3.1 * t)) : 0.002
            for c in 0..<channels {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let r = Double(Int32(truncatingIfNeeded: seed >> 32)) / 2_147_483_648
                let v = (r * env * 32_768).rounded()
                out[i * channels + c] = Float(v / 32_768)
            }
        }
    }

    @Test("Three hours: write, open, peaks, zoom, edits, loudness, export that nulls")
    func threeHours() throws {
        let hours = Double(env["JAMMER_STRESS_HOURS"] ?? "3") ?? 3
        let frames = Int64(hours * 3_600 * sr)
        let bytes = frames * Int64(channels) * 2
        let dir = env["JAMMER_STRESS_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let work = dir.appending(path: "jammer-stress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let free = (try? work.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
        try #require(Int64(free) > 2 * bytes + 1_000_000_000, "Needs \(2 * bytes / 1_000_000_000 + 1) GB free in \(dir.path), has \(Int64(free) / 1_000_000_000) GB.")

        let report = Report()
        report.add("File", String(format: "%g h, %lld frames, %.2f GB", hours, frames, Double(bytes) / 1e9), "48 kHz stereo, 16-bit WAV")

        // 1. Write the source (the same path recording and export take).
        let src = work.appending(path: "source.wav")
        let block = 1 << 18
        let (_, tWrite) = try Self.time {
            let w = try WAVWriter(url: src, options: .init(encoding: .int16, channels: channels, sampleRate: sr))
            var buf = [Float](repeating: 0, count: block * channels)
            var seed: UInt64 = 7
            var at: Int64 = 0
            while at < frames {
                let n = Int(min(Int64(block), frames - at))
                Self.fill(&buf, from: at, frames: n, channels: channels, sampleRate: sr, seed: &seed)
                try buf.withUnsafeBufferPointer { try w.write(UnsafeBufferPointer(rebasing: $0[0..<(n * channels)])) }
                at += Int64(n)
            }
            try w.finish()
        }
        report.add("Write WAV", Self.sec(tWrite), String(format: "%.0f× realtime, includes generating the signal", hours * 3_600 / tWrite))

        // 2. Open.
        let (info, tOpen) = try Self.time { try AudioFileReader.info(at: src) }
        #expect(info.frames == frames)
        let ref = SourceRef(name: "stress", path: src.path, info: info)
        let pool = SourcePool()
        try #require(pool.source(for: ref) != nil)
        report.add("Open (parse chunks, open source)", Self.ms(tOpen))

        // 3. Peak index, cache write and read.
        let (built, tPeaks) = Self.time {
            PeakIndex.build(reading: { pool.read(ref, from: $0, count: $1) }, channels: channels, frames: frames)
        }
        let peaks = try #require(built)
        report.add("Build peak index", Self.sec(tPeaks), String(format: "%.0f× realtime, reading %.0f MB/s; peaks, loudness and export are bound by the disk", hours * 3_600 / tPeaks, Double(bytes) / tPeaks / 1e6))
        let cache = work.appending(path: "peaks.jmpk")
        let (_, tCacheW) = try Self.time { try peaks.write(to: cache) }
        let cacheSize = (try? FileManager.default.attributesOfItem(atPath: cache.path)[.size] as? NSNumber)?.int64Value ?? 0
        let (reread, tCacheR) = Self.time { PeakIndex.read(from: cache) }
        #expect(reread?.levels == peaks.levels)
        report.add("Peak cache", String(format: "%.1f MB", Double(cacheSize) / 1_048_576), "write \(Self.ms(tCacheW)), read \(Self.ms(tCacheR))")
        report.add("Memory after peaks (max RSS)", Self.maxRSS())

        // 4. Zoom: 2 000 columns at every zoom from the whole file to below one sample a column.
        var project = Project(source: ref)
        let width = 2_000
        let spans: [(String, Double)] = [("whole file", Double(frames)), ("10 min", 600 * sr), ("1 min", 60 * sr),
                                         ("10 s", 10 * sr), ("1 s", sr), ("0.01 s", 0.01 * sr)]
        var rng: UInt64 = 99
        func random(_ n: Int64) -> Int64 {
            rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int64((rng >> 1) % UInt64(max(1, n)))
        }
        /// Per zoom: what the main thread does (peaks only, never the disk) and, where
        /// the view is finer than a peak block, the background read of exact samples.
        func zoomRound(_ label: String) -> Double {
            var worst = 0.0
            for (name, span) in spans {
                let fpc = span / Double(width)
                let needsFiles = fpc < Double(PeakIndex.baseBlock)
                var main: [Double] = [], files: [Double] = []
                for k in 0..<25 {
                    // Include the very end, where byte offsets pass 2 GB.
                    let start = k == 0 ? max(0, Double(project.length) - span) : Double(random(max(1, project.length - Int64(span))))
                    let (cols, t) = Self.time {
                        Waveform.columns(project, track: 0, start: start, framesPerColumn: fpc, count: width,
                                         peaks: [ref.id: peaks], pool: pool, allowRaw: !needsFiles)
                    }
                    main.append(t)
                    if k == 0, span >= sr { #expect(cols[0].contains { $0 != .empty }, "No waveform at the end, \(name)") }
                    if needsFiles {
                        let (_, tf) = Self.time {
                            Waveform.columns(project, track: 0, start: start, framesPerColumn: fpc, count: width,
                                             peaks: [ref.id: peaks], pool: pool)
                        }
                        files.append(tf)
                    }
                }
                main.sort(); files.sort()
                worst = max(worst, main.last!)
                var note = String(format: "%.4g frames per column", fpc)
                if !files.isEmpty {
                    note += "; exact samples in the background: median \(Self.ms(files[files.count / 2])), max \(Self.ms(files.last!))"
                }
                report.add("Redraw \(label), \(name)", "median \(Self.ms(main[main.count / 2])), max \(Self.ms(main.last!))", note)
            }
            return worst
        }
        let worstClean = zoomRound("untouched")
        #expect(worstClean < 1.0 / 60, "A redraw took \(Self.ms(worstClean)); a frame at 60 Hz is 16.7 ms.")

        // 5. A podcast clean-up: ripple deletes of 0.2–2 s (400 over 3 h, fewer in a short run),
        // each one an undo step and a new plan.
        let cuts = max(4, min(400, Int(Double(frames) / sr / 25)))
        let original = project
        var undo: [Project] = []
        var editTimes: [Double] = [], compileTimes: [Double] = []
        var removed: Int64 = 0
        for _ in 0..<cuts {
            let len = Int64(0.2 * sr) + random(Int64(1.8 * sr))
            let at = random(project.length - len)
            let (_, te) = try Self.time {
                undo.append(project)
                try project.delete(at..<(at + len))
                removed += len
            }
            let (_, tc) = Self.time { _ = PlanCompiler.compile(project, pool: pool) }
            editTimes.append(te)
            compileTimes.append(tc)
        }
        editTimes.sort(); compileTimes.sort()
        report.add("Ripple delete ×\(cuts) (with undo copy)", "median \(Self.ms(editTimes[cuts / 2])), max \(Self.ms(editTimes.last!))",
                   "\(project.tracks[0].clips.count) clips afterwards")
        report.add("Compile render plan", "median \(Self.ms(compileTimes[cuts / 2])), max \(Self.ms(compileTimes.last!))")
        // Cuts that swallow a whole earlier piece leave fewer clips; the length is exact.
        #expect(project.length == frames - removed)
        #expect(project.tracks[0].clips.count <= cuts + 1)
        #expect(editTimes.last! < 0.05 && compileTimes.last! < 0.05)
        let worstEdited = zoomRound("after \(cuts) cuts")
        #expect(worstEdited < 1.0 / 60)
        report.add("Memory after edits (max RSS)", Self.maxRSS())

        // Undo all the way back is exact.
        #expect(undo.first == original)

        // 6. Save and open the edited project.
        let (json, tEncode) = try Self.time { try ProjectPackage.encode(project) }
        let (decoded, tDecode) = try Self.time { try ProjectPackage.decode(json) }
        #expect(decoded == project)
        report.add("project.json, \(project.tracks[0].clips.count) clips", String(format: "%.0f KB", Double(json.count) / 1_024), "encode \(Self.ms(tEncode)), decode \(Self.ms(tDecode))")

        // 7. Loudness of the whole edited timeline.
        let edited = PlanCompiler.compile(project, pool: pool)
        let (loud, tLoud) = Self.time { LoudnessMeter.measure(edited, 0..<edited.length) }
        #expect(loud.integrated != nil)
        report.add("Loudness (BS.1770, true peak), edited timeline", Self.sec(tLoud),
                   String(format: "%.0f× realtime; %.1f LUFS, %.1f dBTP", Double(edited.length) / sr / tLoud, loud.integrated ?? .nan, loud.truePeak))
        report.add("Memory after loudness (max RSS)", Self.maxRSS())

        // 8. Export the untouched project and check it nulls against the source, byte for byte.
        let out = work.appending(path: "export.wav")
        let clean = PlanCompiler.compile(Project(source: ref), pool: pool)
        let (_, tExport) = try Self.time {
            let w = try WAVWriter(url: out, options: .init(encoding: .int16, channels: channels, sampleRate: sr))
            try clean.render(0..<clean.length, blockFrames: block) { try w.write($0) }
            try w.finish()
        }
        report.add("Export 16-bit WAV, untouched", Self.sec(tExport), String(format: "%.0f× realtime", hours * 3_600 / tExport))
        report.add("Memory after export (max RSS)", Self.maxRSS())
        let outInfo = try AudioFileReader.info(at: out)
        #expect(outInfo.frames == frames)
        let (same, tCompare) = try Self.time { try Self.sameData(src, info, out, outInfo) }
        #expect(same, "The untouched export doesn't null against the source.")
        report.add("Null test, export vs source", same ? "identical" : "DIFFERENT", "\(Self.sec(tCompare)) to compare \(String(format: "%.2f GB", Double(bytes) / 1e9))")
        report.add("Memory at the end (max RSS)", Self.maxRSS())

        if let path = env["JAMMER_STRESS_REPORT"] {
            let isInternal = (try? work.resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal) ?? nil
            let disk = isInternal == true ? "an internal disk" : (isInternal == false ? "an external disk" : "a disk of unknown kind")
            let header = """
            # Stress test

            `scripts/stress.sh` on \(Date().formatted(.iso8601.year().month().day())), release build, \(ProcessInfo.processInfo.processorCount) cores, macOS \(ProcessInfo.processInfo.operatingSystemVersionString), files on \(disk). One run; timings vary a little between runs.

            "Redraw" is what the main thread does: it only ever draws from the peak index. Finer than one peak block (256 frames) per column, exact samples are then read on a background task and replace the picture; that time is in the notes.


            """
            try (header + report.markdown).write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// Compares the sample data of two files in 16 MB pieces.
    static func sameData(_ a: URL, _ ai: AudioFileInfo, _ b: URL, _ bi: AudioFileInfo) throws -> Bool {
        let n = ai.frames * Int64(ai.channels) * Int64(ai.sampleFormat.bitsPerSample / 8)
        guard bi.frames == ai.frames, bi.channels == ai.channels, bi.sampleFormat == ai.sampleFormat else { return false }
        let ha = try FileHandle(forReadingFrom: a), hb = try FileHandle(forReadingFrom: b)
        defer { try? ha.close(); try? hb.close() }
        try ha.seek(toOffset: UInt64(ai.dataOffset))
        try hb.seek(toOffset: UInt64(bi.dataOffset))
        var left = n
        while left > 0 {
            let k = Int(min(left, 16 << 20))
            let same = try autoreleasepool {
                guard let da = try ha.read(upToCount: k), let db = try hb.read(upToCount: k) else { return false }
                return da.count == k && da == db
            }
            guard same else { return false }
            left -= Int64(k)
        }
        return true
    }
}
