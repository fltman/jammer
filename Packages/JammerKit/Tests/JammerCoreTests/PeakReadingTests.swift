import Foundation
import Testing
@testable import JammerCore

@Suite("What a lane says while its waveform is read: its own sources, waiting or how far")
struct PeakReadingTests {
    @Test("Each lane by its own sources: done says nothing, queued says waiting, read says the least progress of those read")
    func status() {
        let a = UUID(), b = UUID(), c = UUID()
        let progress: [UUID: Double] = [a: 0.42, b: PeakReading.waiting]   // c is done: no entry
        #expect(PeakReading.status(of: [c], progress: progress) == nil, "a lane whose sources are read says nothing")
        #expect(PeakReading.status(of: [b], progress: progress) == .waiting, "a queued source is waiting, not 0 %")
        #expect(PeakReading.status(of: [a], progress: progress) == .reading(0.42))
        #expect(PeakReading.status(of: [a, b, c, a], progress: progress) == .reading(0.42), "reading before waiting")
        #expect(PeakReading.status(of: [a, b], progress: [a: 0.9, b: 0.1]) == .reading(0.1), "the least of those read")
        #expect(PeakReading.status(of: [], progress: progress) == nil)
    }
}
