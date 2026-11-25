# Troubleshooting

## I hear nothing

- Check the volume slider in Jämmer's transport bar; it's separate from the Mac's volume.
- Check that the right output device is chosen in Control Center › Sound. Jämmer follows the Mac's current output.

## "1 missing file(s)" in the status bar

The project refers to an audio file that has been moved, renamed or deleted. Those clips play as silence. Put the file back where it was and reopen the project.

## A file won't open

Jämmer says why. The usual reasons:

- **It isn't audio Jämmer can read.** Jämmer takes WAV (also RF64 and BW64), AIFF, MP3, AAC/M4A, FLAC, Apple Lossless and CAF. A file with the wrong extension is read for what it is, not what it's called.
- **It is cut off or damaged.** A WAV or AIFF whose recording was interrupted opens with the sound that is there, and the status bar says how much is missing ("… is cut short or damaged: 12.4 s of the 60.0 s it says it has could be read"). A compressed file (MP3, AAC, FLAC) that ends in the middle is refused instead, since what could be decoded can't be trusted to be whole.
- **It has no sound in it.** An empty recording isn't opened as an empty document.
- **Its header makes no sense.** A file that says it has thousands of channels or a sample rate of four billion is refused: Jämmer takes up to 32 channels and 8 to 768 kHz.
- **It would be too large decoded.** A compressed file is decoded once into a file Jämmer keeps; if that wouldn't fit on the disk with room to spare, it is refused before anything is written.

A file that is refused changes nothing and leaves nothing behind on disk.

## "The range covers more than one clip"

Fades must lie inside one clip per track. Select a range that doesn't cross a clip edge (the thin vertical lines), or fade each clip separately.

## The waveform says "Reading waveform…"

For long recordings, Jämmer builds an overview the first time. It's cached in `~/Library/Caches/com.brattoo.jammer`, so it's instant next time. You can play and edit while it's being built.

## The agent can't connect

- Check the address on the splash (Help › Agent Access…). If 9003 was busy, Jämmer uses a port between 9301 and 9319.
- If the splash says all ports are in use, quit other apps that use those ports and restart Jämmer.
- Agents must run on the same Mac.

## The agent says playback isn't allowed

Jämmer only plays for an agent in a window you can see. Bring the document's window to the front.

## After normalizing, the true peak is above −1 dBTP

Normalizing to a loudness target raises everything by the same amount and doesn't limit peaks. Lower the gain, or normalize the true peak to −1 dBTP instead.

## Jämmer quits or stalls with a plugin on a track

Turn on **Safe mode** under **Track › Plugins…**. Every plugin then runs in macOS's separate plugin host process instead of inside Jämmer, which is meant to keep a plugin that crashes from taking Jämmer with it. If the document crashes Jämmer as soon as it opens, hold off on playing, open **Track › Plugins…** and switch the plugin off or remove it. See [Plugins](15-plugins.md).

