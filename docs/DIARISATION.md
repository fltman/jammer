# Diarisation: who speaks when

`diarize` (Audio › Find Speakers, `POST …/diarize`) labels the document with speakers. The turns are anchored in the source files like transcript words, so they survive every edit; the transcript's words take the speaker whose turn overlaps them most.

## Two modes

- **by_track**: each track is one speaker, named after the track. For double-enders (each person recorded on their own), this is simpler and more exact than any model. A track counts as speaking where it's at least 12 dB above its own noise floor *and* at least 6 dB louder than the other tracks' bleed into it would make it. The bleed level between two tracks is measured where one of them clearly talks alone (10 dB above all others), so cross-talk doesn't count and real overlaps count for both. Default when several tracks play at the same time.
- **ml**: pyannote Community-1 through FluidAudio's offline pipeline (segmentation, WeSpeaker embeddings, PLDA, VBx clustering), on each track separately (mono, 16 kHz). Default otherwise. Speakers are per track; pair them up across tracks with `rename_speaker`. `speakers`, or `minSpeakers` and `maxSpeakers`, constrain the count.

## Model and licences

FluidAudio v0.18.3 (Apache-2.0) is compiled from source into the app, only its diarisation code (`scripts/fetch-fluidaudio.sh`, pinned commit). The model files are FluidInference's Core ML conversions of pyannote speaker-diarization-community-1, revision df2625ac, CC-BY-4.0; only the five Community-1 files (Segmentation, FBank, Embedding, PldaRho, plda-parameters.json, about 20 MB) are fetched on first use from the model source: Hugging Face unless set otherwise with `defaults write com.brattoo.jammer models.source https://your-mirror`. The repository's older files, outside that licence scope, are never loaded. Details and attribution: `LICENSES.md`, `App/Credits.html`.

## Measured (2026-11-15)

Synthetic speech only (macOS voices, no real people), made by `Tests/JammerDiarizeTests/DiarizeEval.swift` (`JAMMER_BENCH=1`). DER = (missed + false alarm + confusion) / reference speech, 10 ms frames, overlap scored per speaker; also with the common 0.25 s collar around reference boundaries.

| Case | Mode | DER | With 0.25 s collar | Notes |
|---|---|---|---|---|
| Two tracks, each talker plus the other at −20 dB, two overlaps (synthetic bursts, `DiarizationTests`) | by_track | 3.6 % | — | All false alarm: the 50 ms padding at each turn's ends |
| Easy: woman (Alva, Swedish) and man (Daniel, English), 6 long turns, 36 s of speech | ml, count found | 1.2 % | 0.0 % | Found 2 speakers |
| Hard: two Scandinavian women (Alva, Swedish; Nora, Norwegian), 18 turns, many under 1 s, 4 overlaps, 21 s of speech | ml, count found | 59.0 % | 47.9 % | Found **1** speaker: the voices were merged |
| Hard, the same | ml, `speakers: 2` | 46.2 % | 28.7 % | Mostly confusion on the short turns |

Honestly: the model separates different-sounding voices with long turns almost perfectly, and struggles with similar voices in rapid back-and-forth, as diarisation models generally do. What helps, in order: record each person on their own track and use `by_track`; tell `ml` how many speakers there are; check and fix names in the transcript. Synthetic voices are cleaner than real ones in some ways (no room, no mic changes) and less varied in others, so treat these as a sanity check, not a benchmark.

## Voice profiles: the threshold, measured before the feature is shown (2026-11-19)

A voiceprint is the Community-1 model's own speaker embedding (WeSpeaker, 256 values) of a speaker's spans, through FluidAudio's `embedSpans` (no new model): each span's embedding made unit length, averaged, made unit length again (`VoicePrint`, `FluidDiarizer.voiceprints`). Two prints are compared by their cosine. `VoiceprintEval` (`JAMMER_BENCH=1`, the corpus in `JAMMER_CORPUS`) makes a profile from up to four utterances of one chapter of a reader and tries it against up to three utterances of another chapter by the same reader (should match) and by every other reader (should not): clean, with white noise at 15 dB SNR, as a phone line (300–3400 Hz and noise at 25 dB) and in a room (a decaying tail, RT60 0.5 s, half wet). The profile is always made from clean speech.

**LibriSpeech test-clean** (40 real, consenting readers, CC BY 4.0, downloaded with Anders's yes; MD5 matched to the source's list; never in the repository): 120 same-reader pairs and 4 680 other-reader pairs per condition.

| Threshold | False matches (clean / noise / phone / room) | Misses (clean / noise / phone / room) |
|---|---|---|
| 0.50 | 0.04 % / 0.04 % / 0.06 % / 0.02 % | 2.5 % / 3.3 % / 3.3 % / 2.5 % |
| 0.55 | 0 / 0 / 0 / 0 | 2.5 % / 5.8 % / 6.7 % / 3.3 % |
| **0.60** | **0 / 0 / 0 / 0** | **4.2 % / 13.3 % / 19.2 % / 5.8 %** |
| 0.65 | 0 / 0 / 0 / 0 | 5.8 % / 31.7 % / 25.0 % / 14.2 % |

**macOS voices** (8 synthetic voices: Samantha, Daniel, Karen, Moira, Tessa, Rishi, Flo, Alva; 24 same-voice and 168 other-voice pairs per condition): at 0.55, 2.4 % / 0.6 % / 0.6 % / 0 false matches; at **0.60, 0.6 % / 0.6 % / 0.6 % / 0** (one pair each, voices from the same speech engine) and no misses; at 0.65 no false matches clean and 8.3 % misses with noise.

**Chosen: 0.60.** No false match among real readers in any condition, one in 168 among the most alike synthetic voices; a miss only leaves a speaker's ordinary name, while a false match would suggest the wrong person (and a suggestion is shown with its likeness and undone in one step). "0 of 4 680" means under about 0.06 % with the usual three-in-n bound, not none. Misses grow with noise and a phone line: a profile made from a clean studio recording recognizes its owner on the phone about four times in five. Synthetic voices are evener than real ones, which is why the real readers decide.

