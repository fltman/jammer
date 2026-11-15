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

The status bar shows the gain that was applied. Normalizing to a loudness target doesn't limit peaks: measure afterwards, and if the true peak is above about −1 dBTP, lower the level or use a limiter in another app for now.
