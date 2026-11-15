import AVFAudio
import Foundation

/// Brings audio files into a project. PCM WAV/AIFF at the project rate is
/// played straight from the file; anything else (MP3, AAC, FLAC, ALAC, CAF,
/// another sample rate) is decoded once into a float WAV in `mediaFolder`.
public enum AudioImporter {
    public struct Result: Sendable {
        public var source: SourceRef
        /// True when the samples were decoded into a new file.
        public var decoded: Bool
    }

    /// - Parameter sampleRate: the project's rate, or nil to keep the file's.
    public static func importFile(_ url: URL, sampleRate: Double? = nil, mediaFolder: URL,
                                  progress: @Sendable (Double) -> Void = { _ in }) throws -> Result {
        let name = url.deletingPathExtension().lastPathComponent
        if let info = try? AudioFileReader.info(at: url), sampleRate == nil || sampleRate == info.sampleRate {
            let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            return Result(source: SourceRef(name: name, path: url.path, bookmark: bookmark, info: info), decoded: false)
        }
        let decodedURL = try decode(url, to: mediaFolder, sampleRate: sampleRate, progress: progress)
        var info = try AudioFileReader.info(at: decodedURL)
        // Keep markers and Broadcast Wave data from the original when it had them.
        if let original = try? AudioFileReader.info(at: url) {
            let ratio = info.sampleRate / original.sampleRate
            info.markers = original.markers.map { FileMarker(position: Int64(Double($0.position) * ratio), length: Int64(Double($0.length) * ratio), name: $0.name) }
            info.bext = original.bext
            info.ixml = original.ixml
        }
        return Result(source: SourceRef(name: name, path: decodedURL.path, info: info, originalPath: url.path), decoded: true)
    }

    /// Decodes any file AVFoundation reads into a 32-bit float WAV (RF64 past 4 GB).
    static func decode(_ url: URL, to folder: URL, sampleRate: Double?, progress: (Double) -> Void) throws -> URL {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch {
            throw AudioFileError.unsupported("Jammer can't read \(url.lastPathComponent) (\(error.localizedDescription)).")
        }
        let input = file.processingFormat
        let channels = Int(input.channelCount)
        let rate = sampleRate ?? input.sampleRate
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                         channels: AVAudioChannelCount(channels), interleaved: true) else {
            throw AudioFileError.unsupported("Unsupported channel layout in \(url.lastPathComponent).")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appending(path: "\(url.deletingPathExtension().lastPathComponent)-\(UUID().uuidString.prefix(8)).wav")
        let writer = try WAVWriter(url: dest, options: .init(encoding: .float32, channels: channels, sampleRate: rate))
        guard let converter = AVAudioConverter(from: input, to: output) else {
            throw AudioFileError.unsupported("Can't convert \(url.lastPathComponent) to \(Int(rate)) Hz.")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        let chunk: AVAudioFrameCount = 32_768
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: chunk) else { throw AudioFileError.unsupported("Out of memory.") }
        let outCapacity = AVAudioFrameCount(Double(chunk) * rate / input.sampleRate) + 1_024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: outCapacity) else { throw AudioFileError.unsupported("Out of memory.") }
        let total = max(1, Double(file.length))
        final class State: @unchecked Sendable { var done = false; var error: Error? }
        let state = State()
        while true {
            outBuf.frameLength = 0
            var convError: NSError?
            let status = converter.convert(to: outBuf, error: &convError) { _, outStatus in
                if state.done || file.framePosition >= file.length {
                    state.done = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: inBuf, frameCount: chunk)
                } catch {
                    state.error = error
                    state.done = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inBuf.frameLength == 0 {
                    state.done = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inBuf
            }
            if let e = convError ?? state.error { throw AudioFileError.unsupported("Decoding failed: \(e.localizedDescription)") }
            if outBuf.frameLength > 0, let data = outBuf.floatChannelData {
                try writer.write(UnsafeBufferPointer(start: data[0], count: Int(outBuf.frameLength) * channels))
            }
            progress(min(1, Double(file.framePosition) / total))
            if status == .endOfStream || status == .error { break }
        }
        try writer.finish()
        return dest
    }
}
