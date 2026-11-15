# Troubleshooting

## I hear nothing

- Check the volume slider in Jämmer's transport bar; it's separate from the Mac's volume.
- Check that the right output device is chosen in Control Centre › Sound. Jämmer follows the Mac's current output.

## "1 missing file(s)" in the status bar

The project refers to an audio file that has been moved, renamed or deleted. Those clips play as silence. Put the file back where it was and reopen the project.

## A file won't open

Jämmer reads WAV, AIFF and every format macOS can decode (MP3, AAC, FLAC, ALAC, CAF). Files that macOS can't decode, or that are damaged, are refused with a message. A WAV that was cut off during recording opens with the audio that's there.

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
