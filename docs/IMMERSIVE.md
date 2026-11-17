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

## Not built

Everything else above.
