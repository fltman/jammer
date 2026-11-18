# Automation

Automation lets a track's level, pan, mute or sends, or a plugin's parameter, change over time: points on the timeline that the value follows from one to the next. The music goes down under a voice and up again, a sound moves from left to right, a plugin opens up in the chorus.

## Showing the lanes

**View › Automation** chooses which kind of lane is drawn over the tracks: **Level Lanes**, **Pan Lanes**, **Mute Lanes**, **Send Lanes** or **Plugin Parameters**. In a surround document **Place** and **Height** are listed too, and for a track that plays a sound field **Field Turn**, **Field Front** and **Field Side**. **Hide Lanes** hides them again. One kind is shown at a time, for every track that has one.

- What is drawn is what you hear: on a track in a VCA group, the line you hear (its own lane with the group's) is drawn thick, and the track's own lane thin beside it, with its points.
- A lane that is switched off is drawn dashed and grey, and is not heard.
- The caption at the left says what comes on top of the lane, such as the fader.

## Drawing a lane

Click a track's row once to give its lane the focus.

- **⌥-click** adds a point at the pointer. Near the line it takes the line's value, so nothing you hear changes. Further away it takes the pointer's height. Without ⌥, a click in the timeline does what it always did.
- **Drag** a point to move it in time and value. Hold **⇧** to keep its time, or **⌘** to keep its value. The whole drag is one undo step.
- A point snaps to the playhead, markers, the track's clip edges and the selection while you drag, and to 0 dB or the centre. Hold **⌃** to stop it snapping.
- A point never passes the points on either side of it.
- While you point at the line or drag a point, a label shows the time and the value. The status line says the same for the point you select, and so does VoiceOver.
- Deleting a lane's last point removes the lane. Undo brings it back.

## Keys

With a lane in focus:

| Key | What it does |
|---|---|
| ⌥→, ⌥← | Select the next or the previous point; the playhead goes there |
| ⌥Return | A point at the playhead, at the line's value there |
| ↑, ↓ | The selected point 0.5 dB up or down; a pan 5 % (↑ is left); a mute flips |
| ⇧↑, ⇧↓ | 0.1 dB; a pan 1 % |
| ⌥⇧↑, ⌥⇧↓ | 3 dB; a pan 25 % |
| ⌥⇧→, ⌥⇧← | The point 10 ms later or earlier |
| ⌘⌥→, ⌘⌥← | The point one frame later or earlier |
| ⇧→, ⇧← | Select the next point too, or the one before |
| ⌥Tab | On a send lane: the strip's next send |
| Delete | Remove the selected points |
| Escape | Nothing selected; the keys work the timeline again |

## Writing with the fader

In **Audio › Mixer…** each track and bus has a mode: **Read**, **Touch** or **Latch**. Lanes are only written while the sound plays and the Mixer is in front.

- **Read** plays the lanes. If you move a fader you hear the change, but nothing is written.
- **Touch** writes the fader into the lane while you hold it, and lets go back to the lane when you release it.
- **Latch** writes from when you first move the fader until playback stops.

The modes aren't saved in the document. Every strip goes back to Read when the Mixer closes, and Latch also goes back to Read when playback stops.

## Buses, groups and the master

**View › Automation › Buses, Groups and Master** opens thin rows under the tracks, one for each strip that can have a lane of the kind shown: buses always, VCA groups for level and mute, and the master for level. Adding, dragging and the keys work as they do over the tracks. ⌥↓ from the last track goes into the first of these rows, and ⌥↑ goes back.

## For agents

An agent writes lanes with `set_automation` and removes them with `clear_automation`. The guide (`GET /jammer`) describes both.
