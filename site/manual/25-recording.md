# Recording

Jämmer records from your Mac's input onto one or more tracks at once, while the other tracks play. Each take is written to a file of its own in Jämmer's media folder, as you record, and a crash loses at most the last second of it.

## Arming tracks

Press **R** in a track's header to arm it (or choose **Track › Arm to Record** for the current track). The first time, macOS asks whether Jämmer may use the microphone. That answer is yours, and you can change it later under System Settings › Privacy & Security › Microphone.

An armed track's **R** is red, and its meter shows its input, so you can set the level before you record. The menu beside the **R** chooses the input: **In 1**, **In 2**, … for one channel, or **In 1+2** for a pair. Several tracks can be armed at once, each from its own input. The input is the device chosen under System Settings › Sound › Input, and it must run at the document's sample rate (set it in Audio MIDI Setup if it doesn't). A locked track can't be armed.

## Recording

Put the playhead where the take should start and press **Transport › Record** (⌘R), or the Record button beside Play. The armed tracks record while the others play. The transport bar shows a steady red **● Recording 0:12**; it doesn't blink. Press ⌘R or Space again to stop. The takes go onto their tracks as one undo step, over whatever lay there. Nothing else on the timeline moves.

Jämmer keeps 2 GB of the disk free. Record is off when there is room for less than two minutes. While recording, Jämmer says when about ten minutes are left, and it stops by itself at the reserve, keeping what it has. If the disk didn't keep up and some sound was lost, the status bar says how much.

## Punching in

Select a stretch first, then press Record: that is a punch. Playback starts two seconds before the selection (the pre-roll), so you hear what comes before and come in on time. The take covers exactly the selection, and the recording stops by itself just after it.

## Takes

Recording again over a stretch that was recorded before doesn't throw the earlier take away. Every take is kept, and the newest plays. Right-click the clip (or use its menu with VoiceOver) to see its **Takes**: **Take 1**, **Take 2** and so on, with the one playing checked. Choose another to play it instead. The stretch is laid again from what was there before it was first recorded, with that take over it, so a shorter take leaves the original sound around it. If the takes were moved since, by a drag or a cut earlier in the track, they go with them.

**Delete Take** removes the take that plays, and the newest one left plays instead. Deleting the last take gives the stretch back as it was before it was recorded. It is an undo step like any other. The file stays in the media folder until **File › Storage…** clears it.

An agent can see the takes in the document and choose among them (`set_take`), but only you arm, record and delete takes.

## After a crash

If Jämmer or the Mac stops while recording, the takes are kept up to their last second. The next time the document opens, Jämmer offers to put them back where they were recorded. This works even if the document was moved or renamed in the meantime. **Later** asks again next time; **Forget** stops asking, and the files stay in the media folder.

A recording in a new document that was never saved isn't lost either. Jämmer autosaves the document as soon as it starts recording, so macOS brings it back with the rest of your windows. If the document doesn't come back, Jämmer opens a **Recovered Recordings** window after launch. It lists each recording that no open document claims. **Open in New Document** puts its takes on tracks of their own; **Forget** stops offering it.
