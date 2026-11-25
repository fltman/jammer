import Foundation
import JammerCore
import JammerEngine

/// Recording's writing half: drains each armed track's ring (jm_capture) into a file of its own, 32-bit float WAV
/// (RF64 past 4 GB), on a thread of its own, never the device's. About once a second the sizes are written into the
/// headers and the files flushed (WAVWriter.checkpoint), so a crash loses at most that second, and `WAVWriter.recover`
/// takes a file left so to its last whole frame. Before each drain the free space is asked: under the reserve the
/// recording stops by itself, keeping what it has (never a write error in the middle of a file).
public final class CaptureWriter: @unchecked Sendable {
    public struct Track: Sendable {
        public var url: URL
        public var channels: Int
        public init(url: URL, channels: Int) { self.url = url; self.channels = channels }
    }

    public enum Ending: Equatable, Sendable {
        /// Stopped from the window.
        case stopped
        /// The disk reached the reserve: stopped by itself.
        case diskFull
        /// A file couldn't be written (the reason, as the system said it).
        case failed(String)
    }

    public struct Result: Sendable {
        public var frames: [Int64]
        public var dropped: [Int64]
        public var ending: Ending
    }

    private let capture: OpaquePointer
    private let tracks: [Track]
    private let freeSpace: @Sendable () -> Int64?
    private let reserve: Int64
    private let checkpointEvery: TimeInterval
    private let lock = NSLock()
    private var writers: [WAVWriter] = []
    private var thread: Thread?
    private var stopping = false
    private var ending: Ending?
    private let done = DispatchSemaphore(value: 0)
    /// Called once, from the writer's thread, when the recording ends by itself (the disk, a write error).
    public var endedByItself: (@Sendable (Ending) -> Void)?

    /// - Parameter freeSpace: bytes free where the files are (nil: unknown, go on).
    /// - Parameter reserve: what is always left free; recording stops when free space falls to it.
    public init(capture: OpaquePointer, tracks: [Track], sampleRate: Double, freeSpace: @escaping @Sendable () -> Int64?,
                reserve: Int64 = 2 << 30, checkpointEvery: TimeInterval = 1) throws {
        self.capture = capture
        self.tracks = tracks
        self.freeSpace = freeSpace
        self.reserve = reserve
        self.checkpointEvery = checkpointEvery
        writers = try tracks.map { t in
            try WAVWriter(url: t.url, options: .init(encoding: .float32, channels: t.channels, sampleRate: sampleRate))
        }
    }

    /// How many seconds of recording the free space holds above the reserve, at this many channels and rate.
    public static func secondsLeft(free: Int64, reserve: Int64 = 2 << 30, channels: Int, sampleRate: Double) -> Double {
        Double(max(0, free - reserve)) / (Double(max(1, channels)) * sampleRate * 4)
    }

    public func start() {
        let t = Thread { [self] in run() }
        t.name = "jammer.capture-writer"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    /// Ends the recording: what is in the rings is written, the files are finished. Waits for the writer.
    public func stop() -> Result {
        let wait = lock.withLock { () -> Bool in
            defer { stopping = true; waited = true }
            return thread != nil && !waited
        }
        if wait { done.wait() }
        return lock.withLock { result() }
    }
    private var waited = false

    private func result() -> Result {
        Result(frames: writers.map(\.framesWritten), dropped: tracks.indices.map { jm_capture_dropped(capture, Int32($0)) },
               ending: ending ?? .stopped)
    }

    private func run() {
        var buffer = [Float](repeating: 0, count: 8_192 * 2)
        var lastCheckpoint = Date()
        func drain() throws -> Bool {
            var any = false
            for (i, w) in writers.enumerated() {
                while true {
                    let n = buffer.withUnsafeMutableBufferPointer { jm_capture_pull(capture, Int32(i), $0.baseAddress!, Int32(8_192)) }
                    guard n > 0 else { break }
                    try buffer.withUnsafeBufferPointer { try w.write(UnsafeBufferPointer(rebasing: $0[0..<Int(n) * tracks[i].channels])) }
                    any = true
                }
            }
            return any
        }
        loop: while true {
            let stop = lock.withLock { stopping }
            do {
                if let free = freeSpace(), free <= reserve {
                    // At the reserve: what is in the rings now still goes (it is small), then the files are closed.
                    _ = try drain()
                    lock.withLock { ending = .diskFull }
                    break loop
                }
                _ = try drain()
                if Date().timeIntervalSince(lastCheckpoint) >= checkpointEvery {
                    for w in writers { try w.checkpoint() }
                    lastCheckpoint = Date()
                }
            } catch {
                lock.withLock { ending = .failed(error.localizedDescription) }
                break loop
            }
            if stop { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        for w in writers { try? w.finish() }
        let byItself = lock.withLock { stopping ? nil : ending }
        if let byItself { endedByItself?(byItself) }
        done.signal()
    }
}
