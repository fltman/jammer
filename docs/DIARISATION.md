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
