# Omnibar

The omnibar is the field at the bottom of the window. Press **⌘K** (or choose **Edit › Omnibar**) to put the keyboard there. Then type part of a command's name, or what you want done.

## Commands

Type part of a command's name, for example `norm` or `fade`. The letters only need to appear in order. The best matches are listed above the field, and the commands you run most often from the omnibar come first among matches that are equally good. The omnibar lists transport and view commands, export, loudness measurement, agent access, and every editing operation with its presets (fades, silence, crop, gain ±1 and ±6 dB, and the four normalize targets).

- **↑ / ↓** move between the rows. **Return** runs the highlighted row. You can also click a row.
- **Esc** empties the field and gives the keyboard back to the timeline.

The omnibar, the menus and the agent API share one list of operations, so a command works the same way wherever you start it.

## Requests for the assistant

The last row sends what you typed to the assistant, for example `make the music quieter under the voice` or `ta bort alla ehm`. **⌘Return** always sends it there.

- A text that reads as a sentence, or that matches no command well, is highlighted for the assistant, so Return sends it there.
- A short text that could be either is decided by Apple's model on this Mac when you press Return (with Apple Intelligence on). It is free, and nothing leaves the Mac. Without the model, Return runs the highlighted command.
- The request goes to the assistant as if you had typed it in its own field. The assistant panel opens beside the timeline with the answer. It uses the source chosen in its settings, and asks first before a paid request (chapter 14).
