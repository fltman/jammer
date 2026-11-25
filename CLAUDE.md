# Jammer (visible name: Jämmer)

Native macOS audio editor in Swift 6 with a C++20 realtime core. Third app in the series with Glimmer (images) and Flimmer (video). Free and open source (MIT).

## Build and test

```sh
scripts/test.sh                      # package tests (engine, core, agent API)
xcodegen generate && open Jammer.xcodeproj   # the app; the .xcodeproj is generated, not committed
```

- macOS 27, arm64 only. Xcode 27.
- `Packages/JammerKit` holds everything testable: `JammerEngine` (C++), `JammerCore`, `JammerAudio`, `JammerAgent`. `App/` is the AppKit app.

## Rules that are expensive to break

- **Nothing in Swift runs on the audio thread.** The device callback is `jm_engine_au_render` in C++. Audio-thread functions carry `JM_NONBLOCKING`; the build uses `-Werror=function-effects`, so an allocation, lock or blocking call reachable from them fails compilation. Prove a new guard works by planting a violation once.
- **Bit-exact by default.** 0 dB gain is exactly 1.0; untouched clips must null against the source. Keep the null tests green.
- **Edits are pure value changes on `Project`.** Undo is the previous value. No edit touches source files.
- **Metadata is ours.** AudioToolbox drops bext/iXML/cue on conversion, so WAV/RF64/AIFF chunks go through `AudioFileReader`/`WAVWriter`, which keep foreign chunks.
- **Calibrate against real references.** Loudness is tested against EBU Tech 3341/3342 cases and ffmpeg's ebur128. New meters/analysers need a known-good reference before their numbers are shown.
- **One schema for menu, ⌘K, App Intents and the agent API.** Operations live in `JammerAgent/Operations.swift`; the guide and `GET /api/v1/operations` are generated from it. The guide only describes what works.

## Series conventions

- Technical identifiers are ASCII (`Jammer`, `com.brattoo.jammer`, `/jammer`, the build product and every script path). "Jämmer" in `CFBundleDisplayName` and text, and in what is distributed: the app is `Jämmer.app` in `Jämmer-<version>.zip` (Anders, 2026-11-25; renamed when the archive is made, after signing, in NFC).
- Agent API: 127.0.0.1 only, port 9003, then 9301–9319. Splash and `/api/v1/status` show the real port. POST needs `X-Jammer-Agent: 1`; `Origin` → 403; paid steps need `allowPaid: true` (else 402). Errors `{error:{code,message}}`; a failed step is 422 `step_failed` with `step`.
- The agent may start playback only in a visible window and never start recording.
- Domain jammer.brattoo.com (homepage, future appcast, OpenRouter Referer). The site lives in `site/` in English.
- No server we run: model sources and cloud endpoints are user configuration; the user's own keys (OpenRouter, Hugging Face) go in the Keychain. Sparkle's appcast is the only exception.
- Licences: no GPL in the bundle, LGPL only dynamically linked, no non-commercial models; CC-BY needs attribution. Record every dependency and model in `docs/LICENSES.md` before it ships.
- Never commit secrets, `.env` or private paths. Commit locally; don't push until release.
- GUI tests share the screen with Glimmer/Flimmer: take `mkdir /tmp/gui-test.lock && echo jammer > /tmp/gui-test.lock/owner` before synthetic clicks/keys, `rm -rf /tmp/gui-test.lock` right after. Play test audio quietly or render to file.
