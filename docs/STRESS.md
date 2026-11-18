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

## Hostile and broken files (2026-11-15)

Files come from the net, from siblings and from agents, so opening one is untrusted input. The test suite makes its own (nothing is downloaded) and feeds them through the importer that every route in shares: `HostileFileTests` and `HostileFCPXMLTests` in `JammerCoreTests`.

| What | How many | Result |
|---|---|---|
| WAV cut at 18 offsets; data size 0xFFFFFFFF and past the end; channels 0, 1000, 65535; rate 0, 1, 3 MHz, 4 billion; bits 0, 65535; cue list claiming 4 billion points; label, iXML, bext and JUNK chunks larger than the file; 5000 chunks; RF64 with 64-bit sizes up to the maximum; empty, one byte, zeros, noise, text; 300 headers with random bytes changed | about 350 files | each refused in words or opened as sound that is in the file |
| AIFF cut at 14 offsets; frame count past the end; channels 0 and 65535; bits 0; sample rate 0, infinity, not-a-number, negative, 1e300, tiny; sound offset past the end; 300 random headers | about 330 | the same |
| FLAC, AAC, Apple Lossless (M4A and CAF), CAF PCM: cut at 13 offsets each, 150 files each with header bytes changed, and the right bytes under the wrong name | about 830 | the same; a refusal leaves no half-decoded file |
| MP3-shaped garbage: an ID3 tag claiming 256 MB, frame headers over noise | 7 | refused |
| Decoded size: a FLAC against a 1 MB limit | 1 | refused before anything is kept; opens whole when there is room |
| FCPXML: external entities pointing at a file and an address; a billion laughs; a quadratic entity; nesting 100 000 deep; 100 000 clips; an 8 MB attribute; 65 MB of input; times at the limits of 64-bit integers, zero denominators, infinities | 14 | refused in words or read; the secret file's content never appears; no clip lands outside its file or more than a day into the timeline |

What they found and what was changed:

- A header claiming a sample rate too large for an integer crashed Jämmer while it was writing the refusal. Fixed.
- A WAV or AIFF that Jämmer's own reader refused as absurd was then handed to the system's decoder, which sometimes took it. Now a refusal by the reader stands.
- Header-only files opened as empty documents. Now refused.
- RF64 sizes above the 64-bit signed range would have trapped. Now clamped; every chunk is clamped to the file.
- Channels are limited to 32 and sample rates to 8–768 kHz, for files read directly and for what the system's decoder reports.
- Decoding stops at a size limit (free space less 2 GB, at most 64 GB), checked against what the file claims before anything is written and against what actually comes out while it is.
- A decode that fails removes its partial file. A linked file that can't be opened no longer leaves its copy in the media folder.
- A cut-off WAV or AIFF opens with a warning (status bar, `warning` in the API answer, `warnings` in a batch result); a compressed file that ends early is refused with "is cut short".
- FCPXML: any entity declaration is refused before parsing; size, depth and element count are limited; time arithmetic saturates instead of overflowing; gains are bounded; clips placed beyond a day are left out with a note.

Tried in the running app as well, through `POST /documents`, an upload in two parts, `POST /import/fcpxml` and a batch over a folder of ten such files: every refusal in words, no leftover files in the media folder, the app still answering afterwards. Not tried by hand: File › Open and a linked file from Flimmer with such files (both use the same importer). Project packages (`.jammer`) with hostile contents are not covered here.

## Hostile project packages (2026-11-15)

A `.jammer` package is shared between people and opened with a double-click. `HostileProjectTests` makes its own and checks:

| What | Result |
|---|---|
| project.json cut at six offsets, missing, and 200 copies with bytes changed | refused in words, or opened as something that passes every check |
| Clips before 0, past their audio, past the timeline, of no or negative length, with levels of 1e300; markers outside the timeline; 4 billion Hz; 70 000 channels; more tracks, clips, markers or files than the limits | clips and markers left out and counted in the status bar; the rest refused |
| A source "in the package" given as `../x`, an absolute path, a deeper folder, `Media/..`, a link in Media/, and Media itself as a link | not followed; the clip is silent; nothing outside is read |
| A text file described as 16-bit audio; a real WAV with a false offset, channel count, rate, format or byte order; more sound claimed than there is | not read at all, except the last, which plays what is there |
| A file outside what the document may read, also through a link and `..` | refused by its real location |
| Collect Audio and Save with a refused file | the file is not copied into the package |
| History: a state that expands to 600 MB, garbage, a state with an impossible sample rate | refused |

Two rules carry this. A file is opened only when the file's own header agrees with what the project says about it, so a project can't make another file be read as sound and carried out in an export. And a document opened from a project file reads only from the package, Jämmer's own media folder, and files the user has opened here or allowed; anything else is asked about, with "Open Without Them" as the default.

Tried in the app with five packages: one with its sound inside (plays, no question), one naming a text file as audio (asked about as an outside file; never read; the export is silent and doesn't contain the text), one with a path climbing out (silent, no question), one naming a recording in another folder (silent until "Use These Files", then it plays), and a damaged one (an alert; the app carries on). The first version of this read the outside recording before the rule was in place, because the files were opened when the window was made; the by-hand check caught it.

What an Audio Unit's saved state in a project could do to the plugin that loads it: since 2026-11-16 such settings are asked about before they are loaded (see `RELEASE.md`, "Plugin settings in a project from elsewhere"); what a plugin does with settings the user allows is still not covered.

### By hand, through File › Open and as a linked file (2026-11-16)

The hostile audio files, opened in the app the three ways a person opens a file: the Open panel, from outside (as the Finder does), and sent by a sibling app as a linked file.

| File | Open panel / from outside | Linked |
|---|---|---|
| cut short in its audio | opens with 0.5 s and the warning in the status bar | the same, with the warning in the sent file's name |
| 65 535 channels, 4 billion Hz, header cut off | alert with the reason | falls back to an ordinary open; the same alert |
| text named .mp3, tag claiming 256 MB, empty .wav | alert: not audio this Mac can decode | — |
| a header and no sound | alert: no sound in it | alert, in the sent file's name |

No file was changed by being opened, no copy was left in the media folder, and the app answered afterwards.

Two things this found. The alerts said only "The document … could not be opened", without the reason: AppKit shows an error's failure reason there and nothing of its description, so the tests, which read the error's text, passed while a person saw no reason. The reason is now given as the failure reason, for audio files and for damaged projects. And a linked file with no sound was reported under the name of Jämmer's private copy ("791EC49A no-sound.wav"); it is now reported under its own name.

## A linked document across quit, kill and a missing file (2026-11-16)

Found by Flimmer's live test: a document linked to a sibling's file ("Edit in Jämmer") stopped being linked when Jämmer was started again, and ⌘S then offered the ordinary Save panel. Reproducing it found the larger half: quitting or closing a linked document with changes showed AppKit's Save panel (Delete / Cancel / Save), as for any unsaved document.

Now: the link (bookmark, path, format, who asked) is saved with the window's state and restored with it; a link that can't be used is reported, never dropped; and closing or quitting asks about saving back to the linked file. In the package tests: restored, followed when the file is moved or renamed, found again when a file is put back at the old path, and lost in words when it is read-only, another shape, not audio, or gone. In the app, with a 24-bit WAV handed over as Flimmer does it:

| What | Result |
|---|---|
| Quit with changes | "Save your changes back to "clip.wav"?"; Cancel keeps the document, linked; Save Back writes the file in place and quits; Don't Save quits and leaves the file as it was |
| SIGKILL with changes, start again | the document is back, linked, File › Save Back to clip.wav; ⌘S writes the file |
| SIGTERM with nothing unsaved, start again | the document is back, linked |
| The file removed while Jämmer was away | the title says it can't be saved back; ⌘S explains why and offers Save a Jämmer Copy…; no Save panel by itself |
| The file put back, ⌘S | linked again and saved |

The window state is only written when Jämmer stops being the front app (AppKit's doing), so a kill while it has been in front all along, straight after the hand-over, restores nothing. In use the user has gone back to the other app, which is when it is written.

Two faults in the test equipment came out of this and are fixed: `scripts/with-app.sh` had lost its `$pid` in an edit, so its clean-up stopped nothing and waited for ever (a stray test app, and once a held GUI lock); and GUI scripts now run under the series' `run-supervised.sh`, with a time limit.

## Known cases in the test suite (failures under load)

Written down so a failure can be compared word for word before it is called known; nothing in the suite retries or skips them.

| Test | When it failed | The failure, as printed | On its own |
|---|---|---|---|
| `EngineTests.swift`, "A level under a hand: with none the output is the source bit for bit, also on a track marked for it; a trim for another plan does nothing; a trim of −6 dB is −6 dB once its first block has ramped to it, and what was put on comes back frame by frame" (line 408) | 2026-11-18, in the pre-commit check, one-minute load 13.17 (another session's builds and a live test with Flimmer) | `zip(applied, applied.dropFirst()).allSatisfy { $0.0 < $1.0 } && (applied.last?.0 ?? 0) >= Int64(count) → false` (the first half false: the frames at which the trim was applied, read back, were not strictly rising) | Passed 3 of 3 right after, at the same load; the next pre-commit run green |

What it may mean, not yet looked into: the test reads back, from the engine, at which frames a hand trim was applied; under load the reading thread can see two applications at one frame, or out of order. Whether that is the test's reading or the engine's applying is open. If it fails again with other words, it is not this case.
