# Speakers

**Audio › Find Speakers** works out who speaks when. The transcript then starts a new paragraph with the speaker's name each time someone else talks, and agents can ask who said what.

## Two ways

- **One person per track** (a double-ender, where each person recorded themselves): Jämmer treats each track as its speaker and names them after the tracks. It counts speech only where a track is clearly louder than the other voices bleeding into its microphone, so a laugh from the other side doesn't count, and real overlaps count for both. This is what Find Speakers does whenever several tracks play at the same time.
- **Everyone on one track**: a speaker-recognition model listens to each track and tells the voices apart. The first time, it downloads the model (about 20 MB) from Hugging Face; after that it works offline.

The model does very well with voices that sound different and take turns of a few seconds. It struggles with voices that sound alike in quick back-and-forth ("ja", "precis", "mm"): in our test with two similar women's voices it heard only one speaker. If you can, record each person on their own track. Agents can also tell it how many speakers there are, which helps.

## Names

The model calls them Speaker 1, Speaker 2 and so on; agents can rename them (`rename_speaker`). Speakers found on different tracks are kept apart even if they're the same person; give them the same name to pair them up.

## Edits and undo

Finding speakers is one undo step. Like transcript words, speaker turns belong to the recorded audio, so they stay right while you cut, move and delete. Run Find Speakers again to start over; it replaces the speakers on the tracks it looks at.
