# Surround and Ambisonics

A document can be wider than stereo: **5.1**, **7.1** or **7.1.4** for loudspeakers, or **Ambisonics** (a sound field in AmbiX, first to third order).

## The layout

- A WAV file in 5.1, 7.1 or 7.1.4 opens in its own layout; the status bar names it.
- **Track › Layout** changes a document's layout. Nothing is converted: every file keeps its own channels and is heard in the new layout through its loudspeakers. Changing it is one undo step. Playback stops when the layout changes.
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
- **Transport › Listen on Headphones (Binaural)** renders a loudspeaker document for headphones instead, through Apple's spatial mixer. It is a setting for listening only, and every open document follows it.
- An Ambisonics document is always heard through Apple's spatial mixer: for headphones when that setting is on, for loudspeakers when it is off.
- **Transport › Follow Head Movements** (while listening binaurally): with headphones that have motion sensors, such as AirPods Pro, AirPods Max or AirPods (3rd generation and later), the sound stays where it is as you turn your head. macOS asks the first time whether Jämmer may read the headphones' motion; Jämmer reads it only while this is on and keeps nothing. **Transport › Center Head** makes where you look now the front. It is off when Jämmer starts, and turning binaural listening off turns it off too. It changes only what you hear, never the document or an export.

## Loudness

The loudness meter weights the channels as ITU-R BS.1770-5 does: the surrounds at the sides count a little more, the LFE not at all, rear and height channels like the front. Measured 5.1 agrees with the EBU's test case and with ffmpeg, and 7.1 and 7.1.4 read the ITU's own test files (ITU-R BS.2217) within 0.001 LU.

BS.1770 has no loudness for a sound field. In an Ambisonics document loudness isn't measured, and normalizing to a loudness, loudness presets, the limiter and an export's loudness target are not offered. Export it for loudspeakers or headphones and measure that.

## Exporting

- **WAV** keeps all the channels, marked with the layout's loudspeakers (an Ambisonics WAV is marked with none, as AmbiX files are). A 5.1, 7.1 or 7.1.4 WAV is also an ADM BWF file: it names each channel's loudspeaker the way broadcast and immersive tools read it (ITU-R BS.2076 metadata, checked with the EBU's ADM renderer). Opening such a file, Jämmer uses those names too, so its channels land on the right loudspeakers even when the file has no channel mask.
- **ADM objects** (an option of a WAV export, when a track is placed): each placed track is written as an object of its own with its place over time, its azimuth and elevation automation included, after the bed of everything else; a stereo track is two objects, its left and right. What the track sends to a bus (a reverb) stays in the bed. Jämmer reads the objects back; other tools that read ADM objects render each from where it is, but this hasn't been tried with one yet.

A 7.1 or 7.1.4 WAV with no channel mask and no ADM doesn't say whether its sides or its rears come first. Jämmer hears it in ITU-R BS.2051's order, the sides first (L R C LFE Lss Rss Lrs Rrs), as the ITU's own test files and most immersive tools write it, and says so in the status line when it opens. If the file came from a tool that puts the rears first, choose **Track › Layout › Unmarked File: Rears First (WAV Order)**; it changes only how the file is heard, and ⌘Z takes it back. A file with a channel mask or ADM is always heard by what it says.
- **APAC (MP4)**, Apple's spatial codec, appears in the export's format list for loudspeaker layouts wider than stereo and for Ambisonics.
- MP3 and Opus aren't offered for these documents.

## For agents

`set_layout` sets the layout (`mono`, `stereo`, `5.1`, `7.1`, `7.1.4`, `ambix1`, `ambix2`, `ambix3`; an Ambisonics layout marks the files of its size as sound fields; `order` `bs2051` or `wav` says how a 7.1 or 7.1.4 file without a mask or ADM is heard, also as `?order=` when a document is made); `set_track` `field` (1–3, 0) marks a track's files, and `yaw`, `pitch`, `roll` turn its field (`turned: false` takes the turn away); `GET …/documents/{id}` has `layout` and `outputPath` (`binaural` or `spatialSpeakers` when the spatial mixer is used). `set_track` places a track with `azimuth` (degrees, positive to the left), `elevation` and `width`, and `placed: false` takes it back; each track in `GET …/mixer` has its `position`. `POST …/export` with `format: "apac"`. In a loudspeaker layout `pan` is refused, and in mono or stereo a place by azimuth is refused, each with the reason in words.
