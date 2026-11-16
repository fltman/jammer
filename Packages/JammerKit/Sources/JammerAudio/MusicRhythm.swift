import AVFoundation
import Foundation
import JammerCore
import MusicUnderstanding

/// The system's beat tracking (MusicUnderstanding, on this Mac, no network) as the analyser
/// `Rhythm` judges. It answers with a tempo for any sound; whether to believe it is `Rhythm`'s job.
public enum MusicRhythm {
    /// Makes tempo detection available. Called once at launch.
    public static func register() {
        Rhythm.analyser = { url in read(url) }
    }

    /// Beats and tempo of a file. Blocks the calling thread (never the main one) while the analysis runs.
    public static func read(_ url: URL) -> Rhythm.Reading? {
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        Task.detached(priority: .userInitiated) {
            defer { done.signal() }
            do {
                let session = try await MusicUnderstandingSession(asset: AVURLAsset(url: url))
                guard let r = try await session.analyze(for: [.rhythm]).rhythm else { return }
                box.set(Rhythm.Reading(bpm: r.beatsPerMinute.map(Double.init), beats: r.beats.map(\.seconds).filter(\.isFinite)))
            } catch {}
        }
        done.wait()
        return box.value
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Rhythm.Reading?
        func set(_ r: Rhythm.Reading) { lock.withLock { stored = r } }
        var value: Rhythm.Reading? { lock.withLock { stored } }
    }
}
