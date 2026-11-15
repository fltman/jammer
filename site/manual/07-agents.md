# Agents

Jämmer serves a guide and a small HTTP API on your Mac, so an AI agent such as Claude can open, measure, edit and export audio in your open windows.

## Connect an agent

1. Open the splash (it appears at launch, or choose **Help › Agent Access…**).
2. Under **For your agent**, click **Copy** (⇧⌘C).
3. Paste the line into your agent. It looks like this:

   `Learn all about Jämmer and how to interact with it: fetch and follow this guide http://127.0.0.1:9003/jammer`

The agent fetches the guide and follows it. **Help › Open the Agent Guide** shows the same guide in your browser.

## What an agent can do

- Open audio you or it provides (as bytes; the API never reads file paths).
- Read the document: tracks, clips, markers, selection and playhead.
- Measure loudness and look at the waveform.
- Edit with the same operations as the menus. One request is one undo step that you can undo with ⌘Z; a request that fails changes nothing.
- Export the result.
- Start and stop playback, but only in a window you can see.

An agent can never start recording.

## Safety

- The API listens only on your Mac (127.0.0.1). Other computers can't reach it.
- Web pages can't use it: requests that come from a browser page are refused, and every change needs a special header.
- Nothing in Jämmer costs money today. If paid features are added, an agent must explicitly allow them per request.

## The port

Jämmer uses port 9003 when it's free, otherwise the first free port from 9301 to 9319. The splash always shows the address in use. Glimmer and Flimmer use their own ports, so all three can run at once.

The full API is described in the [agent guide](../agents.md).
