# Immersive audio (phase 4): sketch and what is built

Phase 4 of `docs/PLAN.md`: multichannel up to 7.1.4, ADM BWF, Ambisonics, APAC/ASAF export, binaural monitoring with head tracking, Overdub with consent flow. Sketched 2026-11-17 on the coordinator's word to build block D on my own judgment; numbers from standards are written in only after they have been read at the source (the sources are named where they are used).

## Order

1. **Channel-based documents beyond stereo** (D1): a document has a layout (mono, stereo, 5.1, 7.1, 7.1.4). Every source is mapped into it by a matrix made from the two layouts (a mono voice to the centre, a stereo pair to L and R, a wider source folded down by the standard's coefficients). Playback on a device with fewer channels is folded down at the output. The loudness meter weights the channels by their place. WAV/RF64 written with the channel mask; FLAC up to 8 channels; MP3 and Opus stay mono/stereo. A step changes the layout as a value of the project, so it is undone like any other.
2. **A surround panner** (D2): a track's position (azimuth, elevation, spread) in a layout wider than stereo, written with the published amplitude-panning method it uses; automatable like pan.
3. **ADM BWF** (D3): a bed (channel-based) written as BW64 with `chna` and `axml` by the common definitions, and read back.
4. **Ambisonics** (D4): AmbiX (ACN/SN3D) documents, a source encoded into them by direction, and decoded to a layout or to headphones.
5. **Binaural monitoring with head tracking** (D5): through the system's own renderer where it can take the document's channels; otherwise not built.
6. **APAC export** (D6): where AudioToolbox can write it.
7. **Overdub with consent flow**: waits for Anders's decision on the voice provider's terms.

## Decisions (2026-11-17)

- **The layout is the document's; a source keeps its own.** Nothing is converted on import. A 5.1 file in a stereo document is heard folded down; set the document to 5.1 and it is heard as it is. No edit touches a source file.
- **Old documents render as they did.** A document without a layout is mono or stereo by its channel count, and mono and stereo sources go into it the old way (a mono source in both channels). The matrix is used only where a layout wider than stereo is involved, so the null tests stay as they are.
- **The order of the channels is the WAV order** (by the channel mask's bits). 5.1's surrounds are written as the side pair (mask 0x60F); a 5.1 file with the back pair (0x3F) is read as the same layout.
- **Pan is stereo's.** In a wider document a track's stereo pan is not offered until the surround panner (D2) is there; the step says so.
- **Monitoring is not the mix.** The fold-down at the output is for listening only; an export is always in the document's layout unless a step says otherwise.

## Built

### D1, first part (2026-11-17, not yet used by the documents)

- `ChannelLayout` and `Speaker` (`JammerCore/ChannelLayout.swift`): the five layouts, their loudspeakers in WAV order, the mask; a file's layout from its mask or count.
- The engine: a matrix per source in a plan (`jm_plan_set_source_matrix`); without one a plan renders as before. Tested: a mono voice into 5.1 lands in the centre only and a stereo pair in L and R, sample for sample; a fold-down sums by its gains.
- The output: a slot has a gain, and several slots can add into one device channel (`jm_engine_set_output`'s `gains`). Tested through the device callback: L, R and C on a stereo device give L + 0.707·C and R + 0.707·C within 10⁻⁶.

### D1, second part (2026-11-17)

- **A file in a known layout opens as a document in that layout** (a 5.1 WAV is a 5.1 document); a file in another layout is heard as stereo, as before. A document wider than stereo is saved as format 4, which an older Jämmer refuses rather than playing a mono voice in every channel; a project with a channel count that is no layout (4, say) is refused when read.
- **Sources go into the document by the matrix**: a mono source to the centre, a stereo pair to L and R, a source in the document's own layout channel for channel. Tested: a 5.1 file in its 5.1 document nulls; a voice and a stereo pair in a 5.1 document land in C and in L/R sample for sample, with nothing in the LFE or the surrounds; the same sources in a stereo document are as they were.
- **Pan** in a wider document is refused with words that say so ("this one is 5.1, and its surround panner isn't built yet"), in both languages, and so is pan automation.
- **The export** writes the layout's channel mask (5.1 as the side pair, 7.1.4 as 0x2D63F); the status bar names the layout.

### D1, third part (2026-11-17): fold-downs, the meter, listening, the layout menu

- **Fold-downs** (`ChannelLayout.gains`), a layout at a time:
  - 5.1 to stereo and to mono: ITU-R BS.775-4, Annex 4, Table 2: L′ = L + 0.7071 C + 0.7071 Ls (R′ likewise); mono C′ = 0.7071 L + 0.7071 R + C + 0.5 Ls + 0.5 Rs. The LFE has no column there and is left out.
  - 7.1 to 5.1: the sides and the rears into 5.1's surrounds at 0.707 each: AOMedia IAMF 2.0.0, Annex A2.2, Ls5 = α·Lss7 + β·Lrs7, mode 2 (α = β = 0.707).
  - 7.1.4 to 7.1: each height into the loudspeaker under it at 0.7071 (top fronts into L and R, top rears into the rears). **Jämmer's own choice:** no standard read gives a fold of the heights into the ear layer (BS.775 has no heights; IAMF's quoted steps fold heights into heights; AOM's renderer's static matrices stop at 3.1.2). It uses the same −3 dB as the others.
  - No normalisation, as in BS.775: a fold-down can be louder than its parts and can clip; the meters show it.
  - Tested: each coefficient; 7.1.4 into stereo through every step (a top rear reaches the left at 0.7071³); a 5.1 file in a stereo document is heard as L + 0.7071 C + 0.7071 Ls within 10⁻⁶.
- **Listening:** a document wider than the device is folded down to the device's stereo pair by the same coefficients; a device with enough channels gets one each. Tested on the routing (5.1 onto a stereo pair, onto a four-channel device's chosen pair, 7.1.4 onto two channels).
- **The loudness meter weights by position** (ITU-R BS.1770-5, Annex 3, Tables 4 and 5): 1.41 for 5.1's surrounds (±110°) and 7.1's sides (±90°), 1.00 for the fronts, 7.1's rears (±135°) and every height, the LFE not measured. Until today 7.1's rears had 1.41 and 7.1.4's LFE was counted. Tested: EBU Tech 3341 case 6 (a 5.0 sine, −28/−24/−30 dBFS) made here from its definition reads −23.0 ±0.1; a tone in each loudspeaker of 5.1, 7.1 and 7.1.4 reads as its weight says (sides +1.49 dB, LFE nothing); a 5.1 programme agrees with ffmpeg's ebur128 within 0.15 LU.
  - **Not yet calibrated for 7.1 and 7.1.4 against a measured reference.** ffmpeg's ebur128 gives 7.1's rears 1.41 (its source, read today), so it is no reference there. The reference is ITU-R BS.2217's 8- and 12-channel compliance files (`1770Conf-8channels-24LKFS.wav`, `1770Conf-12channels-24LKFS.wav`, free to download from the ITU, "All Rights Reserved", so not to be committed). Fetching them, even once for a local run, is for Anders to say.
  - EBU's own test files can't be committed either ("You may not use any EBU Test Sequences for business, commercial or for-profit activities"); the cases are tones defined in Tech 3341's table, so they are made in the tests.
- **Audio › Layout** (Mono, Stereo, 5.1, 7.1, 7.1.4, the document's ticked) and the step `set_layout`: a value of the document, undone like any other; nothing converted. `layout` in `GET …/documents/{id}`.

## Not built

- Per-channel meters in the window, and a line that says the document is heard folded down.
- A seen GUI pass of a 5.1 document (the menu, the status bar, listening).
- Everything from D2 on.
