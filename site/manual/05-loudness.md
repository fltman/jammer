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

## Limit Peaks

**Audio › Limit Peaks…** holds the true peak at or under a ceiling you give (−1 dBTP unless you type another, from −20 to 0). It works on the selection, or on the whole document when nothing is selected.

- All tracks get the same gain at each moment, so the balance between them stays, and it is their sum that is kept under the ceiling. (Limiting each track by itself would not keep the mix under it.)
- Where nothing needs limiting, the audio is left exactly as it was, sample for sample. Nothing is delayed.
- Each track plays from a new file over the limited stretch; your original files are untouched, and one undo takes it back.
- The status bar says what it did: the true peak afterwards, the most it took off, and for how long it was limiting. If the peak is already under the ceiling, it says so and changes nothing.
- "True peak" is the level between the samples as well as at them, measured the way ITU-R BS.1770 describes (four times oversampling at 48 kHz). A meter of that kind can read a few tenths of a dB under the real peak on the very worst signals, which is one reason delivery targets ask for −1 dBTP and not 0.
- A track's plugins come after the limiter. If a plugin raises the level, measure again.

The limiter is for peaks, not for making things loud: taking off many dB makes speech and music sound squashed. If it reports more than a few dB, lower the level first.
