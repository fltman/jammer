# Exporting

**File › Export Audio…** (⇧⌘E) renders the project to a WAV file.

| Option | Choices |
|---|---|
| Format | WAV 16-bit, WAV 24-bit (default), WAV 32-bit float |
| Dither (TPDF) | Adds triangular dither when writing 16 or 24 bits. Leave it off for bit-exact copies of untouched audio. |
| Selection only | Exports just the selection (on by default when there is one) |

Exports that grow past 4 GB are written as RF64 automatically.

When you export from the start of the project, Jämmer carries over the first source file's Broadcast Wave description, timecode and iXML, adds a line to the coding history, and writes your markers as cue points. The bext loudness fields are left empty rather than copied, since the audio may have changed.

The status bar shows the progress and the file name when it's done.
