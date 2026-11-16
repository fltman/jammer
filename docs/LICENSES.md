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

| r8brain-free-src (sample rate conversion, C++, header-only) | 7.7 (5792291a) | MIT, "Copyright (c) 2013-2026 Aleksey Vaneev" ([LICENSE](https://github.com/avaneev/r8brain-free-src/blob/master/LICENSE), read 2026-11-16). The free library, not the commercial r8brain PRO | Fetched by `scripts/fetch-r8brain.sh` (pinned commit; the script stops if the LICENSE no longer starts "MIT License" or the version isn't 7.7) and compiled into the app from source in one file, `JammerResampleC/resample.cpp`, at its 24-bit setting. Fetching was approved by Anders on 2026-11-16. Intel IPP and PFFFT are not enabled. The author asks for this credit and it is given in the app's credits and in the manual: "Sample rate converter designed by Aleksey Vaneev of Voxengo" | Notice and credit in `App/Credits.html`; measured in `ResamplerTests` (docs/MASTERING.md) |
| ↳ Ooura FFT (`fft/fft4g.h` inside r8brain, its default FFT) | as in r8brain 7.7 | "Copyright Takuya OOURA, 1996-2001. You may use, copy, modify and distribute this code for any purpose (include commercial use) and without fee. Please refer to this package when you modify this code." (the author's page, read 2026-11-16) | Compiled in with r8brain | Named in `App/Credits.html` |
| CLAP (plugin interface headers, C) | 1.2.9 (cd94482b) | MIT, "Copyright (c) 2021 Alexandre BIQUE" ([LICENSE](https://github.com/free-audio/clap/blob/main/LICENSE), read 2026-11-15) | Headers fetched by `scripts/fetch-plugin-sdks.sh` (pinned commit checked) and compiled into the two helper programs in the app bundle (`jammer-plugin-probe`, `jammer-plugin-host`), not into the app itself. Credited in the app | 2026-11-15 |
| MusicUnderstanding (tempo and beats) | macOS 27 system framework | Part of macOS; nothing is bundled or fetched, and it works with the network blocked | Used through `JammerAudio/MusicRhythm.swift`; its answers are judged by Jämmer before they are shown (`docs/TEMPO.md`) | 2026-11-16 |
| VST 3 SDK: pluginterfaces (4f547e8e), base (fcf9da0b), public.sdk hosting helpers (586dc5e6) | v3.8.1_build_84 (3cdf9ca5) | MIT since SDK 3.8, "Copyright (c) 2026, Steinberg Media Technologies GmbH" (LICENSE.txt in each of the three, read 2026-11-15; Steinberg's portal: "No need to sign any documents", GPLv3 and the proprietary licence "no longer available"). VSTGUI (BSD-style) and the examples are **not** fetched or used | Fetched by `scripts/fetch-plugin-sdks.sh` (pinned commit checked). Compiled from it: `pluginterfaces` (headers, `funknown.cpp`, `coreiids.cpp`) into `jammer-plugin-probe` and `jammer-plugin-host`, and `public.sdk/source/vst/vstinitiids.cpp` (the interface ids) into `jammer-plugin-host`. Nothing of `base` or the hosting helpers is compiled; the host's own objects are in `vst3_host.cpp`. The app doesn't offer VST 3 to users yet. Credited in the app with the trademark line | 2026-11-15 |

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

## Phase 3: read before use (2026-11-16), nothing of this is in the app yet

Read at the source by a research pass on 2026-11-16; each entry is finished (version, notice text in the bundle) when the code comes in. "Not verified" is said where it applies.

| Item | Licence, as read | Verdict | To record or decide when used |
|---|---|---|---|
| ARA 2: ARA_API and ARA_Library (Celemony) | Apache-2.0. "ARA Audio Random Access" is Celemony's mark; no logo rules found | OK with conditions | Apache text and Celemony's notice; a tagged ARA release; plain words ("supports ARA 2 plug-ins"), no logo; JUCE_ARA not used; ARA through VST 3 needs the VST 3 SDK reviewed first |
| AAF SDK (AMWA) | AAF SDK Public Source License 2.0: custom, with a duty to deliver modifications within 60 days, an indemnity, naming rules, and no licence to Microsoft's structured-storage rights | Not used | The plan stays: an own reader |
| Own AAF reader | The container (MS-CFB) is under Microsoft's Open Specification Promise. AMWA's Implementer's Agreement 2.0 (signed on paper, no fee) gives a reciprocal patent licence; it isn't a condition for implementing | OK with conditions; **a decision for Anders: sign the Implementer's Agreement or not** | Written from the specifications with no SDK or LibAAF code; "imports AAF", never "AAF compliant", no logo; AMWA's trademark line |
| LibAAF (agfline) | GPL-2.0-or-later | **Not used**, and no code read from it | |
| OpenTimelineIO C++ core (ASWF) | Apache-2.0 with a NOTICE (Pixar); Imath BSD-3-Clause, rapidjson MIT (its `bin/jsonchecker` excluded), minizip-ng zlib. The core reads `.otio`, `.otioz`, `.otiod` only | OK with conditions, or an own reader of the JSON | Apache text, the NOTICE, the three dependency notices |
| DAWproject (Bitwig) | MIT, covering the schema and the Java reference library | OK; an own implementation of the XML-in-ZIP format | MIT notice if the XSD is bundled |
| DDP 2.0 (DCA) | Proprietary specification, given only after a signed agreement (free, no royalty); "DDP" is DCA's registered mark; the agreement requires a notice and DCA's logo and says nothing about source code | **A decision for Anders before anything is built**: sign and ask DCA in writing about MIT source, or leave DDP out | The agreement's notice if signed |
| CMX3600 EDL | No licence found for the format (SMPTE 258M is the paid specification text) | OK, own parser and writer | Descriptive use of the name |
| Dither | TPDF and noise shaping from the published AES papers (Lipshitz, Vanderkooy, Wannamaker 1991; Wannamaker 1992): no licence found; the papers were not read (paywalled). UV22, POW-r and MBIT+ are others' products | OK | Cite the paper for any curve used; none of the product names, none of their coefficients |
| True peak (ITU-R BS.1770-5) | A free-to-read Recommendation under ITU's patent policy; ITU's patent database was not searched | OK | No ITU text or emblem reproduced |
