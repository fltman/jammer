# Stress test

`scripts/stress.sh` on 2026-11-15, release build, 10 cores, macOS Version 27.2.1 (Build 26B131), files on an external disk. One run; timings vary a little between runs.

"Redraw" is what the main thread does: it only ever draws from the peak index. Finer than one peak block (256 frames) per column, exact samples are then read on a background task and replace the picture; that time is in the notes.

| Step | Result | Notes |
|---|---|---|
| File | 3 h, 518400000 frames, 2.07 GB | 48 kHz stereo, 16-bit WAV |
| Write WAV | 57.3 s | 188× realtime, includes generating the signal |
| Open (parse chunks, open source) | 0.18 ms |  |
| Build peak index | 52.2 s | 207× realtime, reading 40 MB/s; peaks, loudness and export are bound by the disk |
| Peak cache | 30.9 MB | write 813.31 ms, read 13.01 ms |
| Memory after peaks (max RSS) | 149 MB |  |
| Redraw untouched, whole file | median 0.18 ms, max 0.52 ms | 2.592e+05 frames per column |
| Redraw untouched, 10 min | median 0.20 ms, max 0.29 ms | 1.44e+04 frames per column |
| Redraw untouched, 1 min | median 0.04 ms, max 0.05 ms | 1440 frames per column |
| Redraw untouched, 10 s | median 0.03 ms, max 0.04 ms | 240 frames per column; exact samples in the background: median 1.30 ms, max 70.94 ms |
| Redraw untouched, 1 s | median 0.02 ms, max 0.03 ms | 24 frames per column; exact samples in the background: median 0.14 ms, max 20.64 ms |
| Redraw untouched, 0.01 s | median 0.02 ms, max 0.03 ms | 0.24 frames per column; exact samples in the background: median 0.02 ms, max 5.35 ms |
| Ripple delete ×400 (with undo copy) | median 0.01 ms, max 0.05 ms | 394 clips afterwards |
| Compile render plan | median 0.00 ms, max 0.02 ms |  |
| Redraw after 400 cuts, whole file | median 0.19 ms, max 0.55 ms | 2.592e+05 frames per column |
| Redraw after 400 cuts, 10 min | median 0.16 ms, max 0.22 ms | 1.44e+04 frames per column |
| Redraw after 400 cuts, 1 min | median 0.04 ms, max 0.05 ms | 1440 frames per column |
| Redraw after 400 cuts, 10 s | median 0.03 ms, max 0.04 ms | 240 frames per column; exact samples in the background: median 1.31 ms, max 75.87 ms |
| Redraw after 400 cuts, 1 s | median 0.03 ms, max 0.03 ms | 24 frames per column; exact samples in the background: median 0.14 ms, max 19.71 ms |
| Redraw after 400 cuts, 0.01 s | median 0.02 ms, max 0.03 ms | 0.24 frames per column; exact samples in the background: median 0.02 ms, max 1.61 ms |
| Memory after edits (max RSS) | 165 MB |  |
| project.json, 394 clips | 135 KB | encode 1.51 ms, decode 1.15 ms |
| Loudness (BS.1770, true peak), edited timeline | 61.4 s | 169× realtime; -14.8 LUFS, -6.4 dBTP |
| Memory after loudness (max RSS) | 169 MB |  |
| Export 16-bit WAV, untouched | 110.4 s | 98× realtime |
| Memory after export (max RSS) | 169 MB |  |
| Null test, export vs source | identical | 110.6 s to compare 2.07 GB |
| Memory at the end (max RSS) | 169 MB |  |
