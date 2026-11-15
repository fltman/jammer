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
| KB-Whisper small (q5_0, whisper.cpp, Metal) | Alva, 180 wpm | 118 | 2 / 0 / 0 | 1.7 % |
| KB-Whisper small (q5_0, whisper.cpp, Metal) | Alva, 230 wpm | 118 | 2 / 0 / 0 | 1.7 % |
| Parakeet TDT 0.6B v3 (int8-v2, Core ML via FluidAudio) | Alva, 180 wpm | 118 | 5 / 1 / 0 | 5.1 % |
| Parakeet TDT 0.6B v3 (int8-v2, Core ML via FluidAudio) | Alva, 230 wpm | 118 | 5 / 1 / 0 | 5.1 % |
| Parakeet TDT 0.6B v3, English | Daniel (en-GB), 180 wpm | 62 | 0 / 0 / 0 | 0.0 % |
| Parakeet TDT 0.6B v3, English | Daniel (en-GB), 230 wpm | 62 | 0 / 0 / 0 | 0.0 % |

All: 11.4 % WER over 236 words; 84 s of audio in 3.8 s (22× real time, including starting the recogniser for each sentence). Some errors are only formatting: numbers come out as digits ("en minut" → "1 minut", "sexton" → "16"), which the scorer counts as substitutions. Real errors: "podd" → "tåg", "LUFS" → "luft", "Kapitelmarkeringar" → "Kapitel marar", and dropped "och".

KB-Whisper small: 1.7 % WER over 236 words at 8× real time (84 s in 10.4 s, beam search, model loaded once). Its only errors: "podd" → "pog"/"pogg" and "sexton" → "16". It beats Apple dictation clearly on this test, so it becomes the default for Swedish once its model is installed; Apple dictation remains the fallback that needs no download. Medium is next in this table.

Parakeet TDT 0.6B v3 (2026-11-15): 5.1 % WER on the Swedish (236 words) at 41× real time, 0.0 % on the English (124 words, seven sentences at two speeds) at 40× real time, model loaded once; the download is about 630 MB and took 88 s here. Its Swedish errors: "podd hemma" → "podghemma", "gardiner" → "gadiner", "igenom" → "genom", "sexton" → "16" and "LUFS" → "luffs"/"lufts". So for Swedish it sits between Apple dictation (11.4 %) and KB-Whisper (1.7 %), five times faster than KB-Whisper; its strength is the other 24 languages, where Apple's recognisers vary and KB-Whisper doesn't apply. `engine: auto` therefore takes KB-Whisper for Swedish when it's installed, then Parakeet for its 25 languages when it's installed, then Apple. The English set is short and clean synthetic speech; treat 0.0 % as "no errors here", not as a general figure. Measured with `Tests/JammerParakeetTests` (`JAMMER_BENCH=1`); the int8-v2 encoder is used because FluidAudio reports token corruption with the original 6-bit one (issue #760).

A bug the benchmark caught: Whisper's tokens are bytes and can split a UTF-8 character, so "för" came out as "f��r" when tokens were decoded one by one. Words are now decoded only once complete. Its model files are listed with size and SHA-256 in `JammerSpeech/Models.swift` and download from a configurable source (Hugging Face by default) into `Application Support/Jammer/Models` (`JAMMER_MODELS_DIR` during development), verified before use. The runtime, whisper.cpp (MIT), has no prebuilt Apple binary in its releases; `scripts/build-whisper.sh` builds it from a pinned commit (v1.9.5) into `Packages/JammerKit/Vendor/whisper.xcframework` (not committed), and the package includes the Whisper engine only when that exists.
