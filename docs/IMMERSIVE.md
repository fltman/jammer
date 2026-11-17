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

- **Seen in the app** (2026-11-17, a 5.1 WAV with a tone in each channel): it opens as 5.1 and the status bar says "5.1"; Audio › Layout lists Mono, Stereo, 5.1, 7.1, 7.1.4 with 5.1 ticked; choosing Stereo and ⌘Z brings it back; two seconds of playback on the Mac's stereo output, folded down, with no underrun; the mixer's description wraps to a narrow window.

### D2, first part (2026-11-17): the surround panner

- **A track's place** (`SurroundPosition`: azimuth, elevation, width) in a layout wider than stereo, by the angles of ITU-R BS.2051-3 (azimuth positive to the left; read at the source: "positive values rotate to the left"). The loudspeakers' nominal directions from its tables: fronts ±30°, 5.1's surrounds ±110°, 7.1's sides ±90° and rears ±135°, 7.1.4's heights at ±45° and ±135°, 30° up.
- **The panner** (`Panner`): vector base amplitude panning (V. Pulkki, J. Audio Eng. Soc. 45(6), 1997) between the two loudspeakers of a layer that enclose the direction, scaled to constant power; where there are heights, the ear layer and the height layer crossfaded by elevation at constant power from 0° to 30°; above 30° the sound stays in the height layer (there is no loudspeaker overhead). The LFE is never fed. A mono source is placed at the azimuth; a stereo source's two sides at azimuth ± width/2. On a loudspeaker's own direction only that loudspeaker sounds, so the default place (0°, 60° wide) gives exactly the old routing: a voice in C, a pair in L and R. A source of more than two channels on a placed track stays on its own loudspeakers.
- **Steps:** `set_track` takes `azimuth`, `elevation`, `width`, and `placed: false` to take a track out of the panner; refused in mono and stereo ("Use pan"), and pan is refused in a wider document ("Place a track with azimuth instead"), in both languages. `position` on each track in `GET …/mixer`.
- **The mixer:** a track's strip in a wider document has an azimuth slider (left to the left, either end behind) and a menu with its place in words ("Left 110°", "Own loudspeakers"), the height in 7.1.4 (0°, 15°, 30°), and Back on Own Loudspeakers.
- **Tested:** the gains on each loudspeaker's direction, halfway between two, behind; constant power and no LFE at every 7.5° in 5.1, 7.1 and 7.1.4; heights at 30° and above, and halfway at 15°; the default place equals the old routing; a voice placed at 110° plays in Ls sample for sample and nowhere else; saved and read back; out of range refused. **Seen:** the mixer with a voice placed at 110° ("Left 110°", the slider to the left), the layout menu's words.

### D5, first part (2026-11-17): binaural listening, without head tracking

- **Audio › Listen on Headphones (Binaural)** (a setting of the app, ticked when on; for documents wider than stereo): the engine feeds Apple's spatial mixer (`AUSpatialMixer`) with the document's channels as a bed (`kSpatialMixerSourceMode_AmbienceBed`, each channel from its loudspeaker's direction by the bus's channel layout: 5.1 as `MPEG_5_1_A`, 7.1 as `WAVE_7_1`, 7.1.4 as `CICP_19`, the tags whose order is the WAV order), rendered for headphones (`kSpatializationAlgorithm_UseOutputType`, `kSpatialMixerOutputType_Headphones`), and the mixer feeds the default output. Nothing of it runs in Jämmer's code on the audio thread: the engine's render callback is the same one the output unit uses. Listening only: exports and meters are the document's channels.
- **Tested** offline (the mixer rendered from a test, no device): a tone in 5.1's left surround is more than 3 dB louder at the left ear, the right surround at the right, the centre within 1 dB at both, 7.1.4's left top front at the left ear. **In the app:** playback through it with no underrun, the menu's tick, back to loudspeakers. **Not heard:** the test copy's output is silent; how it sounds is for Anders with headphones.
- **Head tracking is not built.** It needs the `com.apple.developer.coremotion.head-pose` entitlement (macOS 15) and `NSMotionUsageDescription`; an entitlement goes with the app's signing, which is Anders's.

### A fault found and mended on the way (2026-11-17)

The document's audio output and its plugin host were made once, for the channel count the document had when it was opened. After Audio › Layout changed the count, the engine would have been handed a plan of another width than its ring. Now both are made again when the count changes (playback stops, plugins start again). Seen: the layout changed while playing, then stereo and 5.1 played again without underruns.

### D6, first part (2026-11-17): APAC export

- **APAC in MP4** for documents in 5.1, 7.1 and 7.1.4 (`APACWriter`; File › Export's format list offers "APAC (MP4)" for those documents, and no MP3 or Opus; the API's `format: "apac"`). Written through AudioToolbox with the encoder of macOS 26 and later, the channels as a bed in the layout tag whose order is the document's; the settings Apple's APAC paper (June 2025) asks for: content source 38 ("Traditional professional AV offline encoded content such as stereo and multichannel"), the loudness/DRC configuration Movie (the paper: "None should not be utilized"), a sync packet every 75 packets. The encoder chooses the bit rate.
  - AVAssetWriter was tried first and refuses every content source but Apple's own (1–10: "content source must be between AVAudioContentSource_AppleCapture_Traditional and AVAudioContentSource_ApplePassthrough"), which would label this as Apple's content; AudioToolbox takes the third-party values, as the paper's own `afconvert -u csrc 36` example does.
  - A loudness delivery target is not measured through APAC (it carries its own loudness metadata, which a decoder applies).
- **Tested:** a 5.1 and a 7.1.4 document written, decoded again by Apple's decoder: the channel count, the format, and every channel's tone loudest in its own channel. **In the app:** a 5.1 document exported through the API; `afinfo` reads "6 ch, 48000 Hz, apac … Channel layout: 5.1 (L R C LFE Ls Rs)"; a stereo document is refused in words. **Not seen:** the export panel's format list (a script couldn't read it).
- **Not built:** Ambisonics and objects in APAC (no Ambisonics documents yet; Jämmer has no objects); ASAF (Apple publishes no authoring interface for it).

### The waveform where the sound is heard (2026-11-17)

In a layout wider than stereo the timeline draws a clip through the same matrix as its sound: a voice in the C row only, a placed voice at its loudspeakers, a wider source folded down into the document's rows (as the envelope of the summed parts). Seen before the change: a voice placed at Ls was drawn in L and R. Tested on the columns; not yet seen in the window.

### D4, first part (2026-11-17): Ambisonics documents

- **AmbiX** (C. Nachbar, F. Zotter, E. Deleflie, A. Sontacchi, "ambiX – A Suggested Ambisonics Format", Ambisonics Symposium 2011, read at the source: ACN order, SN3D, no Condon-Shortley phase), first to third order (4, 9, 16 channels), as layouts in Audio › Layout and `set_layout` (`ambix1`, `ambix2`, `ambix3`).
- **A file is never taken for a sound field:** nothing in a WAV says its 4, 9 or 16 channels are Ambisonics, so it opens as stereo as before, and the document is set to the order by hand; the file then passes through channel for channel (tested, sample for sample).
- **Encoding** (`Ambisonics.encode`): the real spherical harmonics up to third order. Tested on SN3D's defining property: W is 1 and each order's squares sum to 1 in every direction (every 15°), and on the first order's directions. Into a sound field a mono source comes from the front, a placed track from its place (the panner's azimuth and elevation, every elevation), a loudspeaker layout from its loudspeakers' directions (the LFE left out); one order goes into another by the components they share.
- **No decoder:** a sound field in a loudspeaker document is left out (silent there), said in the step's description. Listening to an Ambisonics document always goes through Apple's spatial mixer with Core Audio's `HOA_ACN_SN3D` tag: for headphones when binaural listening is on, otherwise for loudspeakers. Tested offline: a tone encoded at 90° left reaches the left ear more, at 90° right the right ear, at first and third order. In the app: played both ways without underruns (`outputPath` `spatialSpeakers` and `binaural`); not heard.
- **Loudness isn't measured** in an Ambisonics document: ITU-R BS.1770 has no weighting for a sound field, and no reference has been found. `GET …/analysis`, the dialogue analysis, `normalize` to a loudness, `loudness_preset`, `limit` and an export's `targetLUFS` are refused with that reason (`not_available`). The meter internally takes only W, so nothing breaks, and nothing of it is shown.
- **APAC** writes a sound field too, with the HOA tag and content source 39 ("Spatial professional AV offline encoded content"): `afinfo` reads "4 ch, 48000 Hz, apac … Channel layout: High-Order Ambisonics, ACN/SN3D". A WAV export of a field is written with a channel mask of 0 (no loudspeaker positions).

## Not built

- Per-channel meters in the window, and a line that says the document is heard folded down.
- A seen GUI pass of a 5.1 document (the menu, the status bar, listening).
- The panner's place automated over time; buses placed; a spread wider than a pair of loudspeakers for a mono source.
- ADM BWF (D3): writing is simple, but nothing could check the files without the EBU's ADM renderer (`ear-utils`, Python, BSD-3-Clause-Clear) or libadm/libbw64 (Apache-2.0): fetching and installing either is for Anders to say.
- An Ambisonics decoder to loudspeaker layouts (an Ambisonics source in a loudspeaker document is left out); a rotation of the field; loudness for a field.
- Head tracking (an entitlement with the app's signing).
- Overdub with consent (waits for Anders's decision on the voice provider's terms).
