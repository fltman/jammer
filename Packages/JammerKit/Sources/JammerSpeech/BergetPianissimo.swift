import Foundation
import JammerCore

/// The hosted Swedish Pianissimo model uses Berget's realtime transcription API.
/// The final event has text without word timestamps.
public struct BergetPianissimo: TranscriptionEngine {
    public static let model = "klang/pianissimo"
    public static let defaultEndpoint = URL(string: "wss://api.berget.ai/v1/realtime?intent=transcription")!
    public let id = "berget klang/pianissimo"

    private let key: String
    private let connect: @Sendable (URLRequest) -> any PianissimoSocket
    private let endpoint: URL

    public init(key: String, endpoint: URL = defaultEndpoint) {
        self.init(key: key, endpoint: endpoint) { request in
            let socket = KeyedRequest.webSocket(for: request, session: LocalSession.session(for: request.url))
            socket.resume()
            return socket
        }
    }

    init(key: String, endpoint: URL = defaultEndpoint, connect: @escaping @Sendable (URLRequest) -> any PianissimoSocket) {
        self.key = key
        self.endpoint = endpoint
        self.connect = connect
    }

    public func supports(_ locale: Locale) async -> Bool { locale.language.languageCode?.identifier == "sv" }

    public func transcribe(_ source: SourceRef, pool: SourcePool, locale: Locale,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> SourceTranscript {
        guard await supports(locale) else { throw TranscriptionError.unsupportedLanguage(locale.identifier(.bcp47)) }
        try Task.checkCancellation()
        let samples = try SpeechAudio.mono16k(source, pool: pool)
        let words = try await transcribe(samples, sourceFrames: source.info.frames, sourceRate: source.info.sampleRate, progress: progress)
        return SourceTranscript(sourceID: source.id, language: locale.identifier(.bcp47), engine: id, words: words, textOnly: true)
    }

    func transcribe(_ samples: [Float], sourceFrames: Frame, sourceRate: Double,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> [Word] {
        guard !samples.isEmpty else { return [] }
        try Task.checkCancellation()
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let socket = connect(request)
        defer { socket.close() }
        return try await withTaskCancellationHandler {
            let rate = SpeechAudio.rate
            // The server's default chunk is 28 seconds. Commit shorter turns ourselves so each
            // turn yields one final transcript, with cuts near pauses when the source is long.
            let cuts = SpeechAudio.cuts(samples, limit: rate * 24, search: rate * 4)
            try await exchange(on: socket) {
                try await send(["type": "session.update", "session": [
                    "type": "transcription", "audio": ["input": [
                        "format": ["type": "audio/pcm", "rate": rate],
                        "transcription": ["model": Self.model, "languages": ["sv"]],
                    ]],
                ]], on: socket)
                let response = try await receive("session.updated", on: socket)
                guard response.session?.audio?.input?.transcription?.model == Self.model else {
                    throw Failure("Berget did not confirm the Pianissimo model.")
                }
            }
            let scale = sourceRate / Double(rate)
            var words: [Word] = []
            for (start, end) in zip(cuts, cuts.dropFirst()) {
                let final = try await exchange(on: socket) {
                    for offset in stride(from: start, to: end, by: rate / 10) {
                        try Task.checkCancellation()
                        let pcm = SpeechAudio.pcm16(samples[offset..<min(end, offset + rate / 10)])
                        try await send(["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()], on: socket)
                    }
                    try await send(["type": "input_audio_buffer.commit"], on: socket)
                    let event = try await receive("conversation.item.input_audio_transcription.completed", on: socket)
                    guard let transcript = event.transcript else { throw Failure("Berget returned a completion without a transcript.") }
                    return transcript
                }
                let firstFrame = min(sourceFrames, Frame(Double(start) * scale))
                let lastFrame = end == samples.count ? sourceFrames : min(sourceFrames, Frame(Double(end) * scale))
                words += SpeechAudio.spread(final, over: firstFrame..<lastFrame)
                progress(Double(end) / Double(samples.count))
            }
            return words
        } onCancel: {
            socket.close()
        }
    }

    private func exchange<T>(on socket: any PianissimoSocket, _ body: () async throws -> T) async throws -> T {
        let deadline = ContinuousClock.now + .seconds(60)
        let timeout = Task {
            try await ContinuousClock().sleep(until: deadline)
            socket.close()
        }
        defer { timeout.cancel() }
        do { return try await body() }
        catch {
            try Task.checkCancellation()
            if ContinuousClock.now >= deadline { throw Failure("Berget did not answer in time.") }
            throw error
        }
    }

    private func send(_ fields: [String: Any], on socket: any PianissimoSocket) async throws {
        let data = try JSONSerialization.data(withJSONObject: fields)
        try await socket.sendText(String(decoding: data, as: UTF8.self))
    }

    private func receive(_ type: String, on socket: any PianissimoSocket) async throws -> Event {
        while true {
            try Task.checkCancellation()
            let event = try JSONDecoder().decode(Event.self, from: try await socket.receiveData())
            switch event.type {
            case type: return event
            case "error", "conversation.item.input_audio_transcription.failed":
                throw Failure(event.error?.message ?? "Berget could not transcribe this audio.")
            default: continue
            }
        }
    }

    private struct Event: Decodable {
        struct Session: Decodable {
            struct Audio: Decodable {
                struct Input: Decodable {
                    struct Transcription: Decodable { let model: String? }
                    let transcription: Transcription?
                }
                let input: Input?
            }
            let audio: Audio?
        }
        struct ProviderError: Decodable { let message: String? }
        let type: String
        let session: Session?
        let transcript: String?
        let error: ProviderError?
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}

protocol PianissimoSocket: Sendable {
    func sendText(_ text: String) async throws
    func receiveData() async throws -> Data
    func close()
}

extension URLSessionWebSocketTask: PianissimoSocket {
    func sendText(_ text: String) async throws { try await send(.string(text)) }
    func receiveData() async throws -> Data {
        switch try await receive() {
        case .string(let text): return Data(text.utf8)
        case .data(let data): return data
        @unknown default: throw URLError(.cannotDecodeContentData)
        }
    }
    func close() { cancel(with: .goingAway, reason: nil) }
}
