# Overdub

Overdub says new words in a speaker's own voice: a word that was misspoken, a name said wrong, a sentence that needs a change. The voice is cloned at ElevenLabs with your own ElevenLabs key, and the new words take the place of the old ones in the timeline.

It is built from ElevenLabs' documentation and has not yet been tried with a real request.

## What you need

- An ElevenLabs account and its API key, entered under **Jämmer › Settings… › Paid Services**. The key is kept in your Mac's Keychain. It is yours alone: don't share it. Every request made with it is your account's, and ElevenLabs charges it by its own price list. Jämmer doesn't know that price, and says so before each request.
- A transcript of the recording (**Transcribe** in the transcript area).
- The consent of the person whose voice it is, said in the recording itself.

## Consent comes first

A voice is cloned only from someone who has agreed to it. Before anything leaves your Mac:

1. The person whose voice it is says this sentence in the recording: “I consent to my voice being cloned with ElevenLabs to edit this recording.” (In a Swedish recording: “Jag samtycker till att min röst klonas med ElevenLabs för att redigera den här inspelningen.”)
2. Select where it is said, and choose **Speech › Clone Voice…**.
3. Say whose voice it is: your own, or someone who has given you explicit, informed consent. Confirm that the person is 18 or older. The window shows ElevenLabs' terms for cloned voices in short.

Jämmer listens for the sentence in the transcript where you selected. If the sentence isn't there, nothing is sent. Then up to two minutes of the same speaker's speech, taken from the recording, go to ElevenLabs, and the voice is kept in the document together with this record: whose it is, by whose word, and where the consent was said.

## Saying new words

Select the words to replace, then choose **Speech › Overdub…**. Pick the voice, write what it should say (the selected words are filled in to start from), and send. The new speech takes the selection's place, and what follows moves with its length, as a cut does. It is one undo step.

The new clip is marked as made with a cloned voice, and its track shows **Cloned voice**. The mark stays in the document, follows the sound through cuts, mixes and repairs, and an exported WAV (or one sent to Flimmer) says so in its metadata. A file from another app that says it contains speech made with a cloned voice is marked the same way when it comes in. ElevenLabs puts an inaudible watermark in what it makes. Jämmer keeps ElevenLabs' file exactly as it came, watermark included, and plays a decoded copy.

While a clone or an Overdub is out, the status bar shows it with a stop button. Once sent, ElevenLabs may already be working on it and may charge for it even if you stop, and Jämmer says so. A stopped Overdub puts nothing in the document. A clone that ElevenLabs finished anyway is always kept in the document's list, so that you can delete it from Jämmer; one that was stopped before Jämmer heard back may still be in your ElevenLabs account, and Jämmer tells you to look there. (A paid job that can be canceled, such as transcribing at OpenAI, also says after a cancel that the service may have charged, and Jämmer doesn't fetch anything it still sends back.)

## Deleting a voice

**Speech › Delete Cloned Voice…** deletes the voice at ElevenLabs. The record of consent stays in the document, and speech already made with the voice stays marked.

## For agents

`list_voices`, `clone_voice`, `overdub` and `delete_voice` work the same way. `clone_voice` needs `attest` (`own` or `owner_consent`), `adult`, where the consent sentence is said (`consent`) and the speaker's pieces (`samples`). Like every paid step, it needs `allowPaid` and `allowUnknownPrice`. An agent should never clone a voice without its owner's consent.
