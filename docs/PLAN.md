# Plan

Phases from the scoping research (2026-11-15), adopted as decisions. Each phase ships a usable app. Speech, restoration and post come first; MIDI and instruments come no earlier than after phase 3.

## Phase 0: Foundation, the vertical slice (in progress)

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
| RTSan dynamic check (needs upstream LLVM; Apple clang lacks the runtime) | Open |
| HAL IOProc via `AudioHardwareSystem`, audio workgroups for parallel rendering | Open (the default-output unit covers playback today) |
| Tempo map in the time model: frame-anchored tempo and time signature, bar.beat.tick, `set_tempo`/`remove_tempo_change` | Done |
| Multi-hour stress test (3 h file: peaks, zoom, export timings) | Open |
| Collect media into the package ("collect and save") | Open |

## Phase 1: MVP, the speech and audio editor

Replace the Audio Hijack → RX → Descript → Auphonic chain for speech and podcasts: multitrack for speech with double-ender import, spectrogram view with basic selection, restoration v1 (DeepFilterNet 3 with an amount control; de-click, de-clip, de-hum as DSP), transcription (KB-Whisper, Parakeet, SpeechTranscriber where Swedish is available) with text-based editing, diarisation, filler-word and silence suggestions, loudness presets, export to WAV/BWF, AIFF, FLAC, ALAC, AAC, MP3 (LAME, dynamic) and Opus, chapters, AU hosting, "Edit in Jämmer" from Flimmer, Developer ID + notarisation + Sparkle.

## Phase 2: Layers and restoration

Stem separation with stems as first-class layers, spectral painting tools, dialogue/music/effects separation, de-reverb and de-bleed, per-speaker levelling, batch processing, branching history, VST3 and CLAP with a scanner process, FCPXML import from Flimmer, Music Understanding for tempo and beats.

## Phase 3: Mix, mastering and post

Full mixer (buses, sends, VCA, sidechain, automation, PDC, freeze), ARA2, mastering chain, r8brain SRC and dither, DDP 2.0, own AAF reader, EDL, DAWproject, OTIO, SMPTE timecode, video reference, dialogue-gated loudness profiles.

## Phase 4: Immersive

Multichannel up to 7.1.4, ADM BWF, Ambisonics, APAC/ASAF export, binaural monitoring with head tracking, Overdub with consent flow.

## Deliberately out of scope

Clip launcher, large instrument libraries, generative session musicians, Windows, an own Dolby Atmos renderer without an agreement, models with non-commercial licences.
