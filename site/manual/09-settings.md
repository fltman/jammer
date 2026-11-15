# Settings

**Jämmer › Settings…** (⌘,) has two tabs: **Models** (below) and **Agents**. A few other choices are remembered where you make them:

| Setting | Where | What it does |
|---|---|---|
| Show at launch | The splash (Help › Agent Access…) | Whether the splash appears when Jämmer starts |
| Playback volume | The slider in the transport bar | How loud Jämmer plays. It doesn't affect exports or measurements. |
| Transcription language | The menu in the transcript panel | The language Transcribe uses |
| Assistant model | The gear in the assistant panel | The model on this Mac, or your own OpenRouter model and key |
| Safe mode for plugins | Audio › Plugins… | Runs every Audio Unit in macOS's separate plugin host process instead of inside Jämmer |

Window size and position are remembered too.

## Agents

**Folders agents may use**: an agent normally works only on the documents you have open. Batch processing reads and writes files by path, and an agent can do that only inside the folders listed here. Add one with **Add Folder…**; remove it to take the permission back. The list starts empty. Batches you start yourself from File › Batch… don't need it.

## Models

![Settings, Models: KB-Whisper small and medium, Parakeet and the speaker model, each with size, licence and a Download or Remove button](../screens/models.webp)

**Jämmer › Settings… › Models** (⌘,) lists the speech models Jämmer can use. Each shows what it's for, its download size and its licence before you download it, and each can be removed again:

- **KB-Whisper** small or medium: the most accurate Swedish transcription (Apache-2.0).
- **Parakeet TDT 0.6B v3**: transcription in 25 European languages, Swedish and English among them, very fast (CC-BY-4.0; about 630 MB).
- **Stem separation** (Spleeter 4stems): vocals, drums, bass and other from a music track (MIT; 146 MB; from Deezer's own release).
- **Soundtrack separation** (MRX): speech, music and effects from film or video sound (MIT; 122 MB; from MERL's own repository).
- **Speaker diarisation**: for Find Speakers on a mixed recording (CC-BY-4.0; about 20 MB; also fetched by itself the first time).

When you transcribe, Jämmer picks KB-Whisper for Swedish if it's installed, otherwise Parakeet if it's installed and knows the language, otherwise the Mac's own recogniser, which needs no download. Agents can ask for a particular engine but can't download models; that's up to you.
