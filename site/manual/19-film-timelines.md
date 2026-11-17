# Film timelines

![A film's sound opened from Flimmer: four tracks, Dialog, Atmosfär, Musik and Video, with yellow markers where each picture starts](../screens/film.webp)

**File › Import Final Cut Pro XML…** opens the sound of a film timeline as a new Jämmer document, so you can clean, level and mix a film's audio with everything Jämmer has. It reads FCPXML, the format Flimmer exports and that Final Cut Pro and DaVinci Resolve also write.

## What you get

- **One track for each audio lane** of the timeline, in the same order, named after the track (from Flimmer) or the audio role.
- **Each clip where it was**, with its trim, its level and its fades. Fades come in as straight (linear) fades, as film editors draw them.
- **Track level and mute.** A muted track stays muted.
- **The sound of the video clips themselves** on a track called **Video**, under the picture it belongs to.
- **A marker for each picture** (shot), with its name, so you can see what the sound sits under. These shot markers are never chapters: they don't end up in an exported MP3 or M4A. In an exported WAV they are written as cue points labeled "Shot: " and the name, so another program can tell them from your own markers.

The picture itself isn't shown.

**What it has been tried with:** Flimmer's exports, and FCPXML files written by hand to the format's rules. It has not yet been tried with files that Final Cut Pro or DaVinci Resolve wrote, so expect rough edges there, and check the result against the original.

Files from Flimmer carry exact times and separate levels for clips and tracks, and Jämmer uses those. From other programs the times are whole picture frames and a clip's level is all on the clip.

## Things to know

- **Nothing is changed in the film project or its files.** The document is new and untitled; save it as a Jämmer project.
- **The media has to be where the file says.** Export from Flimmer with the media packaged beside the file. A clip whose file is missing is left out, and the status bar says so.
- **Mixed sample rates.** The document takes the timeline's sample rate. A file recorded at another rate plays from a converted copy that Jämmer keeps with its own media; the original stays as it was.
- **A clip that is switched off** in a lane where others are on is left out (Jämmer mutes tracks, not single clips). If every clip in a lane is off, the track comes in muted.
- **Clips that overlap** on one lane are spread over an extra track beside it.

The status bar tells you how many tracks and clips came in and the first of any notes.

## Agents

An agent can do the same with `POST /api/v1/import/fcpxml`, but only for a file in a folder you've allowed under **Jämmer › Settings… › Agents**, and only if the media it uses is in an allowed folder too. See [Agents](07-agents.md).
