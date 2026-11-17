# Surround and Ambisonics

A document can be wider than stereo: **5.1**, **7.1** or **7.1.4** for loudspeakers, or **Ambisonics** (a sound field in AmbiX, first to third order).

## The layout

- A WAV file in 5.1, 7.1 or 7.1.4 opens in its own layout; the status bar names it.
- **Audio › Layout** changes a document's layout. Nothing is converted: every file keeps its own channels and is heard in the new layout through its loudspeakers. Changing it is one undo step. Playback stops when the layout changes.
- A file of 4, 9 or 16 channels opens as stereo, because nothing in a WAV file says it is Ambisonics. Choose **Ambisonics (1st Order)** (or 2nd, 3rd) to hear it as the sound field it is.

## Where each file is heard

- In a loudspeaker layout a mono file goes to the centre, a stereo file to the left and right front, and a file in the document's own layout channel for channel. Nothing goes to the LFE unless the file has it.
- A file wider than the document is folded down: 5.1 into stereo as ITU-R BS.775 gives it (the centre and the surrounds at −3 dB into the front pair, the LFE left out), 7.1 into 5.1 by joining each side and rear into the surround. The heights of 7.1.4 go into the loudspeaker under them at −3 dB, Jämmer's own choice, since the standards give none. A fold-down isn't made quieter, so it can clip; watch the level.
- In an Ambisonics document a loudspeaker file is placed from its loudspeakers' directions, and a mono file from the front.
- An Ambisonics file in a loudspeaker document is decoded (see below) once Jämmer knows it is one.

The waveform shows each file where it is heard: a voice in the centre row, not in every row.

## Placing a track

In a document wider than stereo there is no left-right pan. Instead each track has a place around the listener, in the Mixer:

- The slider moves the track around you: left to the left, right to the right, either end behind.
- The menu beside it says where the track is ("Left 110°", "Center", "Own loudspeakers"). In 7.1.4 and Ambisonics it also sets the height. **Back on Own Loudspeakers** puts each file back where it was heard before it was placed.
- A stereo file is placed as a pair, 60° apart by default. A mono file is placed as one point.
- Between two loudspeakers the sound is shared by both at the same overall level. On a loudspeaker's own direction only that loudspeaker plays.

## A sound field in loudspeakers

Nothing in a WAV file says that its channels are Ambisonics, so Jämmer has to be told: making the document Ambisonics of that order marks its files of that size as sound fields, and they stay fields when the document becomes 5.1, 7.1 or 7.1.4. There a field is decoded to the loudspeakers by AllRAD (All-Round Ambisonic Decoding, by Zotter and Frank): its sound comes from the loudspeakers nearest each direction, at an even level. Into stereo or mono it is decoded to 5.1 first and folded down.

Measured, not heard: in 7.1 a sound at ear level comes from within a few degrees of its direction; in 5.1 the gap behind the listener is less precise; in 7.1.4 a sound at ear level is pulled up a little by the height loudspeakers. A 5.1 or 7.1 layout has no heights, so what is above in the field is heard at ear level. The figures are in the project's notes (docs/IMMERSIVE.md).

## Turning a sound field

A track that plays a sound field can be turned round the listener: in the Mixer the slider turns it (to the left is to the left), and the menu beside it lifts its front or one side, or takes the turn away. The turn applies in an Ambisonics document and in loudspeakers alike.

## Listening

- On a device with fewer channels than the document, such as the Mac's speakers or headphones, a loudspeaker document is folded down to stereo by the same rules. The document and its exports keep all their channels.
- **Audio › Listen on Headphones (Binaural)** renders a loudspeaker document for headphones instead, through Apple's spatial mixer. It is a setting for listening only, and every open document follows it.
- An Ambisonics document is always heard through Apple's spatial mixer: for headphones when that setting is on, for loudspeakers when it is off.
- Head tracking isn't available.

## Loudness

The loudness meter weights the channels as ITU-R BS.1770-5 does: the surrounds at the sides count a little more, the LFE not at all, rear and height channels like the front. Measured 5.1 agrees with the EBU's test case and with ffmpeg; 7.1 and 7.1.4 have not yet been checked against the ITU's test files.

BS.1770 has no loudness for a sound field. In an Ambisonics document loudness isn't measured, and normalizing to a loudness, loudness presets, the limiter and an export's loudness target are not offered. Export it for loudspeakers or headphones and measure that.

## Exporting

- **WAV** keeps all the channels, marked with the layout's loudspeakers (an Ambisonics WAV is marked with none, as AmbiX files are).
- **APAC (MP4)**, Apple's spatial codec, appears in the export's format list for loudspeaker layouts wider than stereo and for Ambisonics.
- MP3 and Opus aren't offered for these documents.

## For agents

`set_layout` sets the layout (`mono`, `stereo`, `5.1`, `7.1`, `7.1.4`, `ambix1`, `ambix2`, `ambix3`; an Ambisonics layout marks the files of its size as sound fields); `set_track` `field` (1–3, 0) marks a track's files, and `yaw`, `pitch`, `roll` turn its field (`turned: false` takes the turn away); `GET …/documents/{id}` has `layout` and `outputPath` (`binaural` or `spatialSpeakers` when the spatial mixer is used). `set_track` places a track with `azimuth` (degrees, positive to the left), `elevation` and `width`, and `placed: false` takes it back; each track in `GET …/mixer` has its `position`. `POST …/export` with `format: "apac"`. In a loudspeaker layout `pan` is refused, and in mono or stereo a place by azimuth is refused, each with the reason in words.
