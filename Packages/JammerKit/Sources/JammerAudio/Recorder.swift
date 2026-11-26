import CoreAudio
import Foundation
import JammerCore
import JammerEngine

/// Recording: armed tracks, their input meters, and a take written to files (the capture and the writer of R1 under
/// one roof). Started only by the person in the window (the agent API has no way to arm or record; SIBLINGS §5).
///
/// The input is the device's (a HAL IOProc on the input device, after macOS's microphone question), or, in a Debug
/// build given `-testInput sine|silence`, a feeder of its own that never touches the device: no question, no
/// microphone (`deviceRequests` counts every request the device path makes, and stays 0 then).
public final class Recorder: @unchecked Sendable {
    public enum Source: Sendable, Equatable {
        case device(AudioObjectID)
        /// Test input: a sine of 440 Hz at −12 dBFS on every channel, or silence. Debug builds only.
        case sine, silence
    }

    /// A track armed to record `channels` (1 or 2) of the input from channel `first` on (0-based).
    public struct Arm: Sendable, Equatable {
        public var track: UUID
        public var first: Int
        public var channels: Int
        public init(track: UUID, first: Int, channels: Int) { self.track = track; self.first = first; self.channels = channels }
    }

    public struct Take: Sendable {
        public var track: UUID
        public var url: URL
        public var frames: Int64
        public var dropped: Int64
    }

    /// Every time the device path asks for the microphone or opens the device's input (permission asked, IOProc made).
    /// A test-input recorder never adds to it.
    public static var deviceRequests: Int { counter.withLock { $0 } }
    private static let counter = Mutex(0)
    /// The app asks macOS's microphone question through this (AVCaptureDevice); counted as a device request.
    public static func noteDeviceRequest() { counter.withLock { $0 += 1 } }

    public let source: Source
    public let deviceChannels: Int
    public let sampleRate: Double
    private let lock = NSLock()
    private var capture: OpaquePointer?
    private var arms: [Arm] = []
    private var ioproc: AudioDeviceIOProcID?
    private var feeder: Thread?
    private var feeding = false
    private var writer: CaptureWriter?
    private var urls: [URL] = []

    public init(source: Source, deviceChannels: Int, sampleRate: Double) {
        self.source = source
        self.deviceChannels = deviceChannels
        self.sampleRate = sampleRate
    }

    deinit { disarm() }

    public var armed: [Arm] { lock.withLock { arms } }
    public var isRecording: Bool { lock.withLock { writer != nil } }

    /// Arms these tracks (replacing what was armed): the input runs, for the meters. Throws when the device can't start.
    public func arm(_ new: [Arm]) throws {
        disarm()
        guard !new.isEmpty else { return }
        guard let c = jm_capture_create(Int32(deviceChannels), Int32(new.count), new.map { Int32($0.first) }, new.map { Int32($0.channels) },
                                        sampleRate, 8) else {
            throw RecordingError.badInput
        }
        lock.withLock { capture = c; arms = new }
        switch source {
        case .device(let id):
            Self.noteDeviceRequest()
            var procID: AudioDeviceIOProcID?
            let made = AudioDeviceCreateIOProcID(id, jm_capture_ioproc, UnsafeMutableRawPointer(c), &procID)
            guard made == noErr, let procID, AudioDeviceStart(id, procID) == noErr else {
                if let procID { AudioDeviceDestroyIOProcID(id, procID) }
                disarm()
                throw RecordingError.device(made)
            }
            lock.withLock { ioproc = procID }
        case .sine, .silence:
            startFeeder(c)
        }
    }

    public func disarm() {
        _ = stopRecording()
        let (c, proc) = lock.withLock { () -> (OpaquePointer?, AudioDeviceIOProcID?) in
            defer { capture = nil; arms = []; ioproc = nil; feeding = false }
            return (capture, ioproc)
        }
        if case .device(let id) = source, let proc {
            AudioDeviceStop(id, proc)
            AudioDeviceDestroyIOProcID(id, proc)
        }
        while lock.withLock({ feeder != nil }) { Thread.sleep(forTimeInterval: 0.005) }
        if let c { jm_capture_release(c) }
    }

    /// The input's peak on an armed track since last asked (linear), for its meter.
    public func peak(_ track: UUID) -> Float {
        lock.withLock {
            guard let c = capture, let i = arms.firstIndex(where: { $0.track == track }) else { return 0 }
            return jm_capture_take_peak(c, Int32(i))
        }
    }

    /// Frames recorded so far in this recording (the capture counts every recording since the tracks were armed).
    public var recordedFrames: Int64 { lock.withLock { capture.map { jm_capture_frames($0) - framesBefore } ?? 0 } }
    private var framesBefore: Int64 = 0

    /// Starts writing every armed track to a file of its own, `name(track)` in `folder`.
    public func record(into folder: URL, name: (UUID) -> String, freeSpace: @escaping @Sendable () -> Int64?, reserve: Int64 = 2 << 30,
                       endedByItself: @escaping @Sendable (CaptureWriter.Ending) -> Void) throws {
        guard let c = lock.withLock({ capture }), writer == nil else { throw RecordingError.notArmed }
        let arms = armed
        let urls = arms.map { folder.appending(path: name($0.track)) }
        let w = try CaptureWriter(capture: c, tracks: zip(arms, urls).map { .init(url: $1, channels: $0.channels) }, sampleRate: sampleRate,
                                  freeSpace: freeSpace, reserve: reserve)
        w.endedByItself = endedByItself
        lock.withLock { writer = w; self.urls = urls; framesBefore = jm_capture_frames(c) }
        w.start()
        jm_capture_set_recording(c, true)
    }

    /// Stops writing; the takes, one per armed track (nil when nothing was recording).
    @discardableResult
    public func stopRecording() -> (takes: [Take], ending: CaptureWriter.Ending)? {
        guard let (w, c) = lock.withLock({ writer.flatMap { w in capture.map { (w, $0) } } }) else { return nil }
        jm_capture_set_recording(c, false)
        let r = w.stop()
        let (arms, urls) = lock.withLock { () -> ([Arm], [URL]) in
            defer { writer = nil }
            return (self.arms, self.urls)
        }
        let takes = arms.indices.map { Take(track: arms[$0].track, url: urls[$0], frames: r.frames[$0], dropped: r.dropped[$0]) }
        return (takes, r.ending)
    }

    // MARK: Test input

    private func startFeeder(_ c: OpaquePointer) {
        let silent = source == .silence, rate = sampleRate, channels = deviceChannels
        lock.withLock { feeding = true }
        let t = Thread { [weak self] in
            var n = 0.0, next = Date()
            let block = 512
            var buffer = [Float](repeating: 0, count: block * channels)
            while self?.lock.withLock({ self?.feeding ?? false }) == true {
                if !silent {
                    for f in 0..<block {
                        let v = Float(0.25 * sin(2 * .pi * 440 * (n + Double(f)) / rate))
                        for ch in 0..<channels { buffer[f * channels + ch] = v }
                    }
                }
                buffer.withUnsafeBufferPointer { jm_capture_push(c, $0.baseAddress!, Int32(block)) }
                n += Double(block)
                next = next.addingTimeInterval(Double(block) / rate)
                let wait = next.timeIntervalSinceNow
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            }
            self?.lock.withLock { self?.feeder = nil }
        }
        t.name = "jammer.test-input"
        lock.withLock { feeder = t }
        t.start()
    }
}

public enum RecordingError: Error, LocalizedError, Equatable, KeyedFailure {
    case badInput, notArmed, device(OSStatus)
    public var errorDescription: String? { said.text }
    public var keyed: KeyedMessage? { said.keyed }
    private var said: Said {
        switch self {
        case .badInput: Said("error.record.badInput", "The chosen inputs aren't on this input device.")
        case .notArmed: Said("error.record.notArmed", "No track is armed to record.")
        case .device(let s): Said("error.record.device", "The input device wouldn't start (%@).", "\(s)")
        }
    }
}

/// A value behind a lock (Synchronization's Mutex is macOS 15+, and its name is taken here by none).
final class Mutex<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func withLock<R>(_ f: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return f(&value) }
}

/// The input devices this Mac has, and what each can do.
public enum InputDevices {
    public struct Device: Sendable, Equatable {
        public var id: AudioObjectID
        public var name: String
        public var channels: Int
        public var sampleRate: Double
        /// What the device itself adds before a sample reaches Jämmer: latency, safety offset and one buffer, in frames.
        public var latency: Int
    }

    /// The Mac's default input device (System Settings › Sound › Input), without opening it.
    public static func defaultDevice() -> Device? {
        var id = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return describe(id)
    }

    static func describe(_ id: AudioObjectID) -> Device? {
        func u32(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32 {
            var v: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : 0
        }
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return nil }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        let channels = list.reduce(0) { $0 + Int($1.mNumberChannels) }
        guard channels > 0 else { return nil }
        var rate: Float64 = 0, rsize = UInt32(MemoryLayout<Float64>.size)
        var ra = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(id, &ra, 0, nil, &rsize, &rate)
        var name: CFString = "" as CFString, nsize = UInt32(MemoryLayout<CFString>.size)
        var na = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        _ = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(id, &na, 0, nil, &nsize, $0) }
        let latency = Int(u32(kAudioDevicePropertyLatency, kAudioObjectPropertyScopeInput)) + Int(u32(kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeInput))
            + Int(u32(kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal))
        return Device(id: id, name: name as String, channels: channels, sampleRate: rate, latency: latency)
    }
}
