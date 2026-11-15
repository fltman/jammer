# Exporting

**File › Export Audio…** (⇧⌘E) renders the project to a WAV file.

| Option | Choices |
|---|---|
| Format | WAV 16-bit, WAV 24-bit (default), WAV 32-bit float |
| Dither (TPDF) | Adds triangular dither when writing 16 or 24 bits. Leave it off for bit-exact copies of untouched audio. |
| Selection only | Exports just the selection (on by default when there is one) |

Exports that grow past 4 GB are written as RF64 automatically.

When you export from the start of the project, Jämmer carries over the first source file's Broadcast Wave description, timecode and iXML, adds a line to the coding history, and writes your markers as cue points. The bext loudness fields are left empty rather than copied, since the audio may have changed.

The status bar shows the progress and the file name when it's done.

## Other formats

Besides WAV, **File › Export Audio…** writes **AIFF** (24-bit), **FLAC** (16 or 24-bit), **Apple Lossless** (ALAC, 24-bit, .m4a) **AAC** (192 kbit/s, .m4a) and **Opus** (96 kbit/s, in an Ogg file as podcast hosts expect), with the encoders built into macOS. The lossless formats give back exactly the samples you hear (Jämmer's tests check it). Broadcast Wave metadata, iXML and markers are written in WAV only. **MP3** (160 kbit/s) uses LAME, which ships with Jämmer as a separate library under the LGPL; the file carries the LAME header, so players can trim the encoder's silence and play it gaplessly.

## Chapters

Markers are chapters. When you export **MP3**, each marker starts a chapter that runs to the next marker (or the end), written as ID3 chapter frames that Apple Podcasts, Overcast and most podcast apps show; if the first marker comes after the start, a chapter called "Start" covers the beginning. **Also save chapters as JSON** writes the same chapters as a Podcasting 2.0 chapters file (`name.chapters.json`) next to the audio, for hosts that take a separate file. WAV keeps markers as cue points, as before.
