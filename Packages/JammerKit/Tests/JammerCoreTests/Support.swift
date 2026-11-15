import Foundation
@testable import JammerCore

/// A temporary folder removed when the value goes away.
final class TempDir {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appending(path: "jammer-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func file(_ name: String) -> URL { url.appending(path: name) }
}

/// Interleaved sine: `amplitudeDB` is the peak level in dBFS (EBU test-signal convention).
func sine(_ frequency: Double, amplitudeDB: Double, seconds: Double, sampleRate: Double = 48_000,
          channels: Int = 2, phase: Double = 0) -> [Float] {
    let n = Int((seconds * sampleRate).rounded())
    let a = pow(10, amplitudeDB / 20)
    var out = [Float](repeating: 0, count: n * channels)
    for i in 0..<n {
        let v = Float(a * sin(2 * .pi * frequency * Double(i) / sampleRate + phase))
        for c in 0..<channels { out[i * channels + c] = v }
    }
    return out
}

/// Deterministic pseudo-random values in [-1, 1).
func noise(count: Int, seed: UInt64 = 1) -> [Float] {
    var x = seed
    return (0..<count).map { _ in
        x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(Int32(truncatingIfNeeded: x >> 32)) / 2_147_483_648
    }
}

/// Writes interleaved float frames to a WAV.
func writeWAV(_ samples: [Float], to url: URL, channels: Int = 2, sampleRate: Double = 48_000,
              encoding: WAVWriter.Encoding = .float32) throws {
    let w = try WAVWriter(url: url, options: .init(encoding: encoding, channels: channels, sampleRate: sampleRate))
    try w.write(samples)
    try w.finish()
}

func run(_ tool: String, _ args: [String]) throws -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// A source registered in a pool from memory, plus a project around it.
func memoryProject(_ samples: [Float], channels: Int = 2, sampleRate: Double = 48_000) -> (Project, SourcePool) {
    let frames = Int64(samples.count / channels)
    let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: channels,
                             sampleRate: sampleRate, channelMask: nil, dataOffset: 0, frames: frames,
                             chunks: [], bext: nil, ixml: nil, markers: [])
    let ref = SourceRef(name: "test", path: "/dev/null", info: info)
    let pool = SourcePool()
    pool.register(ref.id, memory: samples, channels: channels)
    return (Project(source: ref), pool)
}
