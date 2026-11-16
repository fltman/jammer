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
| `format` | "Each file must be a 192 kbps or higher CBR, 44.1kHz MP3" | At 44.1 kHz the document is encoded to a 192 kbps constant-bit-rate MP3 and the levels are measured on that file as it decodes. At another rate this fails and says that sample-rate conversion is missing; the levels are then measured on the mix (`measuredOn`). |
| `channels` | "All files must be in the same channel format (all mono or all stereo)" | Shown; `pass` null (it is about the files together). |
| `length` | "Each file must be no longer than 120 minutes" | The document's length. |
| `roomTone` | "Room tone spacing must not exceed 5 seconds" (1–5 s recommended at each end) | The stretch at each end under −45 dBFS. |
| `narration` | "Your submitted audiobook must be narrated by a human unless otherwise authorized" | Not measured; `pass` null. |

Not found on ACX's page, and so not claimed: how RMS and the noise floor are to be measured, and a file size limit.

**Against an outside reference** (ffmpeg `astats`): a 48 kHz test file reads RMS −22.6 dB and peak −7.4 dB here, −22.55 and −7.41 in ffmpeg. The same speech at 44.1 kHz reads −19.55 dB RMS as a WAV in ffmpeg and −19.8 as the 192 kbps MP3 decoded here: the encoder takes about a quarter of a dB, which is why the check is made on the encoded file.

**In the app** (2026-11-16): a 44.1 kHz mono chapter measured on the MP3 with every measured line met; a 48 kHz document with `format` failing and the rest measured on the mix; the sheet read through the accessibility API; the document not marked as edited by the check.

## Not built yet

- Sample-rate conversion on export (r8brain-free-src, MIT; to be fetched only when Anders has said yes) and dither when the bit depth goes down.
- The limiter as a live insert comes with the mixer, after its realtime measurements. With the mixer its place is on the master bus, after everything; today it comes before the tracks' plugins and says so (`beforePlugins`).
