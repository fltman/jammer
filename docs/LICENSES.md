# Licence register

Jämmer is MIT. Every third-party component and model is listed here **before** it ships, with the licence text read at the source. Rules:

- No GPL/AGPL code in the app bundle. LGPL only as a dynamically linked library.
- No models with non-commercial terms (users may use Jämmer commercially).
- CC-BY and similar need attribution in the app's credits.
- Models are downloaded from their upstream source (configurable mirror), never from a server we run.

## Bundled code

| Component | Version | Licence | How it's used | Checked |
|---|---|---|---|---|
| Apple frameworks (AudioToolbox, AVFAudio, Accelerate, Metal, Network, AppKit, SwiftUI) | macOS 27 SDK | Apple SDK | System frameworks | — |

## Derived algorithms (no code copied)

| What | Source | Licence | Note |
|---|---|---|---|
| K-weighting at any sample rate | ITU-R BS.1770 analog prototype; constants as published in libebur128 | Standard / MIT | Reimplemented in `Loudness.swift`, tested against EBU Tech 3341/3342 |

## Test-only tools (not shipped)

| Tool | Use |
|---|---|
| ffmpeg (`ebur128` filter) | Independent loudness reference in tests; skipped when absent |
| afconvert / afinfo (macOS) | Interop tests for WAV/AIFF/AAC |

## Planned, not yet added

| Component | Licence (to verify) | Plan |
|---|---|---|
| LAME (MP3 encoder) | LGPL | Dynamic library only, phase 1 |
| KB-Whisper / whisper.cpp | Apache-2.0 / MIT | Phase 1 transcription |
| Parakeet v3 (via FluidAudio) | CC-BY-4.0 / Apache-2.0 | Phase 1, attribution |
| pyannote community-1 | CC-BY-4.0 | Phase 1 diarisation, attribution |
| DeepFilterNet 3 | to verify | Phase 1 noise reduction |
| Sparkle | MIT | Updates |
