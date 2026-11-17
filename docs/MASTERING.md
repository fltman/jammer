# Mastering: limiter, sample rate, dither, delivery checks

Phase 3, part 1. What is built is said here with the numbers it was measured to; what isn't is listed last.

## Limit (true-peak limiter), built 2026-11-16

`limit` in the operation registry, **Audio › Limit Peaks…** in the app. Offline: the result is bounced into new files, like `echo` and `duck`.

**How it works** (`JammerCore/Limiter.swift`, `LimiterApply.swift`). For every frame the level is the highest of the samples and the oversampled points around it, over all channels; the oversampler is the meter's own (`TruePeak`: 4× at 44.1/48 kHz, 2× at 88.2/96, none from 176.4), so the limiter sees the peaks the meter will. Required gain = ceiling / level, at most 1 → the lowest required gain in the lookahead ahead → release (falls at once, rises with the time constant) → mean over the lookahead. Every value averaged for a frame is at most what that frame needs, so the applied gain never exceeds it. One gain for all channels and all limited tracks: it is found on the tracks' mix (their levels and mutes, not their plugins) and put on each track, so their sum is the limited mix.

**No delay.** The lookahead is hidden inside the processor; frame k out is frame k in. `latencySamples` in the answer is 0, and a test checks that an impulse and the zero crossings of a tone stay where they were.

**Untouched where nothing is needed.** Where the gain is 1 the samples are copied, never multiplied or filtered: the first and last seconds of the test document null against the original. Outside the range nothing is touched.

**The promise is kept by measuring.** A moving gain shifts inter-sample peaks a little, so the limiter aims 0.05 dB under the ceiling, the result is read as the meter reads it, and if it is over, the pass is run again 0.1, 0.2, 0.4 and 0.8 dB under; after that it fails in words rather than hand back audio over the ceiling. Hours of audio are done in blocks; only gains and blocks are held in memory.

**Measured** (48 kHz, release 100 ms, lookahead 5 ms; "after" read by `LoudnessMeter`, the meter validated against EBU Tech 3341/3342 and ffmpeg):

| Signal | Ceiling | True peak before | After | Aimed under by |
|---|---|---|---|---|
| Sine at fs/4, 45° phase, amplitude 1 (no sample over 0.7071) | −1 | −0.17 | −1.05 | 0.05 |
| Tone bursts at +6 dB | −0.1 / −1 / −3 | +6.64 | −0.15 / −1.05 / −3.05 | 0.05 |
| Full-scale impulse | −0.1 / −1 / −3 | 0.00 | −0.15 / −1.05 / −3.05 | 0.05 |
| White noise ×2 | −0.1 / −1 / −3 | +11.01 | −0.15 / −1.05 / −3.05 | 0.05 |
| White noise ×2 at 44.1 / 96 / 192 kHz | −1 | +10.85 / +10.04 / +6.02 | −1.05 / −1.05 / −1.05 | 0.05 |
| White noise ×2, release 1 ms, lookahead 0.5 ms | −0.1 | +11.01 | −0.12 | 0.10 (second try) |

**What "true peak" means here, exactly.** The fs/4 sine has a real peak of 0 dBTP and the meter reads −0.17: its 4× points fall 11.25° beside the crest at that frequency (20·log10(cos 11.25°) = −0.169 dB). That is inside the 0.3 dB the meter is held to, and it is what a four-times oversampling meter of the BS.1770 kind does. The limiter uses the same points, so after limiting to −1 that signal's real peak is −0.88 dBTP. The ceiling is therefore kept *as a BS.1770 meter reads it*, not analytically; the manual says so. Reading finer (8× or more) would change the meter that the loudness tests are calibrated with, so it is a decision of its own, not made here.

**Proved by planting a fault**: with detection on sample peaks only, the fs/4 test fails ("couldn't keep the true peak under −1.0 dBTP (it came to −0.17)") and six others with it; with the tracks written unlimited, the document tests fail.

**Refused in words**: a peak already under the ceiling (422 `nothing_to_do`), nothing in the range, a track that isn't there (`not_found`), and values outside ceiling −20…0 dBTP, release 1…2000 ms, lookahead 0.5…20 ms, including NaN and infinity, before any audio is read.

**Known limits.** At the edges of a range the gain can step (the audio outside is not touched, so the gain can't ramp there); for the whole document there is no edge. A track's plugins come after the limiter and are not in its figures (`beforePlugins` in the answer). The last ~16 frames of a file are read by the meter as sample peak only; the limiter does see them.

**In the app** (2026-11-16), on an 8 s test mix with a true peak of +1.58 dBTP: the sheet read through the accessibility API (ceiling field named, no unnamed controls); Limit with −1 gave −1.05 dBTP, "at most 2.6 dB taken off, over 3.6 s" in the status bar, one new clip on the track, and Edit › Undo Limit brought +1.58 back; a ceiling typed as "-3,5" gave −3.55; a ceiling of 5 was refused with "The ceiling has to be a number from −20 to 0 dBTP. Nothing was changed".

## A loudness preset with the limiter, built 2026-11-16

`loudness_preset` with `"limit": true`, **Audio › Loudness Preset With Limiter** in the app. Default is unchanged: one gain, stopping where the true peak would pass the preset's ceiling. With `limit`, and only when the peaks are in the way, the gain goes all the way to the target and the limiter holds the peaks at the ceiling; limiting takes a little loudness back, so the gain is corrected and the pass repeated, at most three times, until the result is within 0.1 LU (`Project.matching`). The earlier tries' files are removed.

The answer says what it cost: `limited`, `reductionMaxDB`, `limitedSeconds`, and the loudness range before and after (`rangeBeforeLU`, `rangeAfterLU`), so that nobody squashes a recording to a target without it showing.

Tested on 20 s that are quiet on average with a 5 ms burst at −2 dBFS every second, target −14 LUFS: without the limiter the result is far short and `limitedByPeak` is 1; with it, −14.0 ± 0.1 LUFS as measured again afterwards, true peak at or under −1.0, more than 3 dB taken off the bursts. Where the peaks leave room (the same material to −23 LUFS) the limiter isn't used even when allowed.

## Measured against ACX's requirements, built 2026-11-16

`GET …/analysis/acx`, **Audio › Check Against ACX Requirements…**. Measures, changes nothing, and never says "approved".

The requirements are quoted from ACX's article "ACX Audio Submission Requirements", https://help.acx.com/s/article/acx-audio-submission-requirements, article date 15 April 2026, read on 16 November 2026 (`JammerCore/ACX.swift` has the figures, the wording and the dates; they change only with a new reading):

| Name | ACX's words | Jämmer's measure |
|---|---|---|
| `rms` | "Each file needs to fall between the specific volume range of -23dB and -18dB RMS" | Plain RMS of all samples, channels together, unweighted (`LoudnessResult.rms`; a full-scale sine reads −3.01). ACX gives no method. |
| `peak` | "Each file must have peak values no higher than -3dB" | Sample peak and true peak both at or under −3; the note says which decided. ACX says "peak" and "dB". |
| `noiseFloor` | "Each file must have a noise floor no higher than -60dB RMS" | RMS of the pauses (`Restoration.noiseFloor`). ACX gives no method. `pass` is null when there is no pause to measure in. |
| `format` | "Each file must be a 192 kbps or higher CBR, 44.1kHz MP3" | The document is encoded to a 192 kbps constant-bit-rate MP3 at 44.1 kHz (converted when it is at another rate) and the levels are measured on that file as it decodes. If no MP3 can be made this fails and says why; the levels are then measured on the mix (`measuredOn`). |
| `channels` | "All files must be in the same channel format (all mono or all stereo)" | Shown; `pass` null (it is about the files together). |
| `length` | "Each file must be no longer than 120 minutes" | The document's length. |
| `roomTone` | "Room tone spacing must not exceed 5 seconds" (1–5 s recommended at each end) | The stretch at each end under −45 dBFS. |
| `narration` | "Your submitted audiobook must be narrated by a human unless otherwise authorized" | Not measured; `pass` null. |

Not found on ACX's page, and so not claimed: how RMS and the noise floor are to be measured, and a file size limit.

**Against an outside reference** (ffmpeg `astats`): a 48 kHz test file reads RMS −22.6 dB and peak −7.4 dB here, −22.55 and −7.41 in ffmpeg. The same speech at 44.1 kHz reads −19.55 dB RMS as a WAV in ffmpeg and −19.8 as the 192 kbps MP3 decoded here: the encoder takes about a quarter of a dB, which is why the check is made on the encoded file.

**In the app** (2026-11-16): a 44.1 kHz mono chapter measured on the MP3 with every measured line met; a 48 kHz document, first (before sample-rate conversion existed) with `format` failing and the rest measured on the mix, then, with conversion, measured on the converted MP3 with `format` met; the sheet read through the accessibility API; the document not marked as edited by the check.

## Dither, measured 2026-11-16

TPDF dither on a 16- or 24-bit WAV has been in the export since phase 0 without a measurement of its own. It has one now (`DitherTests`), against what the arithmetic says: one step of 16 bits is 1/32768; rounding alone leaves an error of LSB/√12 (−101.09 dBFS), and triangular dither of ±1 LSB brings the total to LSB/2 (−96.33 dBFS), with the error no longer depending on the signal.

| What | Expected | Measured |
|---|---|---|
| Error of a −12 dBFS tone written to 16 bits, no dither | −101.09 dBFS | within 0.15 dB |
| The same with dither | −96.33 dBFS | within 0.15 dB, mean under 0.02 LSB |
| A 1 kHz tone at −100 dBFS (a third of a step), no dither | lost | every sample 0 |
| The same with dither | still there | its amplitude found within 10 % over 20 s |
| 24 bits with dither | −144.49 dBFS for an ideal source | −144.9: a 32-bit float source already sits on a 24-bit step for about one sample in ten |

**Once, last, and not again.** Dither is added only to a sample that rounding would change. Audio that is already at the target depth (an untouched 16-bit file exported at 16 bits) comes out bit for bit and gets none, and digital silence stays silent. The answer says what was done: the export's `X-Jammer-Dither` header is `tpdf`, `none`, or `not_needed` (asked for, nothing to dither). Default in the API: none. In the export sheet it is ticked when 16-bit WAV is chosen.

**Not built:** a noise-shaped dither. The published curves (Lipshitz, Vanderkooy and Wannamaker) are behind a paywall and have not been read, and no curve is taken from memory or from a product; until one has been read at its source there is TPDF only.

## Sample rate conversion, built 2026-11-16

`"sampleRate"` on `export`, **Sample rate** in the export sheet. The mix is rendered once at the document's rate, converted into a temporary 32-bit float file, and the export (any format, the loudness correction for lossy formats included) then runs on that as if it were the document; markers are moved to the new rate, chapters are in seconds and stay. Opus is always 48 kHz and refuses another rate. The document is never changed. Dither, when asked for, is added after the conversion, once.

The converter is r8brain-free-src 7.7 by Aleksey Vaneev of Voxengo (MIT), one converter per channel at its 24-bit setting, compiled from source with its own Ooura FFT (`JammerResample`). Fetching it was approved by Anders on 2026-11-16; see `docs/LICENSES.md`.

**Measured before it went in** (`ResamplerTests`, the middle of two seconds, away from the ends):

| What | Result |
|---|---|
| A 997 Hz tone, 48 → 44.1, 44.1 → 48, 96 → 44.1 kHz | level +0.0000 dB; everything else −150.9, −150.7, −152.1 dB under the tone |
| 48 → 44.1 kHz at 20 Hz, 10, 18, 20 and 21 kHz | −0.0000 dB at each |
| 48 → 44.1 kHz, tones at 22.5, 23 and 23.9 kHz (over the new half rate; they would fold back if they got through) | −156.2, −154.9, −153.8 dB |
| A click at 1.000 s, 48 → 44.1 kHz; at 0.5 s, 44.1 → 96 kHz | at frame 44 100; at frame 48 000 |
| Length | exactly round(frames × to / from), in every case |
| Fed in blocks of 1, 7, 4 095, 4 097, 20 000 frames | the same output bit for bit as in one piece |
| 48 → 44.1 → 48 kHz of tones under 18 kHz | nulls against the original to under −100 dB |
| Against Apple's converter (afconvert, bats, quality 127), band-limited signal, 48 → 44.1 kHz | same length; difference −146.2 dB |
| Against ffmpeg's (swresample, filter size 512) | same length; difference −123.7 dB |

**In the app** (2026-11-16), a 48 kHz stereo document of 25.08 s: WAV 24-bit at 44.1 kHz, FLAC at 96 kHz, MP3 192 kbps and AAC at 44.1 kHz, and WAV 16-bit at 16 kHz with dither all came out at the rate asked, the right length, with `X-Jammer-Sample-Rate` saying so (and `X-Jammer-Dither: tpdf` on the last); 44 000 Hz was refused with the list of rates, and Opus at 44.1 kHz with "opus is always written at 48000 Hz". The 44.1 kHz WAV against ffmpeg's own conversion of the 48 kHz export of the same speech: same number of frames, difference −79 dB. (That is real speech with content up to the band edge, where the two converters' filters differ, compared through 24-bit files; the band-limited comparison above is the measure of agreement.) The ACX check on the 48 kHz document was then measured on the converted MP3, with `format` met.

**Also through this converter since the same day:** the batch export (`export.sampleRate`, the same field and the same refusals) and the import of a file at another rate than the document's (the same file through the system's converter and through this one: same length, difference −145.4 dB; `docs/CHANGES.md` says what changed and what is still on the system's converter). The converter registers at `SampleRateConversion` in the core, so there is one place a rate changes.

## Dialogue-gated loudness (debug builds, 2026-11-17: not yet set beside a reference meter)

Film and television are set by how loud the talking is. Jämmer measures it itself, and the measurement is never called anything but Jämmer's own.

- **What is measured:** BS.1770 K-weighting and channel weights, in the meter's 100 ms blocks; a block is speech when at least half of it lies where the document says there is speech; the dialogue loudness is −0.691 + 10·log10 of the mean energy of the speech blocks above −70 LKFS. No relative gate. That is what ATSC A/85:2026-07 describes (§5.2.2: "BS.1770 (without the relative-level gate) along with a dialogue-gating algorithm and measured over the entire duration"), with the −70 LKFS absolute gate kept so that silence marked as speech doesn't pull the number down.
- **Where the speech is:** what the document already knows from this Mac's own speech tools. Who speaks when (Find Speakers) on the tracks that are heard; without that, a transcript's words, joined when less than 0.3 s apart. Without either the answer says `speechFrom: none` and gives no dialogue number. No new model, nothing sent anywhere.
- **Not Dolby's.** Most specifications name Dolby's Dialogue Intelligence. Its reference code is offered under an agreement (read 2026-11-17, https://professional.dolby.com/support/dolbys-speech-gating-reference-code-agreement/): object code only, non-sublicensable, professional products, a notice and patent marking. That can't go in an MIT source tree, so nothing of it is fetched, read or used. A meter with another speech detector puts the speech in other places and gives another number; how much is to be measured (below) and written in the manual as it is.
- **The arithmetic is tested** against EBU Tech 3341's own case (a 1 kHz stereo sine at −23 dBFS is −23.0): 10 s of it marked as speech among 20 s at −10 dBFS measures −23.0 ± 0.1 with a third of the time speech.
- **API:** `GET …/analysis/dialogue` (`dialogueLKFS`, `speechShare`, `speechSeconds`, `speechFrom`, `program`), with `profile` for a delivery target. A build without it answers `not_available`.

**Profiles** (each with where it was read and when; no verdict is given until the reference measurements are in):

| Profile | Dialogue target | True peak | Goes by the whole programme when | Read |
|---|---|---|---|---|
| `atsc_a85_dialogue` | −24 LKFS, about ±2 | below −2 dBTP | speech under 8 % (the standard's example for automated processes), then −24 ±2 | ATSC A/85:2026-07, at the source, 2026-11-17 |
| `netflix` | −27 LKFS ±2 | −2 dBTP | dialogue under 15 %, then −24 ±2 | **Not at the source:** Netflix's page is an application that could not be read; the numbers are MeterPlugs' account (deliveryqc.com/netflix-delivery-specs), 2026-11-17 |

Not made a profile: Apple's Atmos film range (−31 to −10 LKFS dialogue, on a 5.1 render: nothing Jämmer makes before phase 4); Amazon, Disney+, Max (no public numbers found).

**Jämmer's own numbers on the eight files** (in the app, 2026-11-17; the speech found by the Mac's own transcription, then by Find Speakers). "Made as" is how loud the speech alone was made and the share of the file it was placed over; a pause between sentences is inside that share, and the detectors leave some of them out.

| File | Speech made as | Whole file (ffmpeg) | By the transcript's words | By who speaks when |
|---|---|---|---|---|
| d1 speech alone | −27, 93 % | −27.1 | −26.74, 86 % | −26.87, 92 % |
| d2 speech over quiet music | −27, 92 % | −26.9 | −26.70, 84 % | −26.75, 90 % |
| d3 half speech, loud music between | −27, 47 % | −19.3 | −26.76, 44 % | −26.78, 44 % |
| d4 little speech, loud effects | −27, 11 % | −20.4 | −26.58, 10 % | −26.85, 11 % |
| d5 quiet speech, loud music between | −38, 47 % | −20.2 | −37.74, 44 % | −37.77, 44 % |
| d6 speech under music | −30, 92 % | −21.5 | −21.48, 84 % | −21.36, 89 % |
| d7 music only | none | −24.0 | no speech found | no speech found (Find Speakers ends as failed on a file without speech) |
| d8 two voices over room tone | −27, 86 % | −27.1 | −26.98, 79 % | −27.02, 84 % |

Where the speech is the loudest thing while it is spoken (all but d6) the number is within 0.5 LU of what the speech was made as, whatever is between the sentences. In d6 the music is 8 dB over the speech all the way, and the number is the music's: dialogue gating measures everything that sounds while someone speaks, not the voice alone. What a reference meter says of the same files is the part that is missing.

**Calibration, waiting for Anders.** `scripts/make-dialogue-test-files.py` makes eight files (system voices reading an invented text, music and effects from tones and noise; nothing fetched) in `$JAMMER_TEST_MEDIA/dialogue`, with `manifest.json` saying where the speech was put: speech alone; over quiet music; half speech with loud music between; little speech with loud effects; quiet speech; speech under music; music only; two voices over room tone. He measures them in a reference meter (TBProAudio dpMeter5 in DIAL mode, or DeliveryQC.com, both of which say they use Dolby's code); the differences go in the manual with the share of speech beside them. Until then: debug builds only, and nothing is called met or failed.

## Not built yet

- The limiter as a live insert comes with the mixer, after its realtime measurements. With the mixer its place is on the master bus, after everything; today it comes before the tracks' plugins and says so (`beforePlugins`).
