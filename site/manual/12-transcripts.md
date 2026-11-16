# Transcripts and editing by text

Jämmer can write down what's said and let you edit the audio by editing the text. Recognition runs on your Mac with Apple's speech recognition; nothing is uploaded.

## Transcribe

1. Choose **View › Show Transcript** (⌥⌘T). The transcript panel opens under the timeline.
2. Pick the language and click **Transcribe**. The status bar shows the progress.

Every track is transcribed. A track of music gets "words" too (the recogniser hears speech where there is none), so don't be surprised by a few stray words there; they do no harm, and you can ignore them.

Swedish works through Apple's dictation recognition, which downloads its language files the first time (a few hundred MB, managed by macOS). English, German, French, Spanish, Italian, Portuguese and many more languages are supported as well; if a language isn't available on your Mac, Jämmer says so. You can keep editing while it transcribes.

## Edit by text

The transcript always reads what plays now. It's not a copy: cut something on the waveform and it disappears from the text; undo and it comes back.

| Do this | To |
|---|---|
| Select words | Select their audio on the timeline |
| Delete or Backspace | Remove the selected words from the audio, with the pauses between them (ripple) |
| Click a word | Move the playhead there |
| Space | Play or stop |

While playing, the word you hear is highlighted. Words the recogniser wasn't sure about have a dotted underline, so you can check them. Words cut through by a clip edge are shown dimmed.

Deleting words is an ordinary edit: it's one undo step, and the original file isn't changed.

## Good to know

- Each word is tied to the exact samples it was heard in, so edits, copy and paste, saving and reopening never shift the text.
- **Transcribe Again** replaces the transcript, for example after choosing another language.
- Agents can read the transcript and remove words by their ids; see the agent guide.
