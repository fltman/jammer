# Exporting

**File › Export Audio…** (⇧⌘E) renders the project to a WAV file.

| Option | Choices |
|---|---|
| Format | WAV 16-bit, WAV 24-bit (default), WAV 32-bit float |
| Dither (TPDF) | Adds triangular dither when writing 16 or 24 bits, which keeps quiet detail from turning into distortion when the bit depth goes down. It is ticked for you when you choose 16-bit WAV. Only samples that rounding would change get it: audio that is already 16 bits comes out exactly as it was, and silence stays silent, so it is safe to leave on. |
| Sample rate | **Same as the document** (default), or 44.1, 48, 88.2, 96, 22.05 or 16 kHz. Choose another rate only when the file has to be at it (an MP3 for ACX at 44.1 kHz, a 16 kHz file for a speech service): converting changes every sample. Opus is always 48 kHz. |
| Selection only | Exports just the selection (on by default when there is one) |

Exports that grow past 4 GB are written as RF64 automatically.

When you export from the start of the project, Jämmer carries over the first source file's Broadcast Wave description, timecode and iXML, adds a line to the coding history, and writes your markers as cue points. The bext loudness fields are left empty rather than copied, since the audio may have changed.

The status bar shows the progress and the file name when it's done.

## Other formats

Besides WAV, **File › Export Audio…** writes **AIFF** (24-bit), **FLAC** (16 or 24-bit), **Apple Lossless** (ALAC, 24-bit, .m4a) **AAC** (192 kbit/s, .m4a) and **Opus** (96 kbit/s, in an Ogg file as podcast hosts expect), with the encoders built into macOS. The lossless formats give back exactly the samples you hear (Jämmer's tests check it). Broadcast Wave metadata, iXML and markers are written in WAV only. **MP3** (160 kbit/s) uses LAME, which ships with Jämmer as a separate library under the LGPL; the file carries the LAME header, so players can trim the encoder's silence and play it gaplessly.

## Loudness of MP3, AAC and Opus

A lossy encoder changes the loudness a little: an MP3 can come out 0.4 LU quieter than the mix it was made from. So when you've just set the loudness with **Audio › Loudness Preset** and export to MP3, AAC or Opus, Jämmer reads the finished file back, measures it, corrects the level going into the encoder and encodes again (at most twice more), without letting the peaks pass the preset's ceiling. The status bar then says what the file measures, for example "Exported Episode 7.mp3 at −16.0 LUFS (+0.44 dB to make up for the encoder)".

This only happens while the document is as the preset left it. Edit anything afterwards and the export is a plain one again; apply the preset once more when you're done. WAV, AIFF, FLAC and Apple Lossless keep the mix exactly, so there is nothing to correct.

## Chapters

![The export dialog with MP3 chosen and Chapters from markers ticked](../screens/export.webp)

Markers are chapters. Each marker starts a chapter that runs to the next marker (or the end). **MP3** gets ID3 chapter frames, **AAC and ALAC** (.m4a) a chapter track like the ones Apple Podcasts and QuickTime show, and **Opus** CHAPTER comments, which ffmpeg-based players read; if the first marker comes after the start, a chapter called "Start" covers the beginning. **Also save chapters as JSON** writes the same chapters as a Podcasting 2.0 chapters file (`name.chapters.json`) next to the audio, for hosts that take a separate file. WAV keeps markers as cue points, as before; AIFF and FLAC get no chapters.

## Another sample rate

When you choose another sample rate than the document's, the mix is converted on the way out; the document itself is not changed. Markers and chapters stay at the same times.

Sample rate converter designed by Aleksey Vaneev of Voxengo (r8brain-free-src). What Jämmer measured it to before putting it in, from 48 to 44.1 kHz: a tone comes out at the same level to four decimals of a dB, with everything else more than 150 dB under it; the response is flat up to 21 kHz; a tone above the new rate's limit (which would otherwise fold back as a false tone) is more than 150 dB down; nothing moves in time, and the file is exactly as long as it should be. On the same signal its output agrees with Apple's converter to −146 dB and with ffmpeg's to −124 dB.

Going down in bit depth as well (a 16-bit WAV at 44.1 kHz from a 48 kHz, 24-bit document): the rate is converted first and dither is added last, once.

