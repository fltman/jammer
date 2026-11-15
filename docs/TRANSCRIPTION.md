# Transcription

## The model: the transcript is a view of the edit list

- A `Word` is anchored to the **source** it was heard in, in source frames (`JammerCore/Transcript.swift`). Edits never touch sources, so the anchors never need updating.
- What the transcript *reads* is computed from the clips each time (`Project.placedWords`): a word plays at `clip.start + (word.start − clip.sourceStart)`, clipped to the clip. Delete, cut, paste, crop, silence and undo on the waveform change the transcript by themselves; it can't disagree with what plays.
- Deleting words is a ripple delete of their timeline ranges (`deleteWords`), bit-identical to deleting those ranges by hand. Optionally the pauses between selected words go too (`bridge`).
- Correcting a word changes its text only; the audio doesn't change.
- Copy and paste carry the words of the sources involved, also into another project.

## Engines on this machine (2026-11-15, macOS 27.2.1, build 26B131)

`SpeechTranscriber.supportedLocales` lists 45 locales: bn-IN de-AT de-CH de-DE en-AU en-CA en-GB en-IE en-IN en-NZ en-SG en-US en-ZA es-CL es-ES es-MX es-US fr-BE fr-CA fr-CH fr-FR gu-IN hi-IN it-CH it-IT ja-JP kn-IN ko-KR ks-IN mai-IN ml-IN mr-IN mul-IN ne-IN or-IN pa-IN pt-BR pt-PT ta-IN te-IN ur-IN yue-CN zh-CN zh-HK zh-TW.

- **Swedish is not supported by SpeechTranscriber** (`supportedLocale(equivalentTo: sv-SE)` is nil).
- **`DictationTranscriber` supports sv-SE.** Its assets download on first use (`AssetInventory`, system-managed, a few hundred MB). With `attributeOptions: [.audioTimeRange, .transcriptionConfidence]` it returns one run per word with a time range and a confidence. Punctuation arrives as zero-length runs.
- Probe on synthetic speech (macOS voice Alva, sv_SE, 6.8 s): 18 of 19 words right; "ljudredigering" came out as "ju redigering" with confidence 0.70/0.50, against 0.8–0.9 for the words it got right. Low confidence is worth showing.

The app asks `supportedLocales` at run time (the list changes with OS updates) and picks SpeechTranscriber, then DictationTranscriber, for the document's language. KB-Whisper (better Swedish word error rate, see the research report) and Parakeet TDT v3 come next as downloadable engines; their licences are in `LICENSES.md`.
