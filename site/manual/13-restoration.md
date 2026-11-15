# Restoration

**Audio › Remove Hum…, Repair Clipping…, Remove Clicks…** (also in the command palette) open the Restore sheet. It works on the selection, or on the whole document when nothing is selected.

## The repairs

| Repair | What it does |
|---|---|
| **Remove Hum** | Finds mains hum at 50 or 60 Hz (to a few thousandths of a hertz) and removes it and its harmonics with narrow notch filters. Speech and music around it are left alone. Choose 50 or 60 Hz yourself if it doesn't find the hum. |
| **Repair Clipping** | Finds samples flattened at the top of the range and rebuilds the wave from the audio around them. |
| **Remove Clicks** | Finds short clicks and pops and fills them in from the surrounding audio. Raise the sensitivity to catch quieter clicks. |

When the sheet opens, Jämmer looks at the audio and tells you what it found, for example "Hum at 50.00 Hz · no clipping · 4 clicks".

## Amount and preview

**Amount** blends between the original (0 %) and the full repair (100 %). **Preview** plays up to 30 seconds from the selection (or the playhead) with the repair; switch between **Original** and **Repaired** while it plays to compare. Nothing changes until you click **Apply**.

## What Apply does

The repaired clips play from a new file that Jämmer writes in `~/Library/Application Support/Jammer/Media` (use **File › Collect Audio and Save** to move it into the project). Your original file is never changed, and one **Undo** brings back the unrepaired audio. Transcripts stay with the repaired clips. The status bar shows the progress; you can keep working meanwhile.

Noise reduction with DeepFilterNet is planned.

## Drawing in the spectrogram

In the spectrogram (**View › Show Spectrogram**) you can mark a sound by where it is in time *and* pitch, and change only that. Pick a tool with **B** (box), **L** (lasso) or **P** (brush), then drag over the sound on its track; the area shows in turquoise and the status bar describes it ("Box, 1.42–1.59 s, 66–210 Hz"). Esc clears it.

- **Audio › Heal Area** rebuilds the area from the sound just before and after it. It's for short sounds (a click, a cough, a phone ringing, up to half a second); longer areas are refused, use attenuate for those.
- **Audio › Attenuate Area…** lowers the area by the amount you choose.
- **Audio › Edit Spectrum Numerically…** does the same with a box you type in (time in seconds, frequency in Hz) on a track you pick, for when drawing isn't practical.

As with the other repairs, the changed stretch plays from a new file; the original stays untouched and one undo brings it back, and the transcript and speakers stay as they were.
