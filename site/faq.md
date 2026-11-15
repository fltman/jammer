## What is Jämmer?

A native macOS audio editor for speech, restoration and post-production. It's the audio sibling of Glimmer (images) and Flimmer (video). Version 0.1 is the foundation: non-destructive editing, loudness measurement and normalization, WAV/AIFF with their metadata, and a local API for AI agents.

## What do I need to run it?

macOS 27 or later on a Mac with Apple silicon.

## Is it free?

Yes. Jämmer is free and open source under the MIT licence. The source code will be on GitHub when it's released. If you want to support the work, you can do so on [Patreon](https://www.patreon.com/AndersBjarby).

## Does it cost anything to use the AI features?

Nothing in Jämmer costs money today: everything runs on your Mac. If paid cloud features are added later, they will use your own OpenRouter key, and an agent can only use them when it explicitly allows paid steps.

## What runs locally, and what leaves my Mac?

Everything runs locally. Jämmer doesn't send your audio anywhere and doesn't need an account. The agent API listens only on your own Mac (127.0.0.1); other computers on your network can't reach it.

## Does Jämmer depend on a server?

No. Jämmer doesn't rely on any service run by us. Future features that download models will fetch them from their original source, and you'll be able to point Jämmer at your own mirror.

## Which files can I open?

WAV (including RF64 and BW64 for files over 4 GB), AIFF and AIFF-C are edited straight from the file. MP3, AAC/M4A, FLAC, ALAC and CAF are decoded once into a 32-bit float WAV that Jämmer keeps in its Application Support folder.

## Which files can I export?

WAV at 16-bit, 24-bit or 32-bit float, with optional TPDF dither. More formats are planned.

## Will Jämmer change my original files?

No. Edits are stored in the project and played from the originals. Opening a WAV creates a new untitled project, so saving never overwrites the WAV.

## How do I let an AI agent use Jämmer?

When Jämmer starts, the splash shows a line under "For your agent". Click Copy and paste it into Claude or another agent. The agent fetches the guide from Jämmer on your Mac and follows it. The splash is also under Help › Agent Access.

## What can an agent do, and what can't it?

It can open audio, read the document, measure loudness, look at the waveform, edit (every request is one undo step, and a request that fails changes nothing), and export. It can start playback only in a window you can see, and it can never start recording.

## Can I stop the splash from appearing?

Untick "Show at launch" on the splash. Help › Agent Access shows it again.

## How do I uninstall Jämmer?

Quit Jämmer and move it to the Trash. To remove everything else, also delete `~/Library/Application Support/Jammer` (decoded audio), `~/Library/Caches/com.brattoo.jammer` (waveform caches) and `~/Library/Preferences/com.brattoo.jammer.plist`.
