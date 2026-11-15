# Documents and files

## Projects

A Jämmer project (`.jammer`) is a small package. Inside is `project.json`, a readable description of the tracks, clips, gains, fades and markers. The audio stays in your original files, which the project refers to by location.

- **File › New** (⌘N) makes an empty project.
- **File › Open…** (⌘O) opens projects and audio files.
- **File › Save…** (⌘S) saves; Jämmer also saves automatically as you work, like other Mac apps.
- **File › Duplicate** (⇧⌘S) makes a copy of the project.
- **File › Revert to Saved** goes back to the last save.
- **File › Close** (⌘W) closes the window.

If a file the project uses has been moved or deleted, the status bar says how many files are missing, and those clips play as silence.

## Audio files

Opening an audio file creates a new untitled project around it. Saving that project asks where to put the `.jammer` file; the audio file itself is never overwritten.

| Format | How Jämmer uses it |
|---|---|
| WAV, including RF64 and BW64 (files over 4 GB) | Played straight from the file |
| AIFF, AIFF-C (uncompressed, little- or big-endian, float) | Played straight from the file |
| MP3, AAC/M4A, FLAC, ALAC, CAF and other formats macOS can read | Decoded once to a 32-bit float WAV in `~/Library/Application Support/Jammer/Media` |

Bit depths from 8 to 32-bit integer and 32/64-bit float are supported.

## Metadata that's kept

Jämmer reads its own way through WAV and AIFF files instead of relying on macOS converters, which drop metadata. It keeps:

- the **Broadcast Wave (bext)** description, originator, date, time and timecode (time reference), coding history and loudness fields,
- **iXML** from field recorders,
- **markers and regions** (WAV cue points and labels, AIFF markers), which appear as markers on the timeline.

When you export from the start of the project, the first file's bext and iXML go with it, and your markers are written as cue points.
