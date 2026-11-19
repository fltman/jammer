import JammerAgent
import JammerCore
import JammerDiarize
import JammerSpeech

/// Whether each item of the install register is on this Mac, asked the same way Settings › Models asks
/// (`Requirements`; SIBLINGS, "Det som kan behöva installeras"). nil: not something Jämmer can tell (a plugin kind).
@MainActor
enum RequirementState {
    static func installed(_ id: String) -> Bool? {
        switch id {
        case "kb-whisper-small": SpeechEngines.store.isInstalled(ModelSpec.kbWhisperSmallQ5)
        case "kb-whisper-medium": SpeechEngines.store.isInstalled(ModelSpec.kbWhisperMediumQ5)
        case "parakeet-tdt-0.6b-v3": SpeechEngines.parakeet.isInstalled
        case "diarisation": (Diarization.engine as? FluidDiarizer)?.isInstalled ?? false
        case "spleeter-4stems": Stems.model.isInstalled
        case "mrx": Stems.soundtrack.isInstalled
        default: nil
        }
    }
}
