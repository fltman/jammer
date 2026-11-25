import Foundation
import Testing
@testable import JammerAudio
import JammerCore
import JammerEngine

/// Recording's two halves without a device: the capture's rings fed synthetic blocks as the device thread would,
/// and the writer draining them into files (bit-exact), plus what happens when the writer falls behind, when the disk
/// fills, and after a crash.
@Suite("Recording: capture and writing", .serialized)
struct CaptureTests {
    let rate = 48_000.0

    func folder() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "jammer-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Two device channels, a different sine in each, `blocks` blocks of 512 frames.
    func feed(_ c: OpaquePointer, blocks: Int, from start: Int = 0) -> [Float] {
        var all: [Float] = []
        for b in 0..<blocks {
            var block = [Float](repeating: 0, count: 512 * 2)
            for f in 0..<512 {
                let n = Double(start + b * 512 + f)
                block[f * 2] = Float(0.5 * sin(2 * .pi * 440 * n / rate))
                block[f * 2 + 1] = Float(0.25 * sin(2 * .pi * 1_000 * n / rate))
            }
            block.withUnsafeBufferPointer { jm_capture_push(c, $0.baseAddress!, 512) }
            all += block
        }
        return all
    }

    func samples(_ url: URL) throws -> [Float] {
        let info = try AudioFileReader.info(at: url)
        let src = SourceRef(name: "r", path: url.path, info: info)
        return SourcePool().read(src, from: 0, count: Int(info.frames))
    }

    @Test("Two armed tracks from two input channels: each file holds its channel, bit for bit; nothing dropped")
    func bitExact() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let first: [Int32] = [0, 1], count: [Int32] = [1, 1]
        let made = jm_capture_create(2, 2, first, count, rate, 2)
        let c = try #require(made, "created: \(String(describing: made))")
        defer { jm_capture_release(c) }
        jm_capture_set_recording(c, true)
        let w = try CaptureWriter(capture: c, tracks: [.init(url: dir.appending(path: "a.wav"), channels: 1), .init(url: dir.appending(path: "b.wav"), channels: 1)],
                                  sampleRate: rate, freeSpace: { .max })
        w.start()
        var fed: [Float] = []
        for i in 0..<40 { fed += feed(c, blocks: 10, from: i * 5_120); Thread.sleep(forTimeInterval: 0.005) }
        let r = w.stop()
        #expect(r.ending == .stopped && r.dropped == [0, 0] && r.frames == [204_800, 204_800])
        #expect(jm_capture_frames(c) == 204_800)
        let a = try samples(dir.appending(path: "a.wav")), b = try samples(dir.appending(path: "b.wav"))
        #expect(a == stride(from: 0, to: fed.count, by: 2).map { fed[$0] })
        #expect(b == stride(from: 1, to: fed.count, by: 2).map { fed[$0] })
    }

    @Test("Armed but not recording: the meters see the input, nothing goes into the rings")
    func armedOnly() {
        let c = jm_capture_create(2, 1, [0], [2], rate, 1)!
        defer { jm_capture_release(c) }
        _ = feed(c, blocks: 4)
        #expect(abs(jm_capture_take_peak(c, 0) - 0.5) < 0.001 && jm_capture_take_peak(c, 0) == 0, "the peak, then reset by the reading")
        var out = [Float](repeating: 0, count: 4_096)
        #expect(jm_capture_pull(c, 0, &out, 2_048) == 0 && jm_capture_frames(c) == 0)
    }

    @Test("A writer that falls behind: the ring takes what it holds and counts the rest as dropped, never silently")
    func dropsCounted() {
        let c = jm_capture_create(2, 1, [0], [1], rate, 0.01)!   // 480 frames → a ring of 512
        defer { jm_capture_release(c) }
        jm_capture_set_recording(c, true)
        _ = feed(c, blocks: 3)
        #expect(jm_capture_dropped(c, 0) == 1_024)
        var out = [Float](repeating: 0, count: 2_048)
        #expect(jm_capture_pull(c, 0, &out, 2_048) == 512)
    }

    @Test("Bad tracks are refused: a channel past the device's, three channels, none")
    func refuses() {
        #expect(jm_capture_create(2, 1, [1], [2], rate, 1) == nil)
        #expect(jm_capture_create(4, 1, [0], [3], rate, 1) == nil)
        #expect(jm_capture_create(2, 0, [], [], rate, 1) == nil)
    }

    @Test("At the disk's reserve the recording stops by itself, and the file holds what was written, readable")
    func diskFull() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let c = jm_capture_create(2, 1, [0], [1], rate, 4)!
        defer { jm_capture_release(c) }
        jm_capture_set_recording(c, true)
        let asked = Counter()
        let w = try CaptureWriter(capture: c, tracks: [.init(url: dir.appending(path: "a.wav"), channels: 1)], sampleRate: rate,
                                  freeSpace: { asked.next() < 5 ? 10 << 30 : 1 << 30 })
        let ended = Counter()
        w.endedByItself = { if $0 == .diskFull { _ = ended.next() } }
        _ = feed(c, blocks: 20)
        w.start()
        Thread.sleep(forTimeInterval: 0.5)
        let r = w.stop()
        #expect(r.ending == .diskFull && ended.value == 1)
        #expect(try AudioFileReader.info(at: dir.appending(path: "a.wav")).frames == r.frames[0] && r.frames[0] == 10_240)
        #expect(CaptureWriter.secondsLeft(free: (2 << 30) + 48_000 * 4 * 2 * 60, channels: 2, sampleRate: rate) == 60)
    }

    @Test("A recording cut off by a crash: the checkpointed file reads, and recover takes it to its last whole frame")
    func recovers() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "cut.wav")
        do {
            let w = try WAVWriter(url: url, options: .init(encoding: .float32, channels: 2, sampleRate: rate))
            try w.write([Float](repeating: 0.25, count: 2_000 * 2))
            try w.checkpoint()
            #expect(try AudioFileReader.info(at: url).frames == 2_000, "readable at the checkpoint")
            try w.write([Float](repeating: 0.5, count: 500 * 2))
            // No finish: the app stopped here. Half a frame more, as a write cut in the middle would leave.
        }
        let h = try FileHandle(forWritingTo: url); try h.seekToEnd(); try h.write(contentsOf: Data([1, 2, 3])); try h.close()
        #expect(try WAVWriter.recover(url) == 2_500)
        let back = try samples(url)
        #expect(back.count == 5_000 && back.last == 0.5 && back[3_999] == 0.25)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func next() -> Int { lock.withLock { defer { n += 1 }; return n } }
}
