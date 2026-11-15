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

## Measuring engines

`JAMMER_BENCH=1 swift test --filter TranscriptionBenchmark` speaks 14 Swedish podcast-style sentences with the macOS voice Alva at 180 and 230 words a minute and scores each engine with word error rate (`WordErrorRate`: substitutions, deletions and insertions over reference words, after lower-casing and removing punctuation; å, ä and ö count). The scorer is checked first against known cases (jiwer's "hello world" → "hello duck" = 50 %, one substitution plus one deletion in six words, insertions) and against a brute-force edit distance on random word lists.

Synthetic speech is clean and evenly paced, so these numbers flatter every engine; they're for comparing engines with each other, not for promising accuracy on real recordings.

### Results, 2026-11-15 (macOS 27.2.1)

| Engine | Speech | Words | S / D / I | WER |
|---|---|---|---|---|
| Apple dictation (sv-SE) | Alva, 180 wpm | 118 | 6 / 3 / 2 | 9.3 % |
| Apple dictation (sv-SE) | Alva, 230 wpm | 118 | 12 / 2 / 2 | 13.6 % |

All: 11.4 % WER over 236 words; 84 s of audio in 3.8 s (22× real time, including starting the recogniser for each sentence). Some errors are only formatting: numbers come out as digits ("en minut" → "1 minut", "sexton" → "16"), which the scorer counts as substitutions. Real errors: "podd" → "tåg", "LUFS" → "luft", "Kapitelmarkeringar" → "Kapitel marar", and dropped "och".

KB-Whisper (small, then medium) is next in this table; it becomes the default for Swedish only if it scores better here. Its model files are listed with size and SHA-256 in `JammerSpeech/Models.swift` and download from a configurable source (Hugging Face by default) into `Application Support/Jammer/Models` (`JAMMER_MODELS_DIR` during development), verified before use. The runtime, whisper.cpp (MIT), has no prebuilt Apple binary in its releases, so it has to be compiled from source; that's waiting for a go-ahead.
