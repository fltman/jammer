# Loudness

## Measure

**Audio › Measure Loudness** (⌥⌘L) measures the selection, or the whole project, and shows the result in the status bar:

- **Integrated loudness** in LUFS: the average loudness, with the quiet parts gated out (ITU-R BS.1770-5).
- **Loudness range** in LU: how much the loudness varies (EBU Tech 3342).
- **True peak** in dBTP: the highest peak, including peaks between samples, found by oversampling.

Jämmer also computes the maximum momentary (400 ms) and short-term (3 s) loudness and the sample peak; agents get all of them from the API. The meter is tested against the EBU test signals for R 128 and agrees with ffmpeg's ebur128 within a tenth of a LU.

## Normalize

The **Audio** menu has four ready-made targets. Each applies one gain change to the selection, or to the whole project when nothing is selected:

| Command | Target | Use it for |
|---|---|---|
| Normalize to −16 LUFS (podcast) | −16 LUFS integrated | Apple Podcasts and most podcast platforms |
| Normalize to −23 LUFS (EBU R 128) | −23 LUFS integrated | European broadcast |
| Normalize Peak to −1 dBFS | −1 dBFS sample peak | A plain peak level |
| Normalize True Peak to −1 dBTP | −1 dBTP true peak | Keeping inter-sample peaks below −1 dB |

The status bar shows the gain that was applied. Normalizing to a loudness target doesn't limit peaks: measure afterwards, and if the true peak is above about −1 dBTP, lower the level or use **Limit Peaks**.

## A preset that reaches its target: Loudness Preset With Limiter

**Audio › Loudness Preset** uses one gain, and stops where the true peak would pass the preset's ceiling; quiet speech with a few loud peaks can then end up short of the target, and the status bar says by how much. **Audio › Loudness Preset With Limiter** has the same targets and goes all the way: the limiter holds the peaks at the ceiling, and the status bar says what that took ("the limiter took at most 3.2 dB off the peaks, over 1.4 s"). When the peaks leave room, the two do exactly the same thing and the limiter isn't used.

A limiter that has to take off many dB to reach a loudness target is changing how the recording sounds. A few dB on occasional peaks is normal for speech; if it reports much more, the recording was probably too dynamic for that target, and levelling it first (see [Speakers](16-speakers.md)) gives a better result.

## Limit Peaks

**Audio › Limit Peaks…** holds the true peak at or under a ceiling you give (−1 dBTP unless you type another, from −20 to 0). It works on the selection, or on the whole document when nothing is selected.

- All tracks get the same gain at each moment, so the balance between them stays, and it is their sum that is kept under the ceiling. (Limiting each track by itself would not keep the mix under it.)
- Where nothing needs limiting, the audio is left exactly as it was, sample for sample. Nothing is delayed.
- Each track plays from a new file over the limited stretch; your original files are untouched, and one undo takes it back.
- The status bar says what it did: the true peak afterwards, the most it took off, and for how long it was limiting. If the peak is already under the ceiling, it says so and changes nothing.
- "True peak" is the level between the samples as well as at them, measured the way ITU-R BS.1770 describes (four times oversampling at 48 kHz). A meter of that kind can read a few tenths of a dB under the real peak on the very worst signals, which is one reason delivery targets ask for −1 dBTP and not 0.
- A track's plugins come after the limiter. If a plugin raises the level, measure again.

The limiter is for peaks, not for making things loud: taking off many dB makes speech and music sound squashed. If it reports more than a few dB, lower the level first.

## Checking an audiobook file against ACX's requirements

**Audio › Check Against ACX Requirements…** measures the document against the audio submission requirements that ACX (Audible's audiobook service) publishes, and changes nothing. Each line shows ACX's own wording, what Jämmer measured, and whether that meets it:

| Requirement (ACX's article, dated 15 April 2026, read 16 November 2026) | How Jämmer measures it |
|---|---|
| "between the specific volume range of -23dB and -18dB RMS" | All samples of the whole file, both channels together, unweighted. ACX doesn't say how to measure it. |
| "peak values no higher than -3dB" | The highest sample and the true peak (between the samples) both have to be at or under −3. ACX says only "peak"; a file whose samples pass and whose true peak doesn't can still be turned down, so Jämmer asks both and says which one decided. |
| "a noise floor no higher than -60dB RMS" | The level of the quietest stretches between the speech. ACX doesn't say how to measure it. |
| "a 192 kbps or higher CBR, 44.1kHz MP3" | The document is encoded to exactly that (converted to 44.1 kHz when it is at another rate) and measured as it decodes, because the encoder changes the level a little. |
| "the same channel format (all mono or all stereo)" | Shown, not judged: it is about all the files of a book together. |
| "no longer than 120 minutes" | The document's length. |
| "Room tone spacing must not exceed 5 seconds" (1 to 5 seconds at each end is recommended) | The stretch at the start and at the end that stays under −45 dBFS. |
| "narrated by a human unless otherwise authorized" | Not something Jämmer measures; it is there so you know ACX asks it. |

Good to know:

- It says what was measured against the requirements as they read on that date. It never says a file is approved: only ACX does that, and ACX also asks for things no meter sees (one chapter per file with its header read out, opening and closing credits, a retail sample).
- The check is made on the MP3 as ACX wants it, so export it the same way: **File › Export Audio…**, **MP3 192 kbit/s**, and **Sample rate 44.1 kHz** when the document is at another rate.
- To bring a chapter into the range, use **Audio › Normalize** or a gain to set the level and **Limit Peaks** with a ceiling a little under −3 dBTP (say −3.5) to leave room for what the MP3 encoder adds, then check again.

