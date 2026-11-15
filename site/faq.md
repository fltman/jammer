## What is Jämmer?

A native macOS audio editor for speech: podcasts, interviews, voice-overs and their clean-up. You edit by cutting the waveform or by deleting words in the transcript, repair hum, clicks, clipping and noise, find and level the speakers, set the loudness for the platform and export with chapters. It's the audio sibling of Glimmer (images) and Flimmer (video), and AI agents can drive it through a local API.

## What do I need to run it?

macOS 27 or later on a Mac with Apple silicon.

## Is it free?

Yes. Jämmer is free and open source under the MIT licence. The source code will be on GitHub when it's released. If you want to support the work, you can do so on [Patreon](https://www.patreon.com/AndersBjarby).

## Does it cost anything to use the AI features?

No, unless you choose to. Transcription, speaker finding, noise reduction and the built-in assistant all run on your Mac at no cost. The assistant can optionally use a cloud model through OpenRouter instead of the one on your Mac; that uses your own OpenRouter key (kept in the Keychain) and is billed by OpenRouter to you. An agent can only trigger paid steps when it explicitly allows them.

## What runs locally, and what leaves my Mac?

Everything runs locally: editing, playback, loudness, restoration, transcription, speaker finding, export, and the assistant with the on-device model. Your audio is never sent anywhere and there's no account. Two things use the network, both only when you ask: downloading a speech model in Settings › Models (from Hugging Face, or a mirror you choose), and the assistant's optional OpenRouter model, which sends your request and a description of the document (not the audio) to OpenRouter. The agent API listens only on your own Mac (127.0.0.1); other computers can't reach it.

## Does it work offline?

Yes. Once the models you want are downloaded, Jämmer needs no network at all: it starts, opens, edits, repairs, transcribes, finds speakers, exports and answers agents on 127.0.0.1 with the network off. Without a network, downloading a model and the OpenRouter option say so instead of working; nothing else is affected. We test this by running Jämmer in a sandbox that blocks every connection off the Mac.

## Does Jämmer depend on a server?

No. Jämmer doesn't rely on any service run by us. Models are fetched from their original source, and you can point Jämmer at your own mirror.

## Which models does it use, and how big are they?

Noise reduction (DeepFilterNet 3, 8 MB) ships inside the app. The rest are optional downloads under **Jämmer › Settings… › Models**, each shown with its size and licence before you download it, and removable there: KB-Whisper small (175 MB) or medium (539 MB) for the most accurate Swedish transcription, Parakeet TDT 0.6B v3 (about 630 MB) for 25 European languages, the speaker model (about 20 MB), and the two stem models (146 MB for music, 122 MB for soundtracks). Without any download, transcription uses the Mac's own recogniser. The assistant uses the model built into macOS.

## Why no HTDemucs stem separation?

Because its weights aren't free to use. The Demucs code is MIT, but its author has said that the trained weights aren't covered by that licence and are for research only, and they were trained on a non-commercial dataset. Jämmer only ships and downloads models whose licence allows everyone to use them, so stem separation uses Spleeter's 4-stem model from Deezer (MIT) instead. It's older and separates less cleanly, but it's yours to use for anything.

## Which files can I open?

WAV (including RF64 and BW64 for files over 4 GB), AIFF and AIFF-C are edited straight from the file. MP3, AAC/M4A, FLAC, ALAC and CAF are decoded once into a 32-bit float WAV that Jämmer keeps in its Application Support folder.

## Which files can I export?

WAV (16-bit, 24-bit or 32-bit float, with optional dither, keeping Broadcast Wave data and markers), AIFF, FLAC, ALAC and AAC (.m4a), Ogg Opus and MP3. Markers become chapters in MP3, M4A and Opus, and can also be saved as a Podcasting 2.0 chapters file.

## Will Jämmer change my original files?

No. Edits are stored in the project and played from the originals; repairs and effects play from new files beside them. Opening a WAV creates a new untitled project, so saving never overwrites the WAV. The one exception is deliberate: a clip that Flimmer hands over to edit is saved back into that same file when you press ⌘S.

## Can I use my plugins?

Yes: Audio Unit effects (AUv2 and AUv3) can be put on any track. Plugins from developers other than Apple run in a process of their own, so one that crashes can't take Jämmer down.

## How do I let an AI agent use Jämmer?

When Jämmer starts, the splash shows a line under "For your agent". Click Copy and paste it into Claude or another agent. The agent fetches the guide from Jämmer on your Mac and follows it. The splash is also under Help › Agent Access.

## What can an agent do, and what can't it?

It can do what the menus do: open audio, read the document and its transcript, measure loudness, edit, repair, transcribe, find and level speakers, add plugins, move through the history and export. Every request is one undo step, and a request that fails changes nothing. It can start playback only in a window you can see, it can't download models, and it can't open plugin windows.

## Does it work with VoiceOver?

Yes. Every control has a name, the timeline reads out the playhead, the selection and the drawn spectrogram area and moves with the VoiceOver increment and decrement gestures, and whatever can be drawn with the mouse (such as an area in the spectrogram) can also be typed in as numbers.

## Can I stop the splash from appearing?

Untick "Show at launch" on the splash. Help › Agent Access shows it again.

## How do I uninstall Jämmer?

Quit Jämmer and move it to the Trash. To remove everything else, also delete `~/Library/Application Support/Jammer` (decoded audio, repaired files and downloaded models), `~/Library/Caches/com.brattoo.jammer` (waveform caches) and `~/Library/Preferences/com.brattoo.jammer.plist`. If you saved an OpenRouter key, remove the "com.brattoo.jammer" item in Keychain Access.
