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
