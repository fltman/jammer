import Foundation
import JammerCore

/// Overdub's steps, in the order rule 9 asks for: the attestation and the consent heard before anything leaves
/// the Mac (`prepareClone`), then the samples to the provider (`clone`), then speech in that voice (`speak`).
/// The window and the agent API both go through here; tests go through it with a stand-in provider.
public struct OverdubService: Sendable {
    public var provider: ElevenLabs
    /// The date of the provider's terms as read, kept with each voice's attestation.
    public static let termsRead = "ElevenLabs Terms of Service and Prohibited Use Policy, 9 October 2026 (read 2026-11-17)"

    public init(provider: ElevenLabs) { self.provider = provider }

    /// Everything that must hold before anything is uploaded; nothing is sent. `samples` and `consent` are
    /// seconds on the timeline. Returns the attestation to keep and the samples as WAV files.
    public static func prepareClone(_ project: Project, plan: RenderPlan, kind: VoiceAttestation.Kind?, adult: Bool,
                                    consent: ClosedRange<Double>, samples: [ClosedRange<Double>], now: Date = Date()) throws -> (VoiceAttestation, [Data]) {
        guard let kind else { throw OverdubError.notAttested }
        guard adult else { throw OverdubError.notAdult }
        let rate = project.sampleRate
        func frames(_ r: ClosedRange<Double>) -> Range<Frame> { Frame((r.lowerBound * rate).rounded())..<Frame((r.upperBound * rate).rounded()) }
        // The consent sentence, said in the recording, heard in its transcript.
        guard !project.transcripts.isEmpty else { throw OverdubError.noTranscript }
        let language = project.transcripts.first?.language ?? "en"
        let sentence = Overdub.consentSentence(language: language)
        let heard = project.placedWords(in: frames(consent)).map(\.word.text).joined(separator: " ")
        guard Overdub.says(heard, sentence: sentence) else { throw OverdubError.consentNotHeard(sentence) }
        // The samples: each at least 5 s, at least 10 s together, at most 3 minutes, inside the document.
        let length = Double(project.length) / rate
        guard samples.allSatisfy({ $0.lowerBound >= 0 && $0.upperBound <= length + 0.001 }) else { throw OverdubError.sampleOutside }
        let total = samples.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        guard samples.allSatisfy({ $0.upperBound - $0.lowerBound >= Overdub.minSample }), total >= Overdub.minTotal else { throw OverdubError.samplesTooShort }
        guard total <= Overdub.maxTotal else { throw OverdubError.samplesTooLong }
        let files = samples.map { r -> Data in
            let range = frames(r)
            let x = plan.render(from: range.lowerBound, frames: range.count)
            let n = plan.channels
            var mono = [Float](repeating: 0, count: range.count)
            for i in 0..<range.count { var s: Float = 0; for c in 0..<n { s += x[i * n + c] }; mono[i] = s / Float(n) }
            return ElevenLabs.wav(mono, rate: Int(rate))
        }
        let attestation = VoiceAttestation(kind: kind, adult: adult, sentence: sentence, heardAt: consent, heard: heard, date: now, termsRead: termsRead)
        return (attestation, files)
    }

    /// Sends the samples and keeps the voice with its attestation.
    public func clone(name: String, attestation: VoiceAttestation, samples: [ClosedRange<Double>], files: [Data], now: Date = Date()) async throws -> (ClonedVoice, needsVerification: Bool) {
        let description = attestation.kind == .own ? "Cloned in Jammer from the user's own voice, by their attestation." : "Cloned in Jammer with the voice owner's explicit consent, by the user's attestation."
        let (id, verify) = try await provider.clone(name: name, description: description, samples: files)
        return (ClonedVoice(provider: "elevenlabs", providerVoiceID: id, name: name, attestation: attestation, samples: samples, created: now), verify)
    }

    /// Speech in `voice`: the provider's MP3 written to `folder` as it came (its watermark kept), decoded into a
    /// source at the document's rate, marked as made in a cloned voice.
    public func speak(_ voice: ClonedVoice, text: String, model: String, previous: String?, next: String?, sampleRate: Double,
                      folder: URL, now: Date = Date()) async throws -> SourceRef {
        guard voice.deleted == nil else { throw OverdubError.voiceDeleted }
        guard voice.madeAfterStop != true else { throw OverdubError.voiceMadeAfterStop }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw OverdubError.emptyText }
        guard clean.count <= ElevenLabs.maxCharacters else { throw OverdubError.textTooLong(ElevenLabs.maxCharacters) }
        let (audio, _) = try await provider.speak(voiceID: voice.providerVoiceID, text: clean, model: model, previous: previous, next: next)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let kept = folder.appending(path: "overdub-\(UUID().uuidString.prefix(8)).mp3")
        try audio.write(to: kept)
        let imported = try AudioImporter.importFile(kept, sampleRate: sampleRate, mediaFolder: folder)
        var source = imported.source
        source.name = "Overdub: \(String(clean.prefix(40)))"
        // The file ElevenLabs sent stays where it is: the source names it as where the sound came from.
        source.originalPath = kept.path
        source.synthetic = SyntheticSpeech(voice: voice.id, voiceName: voice.name, provider: voice.provider, model: model, text: clean, made: now)
        return source
    }
}
