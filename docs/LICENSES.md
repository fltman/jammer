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

| whisper.cpp with ggml | v1.9.5 (d1be6fd) | MIT, "Copyright (c) 2023-2026 The ggml authors" ([LICENSE](https://github.com/ggml-org/whisper.cpp/blob/master/LICENSE), read 2026-11-15) | Static library built from source by `scripts/build-whisper.sh` (Metal, Accelerate; no examples, no server); runs KB-Whisper | 2026-11-15 |

| DeepFilterNet libDF (Rust) with the DeepFilterNet3 model | 7b14b89 | MIT or Apache-2.0 (we take MIT), "Copyright (c) 2021 Hendrik Schröter"; model weights under the same licence | Static library built from source by `scripts/build-libdf.sh` (`--features capi`); the 7.6 MB model ships with the app | 2026-11-15 |
| 146 Rust crates linked into libDF (tract ONNX runtime, ndarray, rubato, …) | Cargo.lock at 7b14b89 | All permissive: 87 MIT OR Apache-2.0, 20 MIT/Apache-2.0, 12 MIT, 4 Apache-2.0, plus BSD-2/3, Zlib, Unlicense/MIT, 0BSD, BSL-1.0 dual, CC0-1.0 and Unicode-DFS-2016; no GPL, LGPL or non-commercial terms. Full list: [licenses/libdf-crates.tsv](licenses/libdf-crates.tsv) (from `cargo metadata`, normal dependencies only) | Linked in libDF | 2026-11-15 |

| LAME | 3.100 (tarball SHA-256 ddfe36ca…da1e, checked by the build script) | LGPL-2.0-or-later (COPYING in the source; copied into the framework's Resources) | Dynamic framework built from source by `scripts/build-lame.sh`, loaded by the app and replaceable by the user, as the LGPL requires; MP3 export only. Source: https://lame.sourceforge.io | 2026-11-15 |
| FluidAudio (Swift) | v0.18.3 (c8b41f98) | Apache-2.0 ([LICENSE](https://github.com/FluidInference/FluidAudio/blob/main/LICENSE), read 2026-11-15) | Its source compiled into the app by our package (fetched by `scripts/fetch-fluidaudio.sh`, pinned commit checked): only the `Diarizer` code, offline Community-1 pipeline. Not its manifest, whose prebuilt NemoTextProcessing binary we leave out; no TTS. Include the Apache-2.0 notice in About | 2026-11-15 |
| ↳ fastcluster (C++, inside FluidAudio's FastClusterWrapper) | as vendored in FluidAudio v0.18.3 | BSD-2-Clause, "© 2011 Daniel Müllner; changes from 1.1.24 © Google Inc." ([LICENSE](https://github.com/fastcluster/fastcluster/blob/master/LICENSE), read 2026-11-15; the vendored header has no licence text) | Centroid-linkage clustering for diarisation. Reproduce the notice in About | 2026-11-15 |

## Derived algorithms (no code copied)

| What | Source | Licence | Note |
|---|---|---|---|
| K-weighting at any sample rate | ITU-R BS.1770 analog prototype; constants as published in libebur128 | Standard / MIT | Reimplemented in `Loudness.swift`, tested against EBU Tech 3341/3342 |

## Test-only tools (not shipped)

| Tool | Use |
|---|---|
| ffmpeg (`ebur128` filter) | Independent loudness reference in tests; skipped when absent |
| afconvert / afinfo (macOS) | Interop tests for WAV/AIFF/AAC |

## Models: licences read at the source (phase 1)

Read 2026-11-15 at the pages linked. "Read" means the licence statement on the model card or the licence file itself, not a summary elsewhere. None of these is in the app yet; each one goes in only after this row says it may.

| Model | Licence as stated | Source read | Weights covered? | Conditions for Jämmer | Verdict |
|---|---|---|---|---|---|
| KB-Whisper large / small / base (KBLab) | Apache-2.0 (card metadata "License: apache-2.0"; no licence file in the repo) | [kb-whisper-large](https://huggingface.co/KBLab/kb-whisper-large), [small](https://huggingface.co/KBLab/kb-whisper-small), [base](https://huggingface.co/KBLab/kb-whisper-base) | The repo holds the weights; KBLab states one licence for it | Keep the Apache-2.0 notice. Citation requested (Vesterbacka et al., Interspeech 2025, doi 10.21437/Interspeech.2025-2646): credit in About. Formats offered: HF, whisper.cpp GGML (small: 488 MB, q5_0 175 MB), ONNX, CTranslate2 | **OK** |
| ↳ upstream: OpenAI Whisper | MIT: "Whisper's code and model weights are released under the MIT License", "Copyright (c) 2022 OpenAI". The HF card for openai/whisper-small says apache-2.0; both are permissive | [openai/whisper](https://github.com/openai/whisper), [LICENSE](https://github.com/openai/whisper/blob/main/LICENSE), [whisper-small](https://huggingface.co/openai/whisper-small) | Yes, explicitly | Include the MIT notice (Copyright (c) 2022 OpenAI) | OK |
| ↳ training data: KBLab/rixvox-v2 | ODC-By (dataset metadata) | [rixvox-v2](https://huggingface.co/datasets/KBLab/rixvox-v2) | Data, not weights | ODC-By asks for attribution of the database; mention it with KB-Whisper's credit | OK |
| Parakeet TDT 0.6B v3 (NVIDIA) | CC-BY-4.0: "Use of this model is governed by the CC-BY-4.0 license", "ready for commercial/non-commercial use" | [nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) | The card licenses the model as a whole | Attribution in About (NVIDIA, link to the licence, say if we use a converted copy). 25 languages including Swedish (sv) | **OK, attribute** |
| ↳ Core ML conversion (FluidInference) | Metadata cc-by-4.0, body text says "Apache 2.0": contradictory | [parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) | Converted weights | Treat as CC-BY-4.0 (the stricter, and the upstream's): credit NVIDIA and FluidInference and say it's a modified Core ML conversion. **In use** since 2026-11-15, re-read at revision 7dd20fe (card metadata cc-by-4.0, body text still "Apache 2.0"): Preprocessor, Encoder_v2 (int8-v2), Decoder, JointDecisionv3 and the vocabulary, about 630 MB, downloaded only when the user installs it in Settings › Models; attributed in Credits | OK, attribute |
| pyannote speaker-diarization-community-1 | CC-BY-4.0: "released under the CC-BY-4.0 license and will always remain freely accessible" | [pyannote/speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1) | The pipeline repo (configs and weights) | **Gated**: download needs a Hugging Face login, accepted conditions and a token. Attribution with the three cited papers (Plaquet 2023, Wang 2023, Landini 2022) | OK, attribute; not downloaded itself: Jämmer uses FluidInference's ungated Core ML conversion (next row) |
| ↳ Core ML conversion (FluidInference speaker-diarization-coreml) | "scoped-cc-by-4.0"; NOTICE.md: "mixed-license-scope repository" | [speaker-diarization-coreml](https://huggingface.co/FluidInference/speaker-diarization-coreml), [NOTICE.md](https://huggingface.co/FluidInference/speaker-diarization-coreml/blob/main/NOTICE.md) | The Community-1 set (Segmentation, FBank, Embedding, PLDA, PldaRho, plda-parameters.json, xvector-transform.json) is CC-BY-4.0. Legacy files differ: segmentation-3.0 MIT (CNRS), WeSpeaker CC-BY-4.0 | Ungated. Attribution as NOTICE.md asks: name pyannote, WeSpeaker, BUT Speech@FIT and Fluid Inference, keep the citations, link CC-BY-4.0, say the files are modified Core ML conversions. Use only the Community-1 set. **In use** since 2026-11-15: FluidAudio's offline diariser loads exactly Segmentation, FBank, Embedding, PldaRho and plda-parameters.json at the pinned revision df2625ac (its `requiredModels`), never the legacy files. The PLDA files come from BUT Speech@FIT, CC-BY-4.0 with commercial use explicitly allowed ([licence](https://huggingface.co/BUT-FIT/diarizen-wavlm-large-s80-md/blob/6285693ddd5b38e8229acb93f864f3d04a82bee1/plda/LICENSE)). Downloaded on first use from the user's model source, not bundled | OK, attribute |
| DeepFilterNet 3 | MIT or Apache-2.0 at our option: "All code and model weights in this repository are dual-licensed", "Copyright (c) 2021 Hendrik Schröter" | [Rikorose/DeepFilterNet](https://github.com/Rikorose/DeepFilterNet), [LICENSE-MIT](https://github.com/Rikorose/DeepFilterNet/blob/main/LICENSE-MIT) | Yes, explicitly | Take MIT; include the notice. ONNX exports exist (`DeepFilterNet3_onnx.tar.gz`, `DeepFilterNet3_ll_onnx.tar.gz`). The README says nothing about the training data's terms; the author licenses the weights, which is what we rely on | **OK** |
| MRX, Multi Resolution CrossNet (MERL, cocktail-fork-separation), dialogue/music/effects | MIT: LICENSE.md is MIT, and the README says "All files: Copyright (c) 2023 Mitsubishi Electric Research Laboratories (MERL). SPDX-License-Identifier: MIT"; the four checkpoints are files of that repository (`checkpoints/*.pth`, git LFS) | [merlresearch/cocktail-fork-separation](https://github.com/merlresearch/cocktail-fork-separation) (read 2026-11-15) | Yes: the rights holder licenses all files, checkpoints included, as MIT | **Caveat on training data:** trained on Divide and Remaster (DnR, CC BY 4.0 as a dataset), built from LibriSpeech, FMA and FSD50K, which include some clips under CC BY-NC licences. Unlike HTDemucs, whose author excluded the weights from MIT, MERL licenses these weights as MIT; we rely on that and record the caveat here. **In use** since 2026-11-15 (Anders approved fetching it): `default_mrx_pre_trained_weights.pth`, SHA-256 9cecc071…0a0c, downloaded by the user from MERL's repository and read directly | OK, with the caveat noted |
| Spleeter 4stems (Deezer) | MIT, for code and models: "Spleeter … source code and pre-trained models are available on github and distributed under a MIT license" (JOSS paper, doi 10.21105/joss.02154); LICENSE "Copyright (c) 2019-present, Deezer SA."; trained on Deezer's internal data | [deezer/spleeter](https://github.com/deezer/spleeter), release v1.4.0 `4stems.tar.gz` (SHA-256 3adb4a50…dfaa8, checked before unpacking) | Yes, explicitly | Include the MIT notice; cite Hennequin et al., JOSS 2020. **In use** since 2026-11-15: downloaded by the user from Deezer's release, read directly (no converted copy) | **OK** |
| HTDemucs (Meta, demucs) | Code MIT; weights **not**: "The model weights are not covered by the MIT license, and are provided only for scientific purposes" (author, facebookresearch/demucs #327, 2022-05-23; #508: "Weights are provided for research purpose!"); trained on MUSDB18-HQ (non-commercial) | [demucs #327](https://github.com/facebookresearch/demucs/issues/327) | No | Not used, bundled or as a download; the MIT tags on mirrors and ports are inherited claims, not grants | **Excluded** |
| Silero VAD | MIT (LICENSE: "Copyright (c) 2020-present Silero Team"; README: "Published under permissive license (MIT)") | [snakers4/silero-vad](https://github.com/snakers4/silero-vad), [LICENSE](https://github.com/snakers4/silero-vad/blob/master/LICENSE) | The weights ship in the same repo under it | Include the MIT notice. Note: the README badge's alt text says "CC BY-NC 4.0" while its image and the LICENSE file say MIT; the LICENSE file governs | **OK** |
| FluidAudio SDK (Swift, code) | Apache-2.0 | [FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio) | Code only; each model has its own licence (above) | Include the Apache-2.0 notice if we link it. Don't use its Sortformer models (NVIDIA Open Model License, not reviewed) | OK for the listed models |

### Gated downloads

pyannote community-1 itself requires each downloader to log in to Hugging Face and accept conditions. Jämmer runs no server, so it can't mirror the files for users. Two options, both without our own server: use FluidInference's ungated Core ML conversion of the Community-1 set (CC-BY-4.0, attribution above), or let the user sign in with their own Hugging Face token (kept in the Keychain). The first is the default; the second stays possible for the original files.

### Attribution (About box and site)

When any CC-BY-4.0 model is installed, About › Acknowledgements lists: NVIDIA Parakeet TDT 0.6B v3 (CC-BY-4.0); pyannote speaker-diarization-community-1 with WeSpeaker and BUT Speech@FIT PLDA (CC-BY-4.0), as Core ML conversions by Fluid Inference; and the citations each card asks for. MIT and Apache notices (Whisper, KB-Whisper, DeepFilterNet, Silero VAD, FluidAudio) go in the same list.

## Planned, not yet added

| Component | Licence (to verify) | Plan |
|---|---|---|
| Sparkle | MIT | Updates |
