# Plan

Phases from the scoping research (2026-11-15), adopted as decisions. Each phase ships a usable app. Speech, restoration and post come first; MIDI and instruments come no earlier than after phase 3.

## Phase 0: Foundation, the vertical slice (done)

Goal: open a WAV of several hours, zoom smoothly, play, cut, undo, export bit-exactly, and let an agent do the same.

| Item | Status |
|---|---|
| C++20 realtime core: render plan, lock-free ring, render worker, compiler-checked `nonblocking` audio thread | Done |
| Deterministic offline renderer, null tests | Done |
| WAV/RF64/BW64/AIFF/AIFF-C reader and WAV/RF64 writer keeping bext, iXML, markers, foreign chunks | Done |
| Import of compressed formats via AVFAudio (decoded once) | Done |
| Project model and edits (ripple delete, cut/copy/paste, crop, silence, gain, fades, markers), undo | Done |
| BS.1770-5 / R 128 meter validated against EBU Tech 3341/3342 and ffmpeg | Done |
| Multi-resolution peak index with disk cache | Done |
| `.jammer` package, window restoration | Done |
| AppKit app: Metal timeline, transport, status bar, menus, ⌘K palette | Done |
| Default-output playback feeding the engine | Done |
| Agent API on 127.0.0.1:9003 (then 9301–9319), guide, splash, uploads | Done, verified end to end with curl |
| Site content (`site/`): app.json, FAQ, manual, generated agents.md, hero | Done for what exists |
| RTSan dynamic check: `scripts/rtsan.sh` builds the engine with upstream clang (`-fsanitize=realtime`) and drives pull, the IOProc (resampling) and the AU callback with seeks and plan swaps; `--plant` proves it catches a violation | Done (LLVM 20.1.8) |
| HAL IOProc on the default device (C HAL API; the SDK has no `AudioHardwareSystem`), routing to the device's stereo pair, resampling in the render worker when the device rate differs, following device and rate changes; AUHAL as fallback | Done; device switching not yet tried by hand |
| Audio workgroups | Deferred: the worker renders 340 ms ahead and isn't tied to the device deadline. Joining `kAudioDevicePropertyIOThreadOSWorkgroup` pays off once rendering moves into the device cycle (low-latency monitoring, plugin chains), phase 1–2 |
| Tempo map in the time model: frame-anchored tempo and time signature, bar.beat.tick, `set_tempo`/`remove_tempo_change` | Done |
| Multi-hour stress test (`scripts/stress.sh`, results in `docs/STRESS.md`); zoomed-in waveform reads moved off the main thread after it found 150 ms stalls | Done |
| Collect media into the package: File › Collect Audio and Save copies (clones on APFS) every used source into `Media/`; undo steps follow | Done, verified in the app (original deleted, project plays from its copy) |

## Phase 1: MVP, the speech and audio editor

| Item | Status |
|---|---|
| Licence register for the phase 1 models, read at the source | Done (`LICENSES.md`) |
| Transcripts as a view of the edit list; text-based deleting and correcting | Done |
| Apple speech engine (SpeechTranscriber; DictationTranscriber for Swedish) | Done (`TRANSCRIPTION.md`) |
| Agent API: jobs, transcribe, transcript, delete_words, correct_word | Done, verified with curl |
| Restoration v1 DSP: de-hum, de-clip, de-click, golden renders | Done |
| Restoration through new sources; analysis, preview, restore jobs in the API | Done, verified with curl |
| App: transcript panel, Restore sheet with A/B preview | Done, checked in the app |
| DeepFilterNet 3 (libDF) with amount control | Done (Reduce Noise; `restore` kind denoise) |
| KB-Whisper engine (1.7 % WER on synthetic Swedish) | Done |
| Export: AIFF, FLAC, ALAC, AAC, Ogg Opus (own muxer), MP3 (LAME, dynamic) | Done |
| Chapters from markers: ID3 CHAP in MP3, Podcasting 2.0 JSON, `GET …/chapters` | Done |
| Chapters in AAC/M4A (QuickTime chapter track via AVAssetWriter) and Ogg Opus (CHAPTERxxx comments, OpusTags across pages) | Done; read back by AVFoundation and ffprobe |
| Loudness presets (Apple Podcasts, Spotify, YouTube, EBU R 128, ATSC A/85), peak-limited gain without a limiter | Done |
| ACX/Audible preset (RMS −23…−18 dB, peak ≤ −3 dB, noise floor ≤ −60 dB): needs its own measurement and the phase 3 limiter | Planned (phase 3) |
| Built-in assistant, sibling tools, plan impact | Done (`ASSISTANT.md`) |
| AU hosting: AUv2/AUv3 effect inserts per track in the render worker (not the device thread), fixed 512-frame quanta, latency compensated, reset and pre-roll on seek; settings as full state in the document; safe mode loads every plugin out of process, and in-process failures fall back to it; exports and loudness use units of their own; agent API (`/plugins`, add/set/remove_insert, insert detail) | Done, verified with curl and in the app (Apple's AUPeakLimiter window) |
| Diarisation: by_track (bleed-aware VAD per track) and ml (FluidAudio, pyannote Community-1 Core ML, CC-BY-4.0); turns anchored in sources, words labelled, rename_speaker, `POST …/diarize`, `GET …/speakers` | Done (`DIARISATION.md`: by_track 3.6 %, easy 1.2 %, hard 59 % / 46 % with the count given) |
| Parakeet engine (v3 via FluidAudio; engine auto/apple/parakeet/whisper; Settings › Models with size and licence) | Done (Swedish 5.1 %, English 0.0 %, ~40× real time; `TRANSCRIPTION.md`) |

Replace the Audio Hijack → RX → Descript → Auphonic chain for speech and podcasts: multitrack for speech with double-ender import, spectrogram view with basic selection, restoration v1 (DeepFilterNet 3 with an amount control; de-click, de-clip, de-hum as DSP), transcription (KB-Whisper, Parakeet, SpeechTranscriber where Swedish is available) with text-based editing, diarisation, filler-word and silence suggestions, loudness presets, export to WAV/BWF, AIFF, FLAC, ALAC, AAC, MP3 (LAME, dynamic) and Opus, chapters, AU hosting, "Edit in Jämmer" from Flimmer, Developer ID + notarisation + Sparkle.

## Phase 2: Layers and restoration

| Item | Status |
|---|---|
| Per-speaker levelling, static: one gain per speaker over their turns (`level_speakers`) | Done |
| Per-speaker levelling, dynamic: centred 3 s short-term over own speech, zero-phase smoothing, segments at pauses > 5 s, pauses never lifted (`level_speakers mode dynamic`) | Done (8 dB drop → both halves within 0.2 LU; spread 8.2 → 1.5 LU; no overshoot after a 7 s pause) |
| Branching history: a tree of states saved in the package, View › History, `GET …/history` and `POST …/history/{node}`; one agent request is one undo step (explicit groups, AppKit only closes its automatic ones after user events) | Done, verified in the app (jump and undo bit-exact, survives save and open) |
| Spectral tools (lasso and brush are in the release by Anders's decision of 2026-11-15, see `RELEASE.md`; switch `JAMMER_SPECTRAL_FREEFORM`): box, lasso, brush in the spectrogram; heal (≤ 0.5 s, log-magnitude interpolation, phase kept) and attenuate; `spectral_edit`; numeric entry | Done, verified in the app |
| Loudness of lossy exports: mp3, aac and opus are read back, measured and re-encoded with corrected gain (at most two corrections, never past the ceiling) when the document was just brought to a preset or the export gives `targetLUFS`; `loudness`, `compensatedDB`, `loudnessFrom` per batch file, `X-Jammer-Loudness` headers on export | Done (MP3 at 160 and 64 kbit/s: −16.4 → −16.0 LUFS with +0.44 dB, checked with ffmpeg's ebur128; AAC and Opus were on target as encoded) |
| De-reverb: WPE (delayed linear prediction per band, no model), amount default 0.7; `restore` kind `dereverb`, Audio › Reduce Reverb…, batch; `analyze_restoration` reports `reverb {rt60, present}` | Done (tails −6.7 dB, noise floor +0.02 dB at 15 dB SNR, dry −0.02 dB; reverberation time calibrated on clean voices, see `RESTORATION.md`). In the release by Anders's decision of 2026-11-15 (`RELEASE.md`, `PATENTS.md`); can be left out with the switch in `Config/Features.xcconfig` |
| De-bleed: gate outside each track's turns (equal-power ramps, own speech bit-exact) and cancel (GCC-PHAT delay up to 1 s, per-bin transfer learnt where the track is silent); `debleed` | Done (same room −28.7 dB, remote 180 ms −16.1 dB, own voice ±0.0 dB) |
| Batch: File › Batch… with recipes (JSON), `POST /api/v1/batch` limited to folders the user allows in Settings › Agents (canonical paths; symlinks and .. can't leave), inputs never overwritten; each result's loudness read back from the written file | Done, verified in the app, Run and Add Folder… by hand |
| Stem separation: **not HTDemucs**. The code is MIT, but its author wrote "The model weights are not covered by the MIT license, and are provided only for scientific purposes" (facebookresearch/demucs #327, 2022-05-23; again #508), and it was trained on MUSDB18-HQ (non-commercial); every MLX and Core ML port redistributes those same weights. Instead, in order: (1) Apple's AUSoundIsolation (system AU, aufx/vois) for voice versus the rest; works as an insert, but starting it took minutes here; (2) Spleeter 4stems (Deezer, weights explicitly MIT), converted by us with a parity test against Spleeter's own output, stems as gain-linked layers; (3) MRX (MERL cocktail-fork, "All files … MIT" including the checkpoints) for dialogue/music/effects, with the training-data caveat (DnR includes some CC-NC clips) in LICENSES.md | (1) not reliable here (start-up hung twice at full CPU), left as an ordinary plugin; (2) done: `separate`, track groups, `set_track`, `set_group` (`STEMS.md`: null −138 dB, parity 110–137 dB); (3) done: `separate` model dialog (parity 121–129 dB against PyTorch, null −144 dB) |

Stem separation with stems as first-class layers, spectral painting tools, dialogue/music/effects separation, de-reverb and de-bleed, per-speaker levelling, batch processing, branching history, VST3 and CLAP with a scanner process, FCPXML import from Flimmer, Music Understanding for tempo and beats.

## Phase 3: Mix, mastering and post

Full mixer (buses, sends, VCA, sidechain, automation, PDC, freeze), ARA2, mastering chain, r8brain SRC and dither, DDP 2.0, own AAF reader, EDL, DAWproject, OTIO, SMPTE timecode, video reference, dialogue-gated loudness profiles.

## Phase 4: Immersive

Multichannel up to 7.1.4, ADM BWF, Ambisonics, APAC/ASAF export, binaural monitoring with head tracking, Overdub with consent flow.

## Deliberately out of scope

Clip launcher, large instrument libraries, generative session musicians, Windows, an own Dolby Atmos renderer without an agreement, models with non-commercial licences.
