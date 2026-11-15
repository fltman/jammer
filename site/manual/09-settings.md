# Settings

**Jämmer › Settings…** (⌘,) holds the speech models (below). A few other choices are remembered where you make them:

| Setting | Where | What it does |
|---|---|---|
| Show at launch | The splash (Help › Agent Access…) | Whether the splash appears when Jämmer starts |
| Playback volume | The slider in the transport bar | How loud Jämmer plays. It doesn't affect exports or measurements. |
| Transcription language | The menu in the transcript panel | The language Transcribe uses |
| Assistant model | The gear in the assistant panel | The model on this Mac, or your own OpenRouter model and key |
| Safe mode for plugins | Audio › Plugins… | Runs every plugin in a process of its own |

Window size and position are remembered too.

## Models

![Settings, Models: KB-Whisper small and medium, Parakeet and the speaker model, each with size, licence and a Download or Remove button](../screens/models.webp)

**Jämmer › Settings… › Models** (⌘,) lists the speech models Jämmer can use. Each shows what it's for, its download size and its licence before you download it, and each can be removed again:

- **KB-Whisper** small or medium: the most accurate Swedish transcription (Apache-2.0).
- **Parakeet TDT 0.6B v3**: transcription in 25 European languages, Swedish and English among them, very fast (CC-BY-4.0; about 630 MB).
- **Speaker diarisation**: for Find Speakers on a mixed recording (CC-BY-4.0; about 20 MB; also fetched by itself the first time).

When you transcribe, Jämmer picks KB-Whisper for Swedish if it's installed, otherwise Parakeet if it's installed and knows the language, otherwise the Mac's own recogniser, which needs no download. Agents can ask for a particular engine but can't download models; that's up to you.
