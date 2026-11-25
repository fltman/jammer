# The assistant

![The assistant panel with a request, the plan it made, what the plan will do, and Run and Cancel](../screens/assistant.webp)

Ask Jämmer in Swedish or English and it does the editing: "ta bort alla ehm och tystnader längre än en sekund", "normalize to −16 LUFS", "ta bort brummet på talare 2", "fade in the first two seconds".

## Open it

**View › Show Assistant** (⌥⌘A) opens the chat beside the timeline with the cursor in its field; type a request and press Return. You can also type a request in the omnibar at the bottom of the window (⌘K) and press ⌘Return (chapter 8). With the chat open, ⌥⌘A takes you to the field from anywhere in the window (the menu item reads **Ask the Assistant**), and from the field it hides the chat (**Hide Assistant**).

## What happens

- The assistant turns your request into a plan of Jämmer's own commands: the same ones as the menus and the agent API, so it can only do what Jämmer can do.
- A plan that removes or replaces audio (deleting, cutting, removing filler words or pauses, repairs, echo) is shown first, with **Run** and **Cancel**. Other plans, such as changing the level or measuring loudness, run straight away.
- A plan is also shown first when it would change the document in a way your request didn't name: ask for a poem and get a plan that sets the tempo, and Jämmer says that you didn't ask for it and does nothing until you click **Run**. Measuring never needs a yes.
- Under **What it does**, Jämmer says in numbers what the plan will do, worked out from the steps themselves rather than from the assistant's words: "Deletes 2.0 s of 3:12 at the end", "Removes 14 words (6.2 s)". If a plan would remove more than a fifth of the document, or deletes audio although you didn't ask to remove anything, it's outlined in orange with a warning, and Return cancels instead of running.
- All the editing in a plan is **one undo step**. Transcribing and repairs run as their own steps in between (they take a moment; the status bar shows the progress).
- Removing filler words needs a transcript; the assistant transcribes first if there isn't one.
- While it thinks or runs a plan, the panel says which, with **Stop** (Esc). Stop ends the planning or the plan and only the jobs that plan started; what the plan had already done stays and can be undone. A new request first cancels a plan that is waiting for **Run**.
- Questions like "how loud is it?" are answered in the chat. A measured value is always written by Jämmer from the measurement itself: the assistant chooses what to measure, and its own sentence isn't shown.
- The assistant's own sentence is only shown when everything it planned can run. If a step was left out (a name it couldn't find, a value it didn't give), Jämmer says what was left out and why in its own words, so that you never read "removed" above something that wasn't.
- A delivery target you name ("master it for Spotify") is that target's loudness preset, not a level of the assistant's choosing, and the plan is shown with the preset and its targets before it runs; say the level yourself and it is yours.
- **The assistant doesn't make figures up.** Every figure with a unit in its answer is checked before you see it, and a sentence with a figure that nothing backs up is taken out; a line under the answer then says that a sentence was held back. A figure is backed up when it is:
  - in your request, in digits or in words ("two seconds", "en halv sekund");
  - in what the assistant was told about the document (its length, the playhead, the selection, the master limiter's ceiling), or among the values of the plan it shows you;
  - a figure from the description of one of Jämmer's commands (a default, a range), but only in a sentence that is about that command, and never in a sentence that says something about your own sound;
  - or one of these, which Jämmer works out itself from the first two before it reads the answer: the selection's length; what is left after the playhead and after the selection; half the document and half the selection; for two times in your request, their sum and their difference; any of these times said in milliseconds, seconds or minutes; and the difference between two levels that were given ("from −23 to −16 LUFS" is 7 dB). The answer's figure has to be that value as a person would round it, not something near it.
  - Prices, sizes on disk, how long something will take, and anything about a service are never worked out: such a figure stands only when your request or the document gave it. 0, 1 and a count of the plan's steps are always allowed.
- The answer follows the language of your request, Swedish or English.

## Which model

Click the gear in the assistant's header.

| Choice | What it means |
|---|---|
| **On this Mac** (default) | Apple's on-device model. Free, private, works offline; nothing leaves the Mac. Understands Swedish and English (and Danish, Norwegian, German and more). |
| **Ollama on this Mac** | A model you have installed in [Ollama](https://ollama.com), when Ollama is running. Free and private: nothing leaves the Mac, and Jämmer never downloads a model. Only models that can call tools are listed. It is slower than the on-device model (about 8 seconds a request in our test) and the model takes about 6 GB of memory while it runs. Tried with `qwen3:8b` on one Mac, where it picked the right actions at least as often as the on-device model; other models are marked "not evaluated with Jämmer", and you can evaluate one yourself with `scripts/eval-assistant.sh` from the source. |
| **OpenRouter**, **Berget**, **Grunden**, **OpenAI**, **Anthropic**, **xAI**, **Google** | A model of your choice at one of these services, with your own key. The key is kept in your Keychain, one per service. The models and their prices are read from the service's own list; a model that can't call tools is marked and can't be used. The first request to a service asks first and shows the approximate price from the service's own list; tick **Don't ask again** to send its later text requests without the question. Where the list gives no price for the model, the question says so and **Send** stays gray until you tick that you want to go on without one, which also stops the question for that service. Both are per service and taken back under **Jämmer › Settings › Paid Services**. Transcription, voices and Overdub always ask. Only your request and a short description of the document (length, tracks, the start of the transcript) are sent, never the audio. Berget and Grunden run in Sweden by their own account. **All seven are built from the services' documentation and none has yet answered a real request from Jämmer**; the line under the key field says so for each until it has. If one answers with an error, Jämmer shows the error as it came. |

## Good to know

- The mixer: the assistant can make a bus or a VCA group, set a bus's or a group's level, mute a bus, set the master's gain and its limiter ("put a limiter on the master at −1 dBTP"), and freeze or unfreeze a track or a bus ("freeze the Music bus"). Tracks, buses and groups are named by their names. With the model on your Mac these were tried in English and Swedish; sends, muting a group and removing a group it usually doesn't manage, and then it does nothing and says what it left out.

- Speakers are tracks: "talare 2" or "track 2" means the second track.
- If a request is unclear, the assistant asks instead of guessing.
- How well the on-device model picks the right commands was measured on a fixed set of requests; see the project's `docs/ASSISTANT.md`. It's good at single tasks; with several tasks in one sentence it sometimes does only one, so check the plan, or ask for one thing at a time.
- Measured on the same requests on 16 November 2026: the on-device model planned 17 of 18 everyday requests right, and 21 of 24 and 17 of 23 on two harder sets. A local model in Ollama (qwen3:8b) planned 18 of 18, and 19 of 24 and 20 of 23: it follows more kinds of requests when they are worded unusually or hold several tasks, at the price of about 6 GB of memory while it is loaded and a few seconds more per request. Neither is right every time, which is why a plan that removes audio, or does something you didn't ask for, waits for your yes.
- Measured again on 19 November 2026 on all six sets (18 everyday requests and five harder sets of 24, 23, 29, 9 and 15): the on-device model planned 17, 21, 18, 21, 7 and 12 right, 96 of 118 in all.
- A track can be named by its name as well as its number ("the Music track"). When the assistant names a track the document doesn't have, it is asked once more with the list of tracks. Asking the on-device model to lower the music under speech still mostly fails: it names the wrong track or puts the amount where a track goes, and Jämmer says so and changes nothing. Use **Audio › Duck Under Speech…** for that.
