# Transcripts and editing by text

Jämmer can write down what's said and let you edit the audio by editing the text. Recognition runs on your Mac with Apple's speech recognition; nothing is uploaded.

## Transcribe

1. Choose **View › Show Transcript** (⌥⌘T). The transcript panel opens under the timeline.
2. Pick the language and click **Transcribe**. The status bar shows the progress.

Every track is transcribed. A track of music gets "words" too (the recognizer hears speech where there is none), so don't be surprised by a few stray words there; they do no harm, and you can ignore them.

Swedish works through Apple's dictation recognition, which downloads its language files the first time (a few hundred MB, managed by macOS). English, German, French, Spanish, Italian, Portuguese and many more languages are supported as well; if a language isn't available on your Mac, Jämmer says so. You can keep editing while it transcribes.

## At OpenAI instead (text only)

The menu beside the language says where the document is transcribed. **On this Mac** is the default, and nothing leaves the Mac. **OpenAI (your key, paid)** uploads the audio to OpenAI and has it transcribed there:

- It is the audio that is sent: the whole of each file the document plays from, not only the parts on the timeline. Before anything goes, a sheet says how much that is, lets you choose one of the models OpenAI lists for your key, and waits for **Send**.
- OpenAI charges your account by its own price list. Jämmer can't read that list and doesn't guess the cost. Because the price is unknown, **Send** stays gray until you tick the box that says so. You are asked once; after that the sheet still says the price is unknown, and **Jämmer › Settings › Paid Services** is where you take the answer back.
- The text comes back **without the time of each word**. You can read it, search it and correct a word. You can't delete words or filler words from the audio with it, and clicking a word doesn't go to it; Jämmer says so when you try. For editing by text, transcribe on this Mac.
- Your OpenAI key is entered in the assistant's settings (the gear), under OpenAI, and is kept in your Keychain.
- This route is built from OpenAI's documentation and **has not yet been tried with a real request**. If OpenAI answers with an error, Jämmer shows it as it came. Jämmer hasn't been able to read OpenAI's terms for uploaded audio; read them there before sending anything that isn't yours to share.

## Edit by text

The transcript always reads what plays now. It's not a copy: cut something on the waveform and it disappears from the text; undo and it comes back.

| Do this | To |
|---|---|
| Select words | Select their audio on the timeline |
| Delete or Backspace | Remove the selected words from the audio, with the pauses between them (ripple) |
| Click a word | Move the playhead there |
| Space | Play or stop |

While playing, the word you hear is highlighted. Words the recognizer wasn't sure about have a dotted underline, so you can check them. Words cut through by a clip edge are shown dimmed.

Deleting words is an ordinary edit: it's one undo step, and the original file isn't changed.

## Good to know

- Each word is tied to the exact samples it was heard in, so edits, copy and paste, saving and reopening never shift the text.
- **Transcribe Again** replaces the transcript, for example after choosing another language.
- Agents can read the transcript and remove words by their ids; see the agent guide.
