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

## Jämmer quits or stalls with a plugin on a track

Turn on **Safe mode** under **Audio › Plugins…**. Every plugin then runs in a process of its own, so one that crashes can't take Jämmer with it. If the document crashes Jämmer as soon as it opens, hold off on playing, open **Audio › Plugins…** and switch the plugin off or remove it. See [Plugins](15-plugins.md).

Plugins from developers other than Apple always run in a process of their own: for safety, Jämmer doesn't let other developers' code load into the app itself. That costs a little performance per plugin and keeps a crashing plugin from taking Jämmer down.
