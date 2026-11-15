# Jämmer

[![Support me on Patreon](https://img.shields.io/badge/Patreon-Support%20my%20work-FF424D?style=flat&logo=patreon&logoColor=white)](https://www.patreon.com/AndersBjarby)

A native macOS audio editor for speech, restoration and post, with on-device AI and a local API that agents can drive. Sibling of Glimmer (images) and Flimmer (video). Free and open source.

**Status:** phase 0, the foundation. Not released.

## What works so far

- A realtime engine in C++20 whose audio-thread code the compiler proves never allocates, locks or blocks.
- Non-destructive editing: cut, copy, paste, delete, crop, gain, fades, markers, with undo. Untouched audio stays bit-exact.
- WAV, RF64/BW64 and AIFF/AIFF-C read and written with their Broadcast Wave (bext), iXML and marker metadata intact. Other formats Apple can decode (MP3, AAC, FLAC, ALAC, CAF) are imported.
- Loudness per ITU-R BS.1770-5 / EBU R 128: integrated, range, momentary, short-term, sample and true peak, tested against the EBU test cases and ffmpeg.
- Waveform overviews for files of many hours.

## Building

Requires macOS 27 on Apple silicon, Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
scripts/test.sh
xcodegen generate
open Jammer.xcodeproj
```

## Licence

MIT. See [LICENSE](LICENSE) and [docs/LICENSES.md](docs/LICENSES.md) for third-party components.
