#!/usr/bin/env python3
"""Makes the test files that dialogue-gated loudness is set beside a reference meter with.

    scripts/make-dialogue-test-files.py [folder]      (default $JAMMER_TEST_MEDIA/dialogue)

Everything is made here, on this Mac: the speech is the system's own voices reading an invented text
(`say`), the music and the effects are sums of tones and filtered noise from ffmpeg. Nothing is fetched
and nobody's voice or music is used. Eight files, 48 kHz, stereo, 24 bit, with a manifest that says where
the speech was put in each (so the share of speech is known by construction) and how loud each part was
made (integrated loudness of the part alone, by ffmpeg's ebur128).
"""
import json, os, re, subprocess, sys, tempfile

OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.environ.get("JAMMER_TEST_MEDIA", "."), "dialogue")
SR = 48000
TEXT = [
    "The ferry leaves at a quarter past six, and nobody on the island has ever seen it leave on time. My aunt keeps a list of its excuses on the kitchen wall. Fog, a goat on the ramp, the captain's birthday.",
    "When the bridge was built they promised it would carry the mail. It carries bicycles, two dogs that belong to nobody, and on Thursdays a man who sells brushes. The mail still comes by boat.",
    "I asked her what she wanted for the garden, and she said less of it. So we took out the hedge, and the wind came in, and now she wants the hedge again. That is how most things go here.",
    "There are forty one steps down to the harbour and forty three back up. Everyone has counted. Nobody agrees why. The schoolteacher says it is the tide, which is the sort of thing she says.",
    "He mended clocks for a living and was late for everything. At his funeral the bell rang eleven minutes after the hour, and the whole village agreed it was the kindest thing the church had ever done.",
    "If you take the upper road you will pass a house with a blue door. Do not knock. The door is all there is. The rest of the house went to the mainland in nineteen seventy and never wrote.",
]

def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True)

def ff(*args):
    return run("ffmpeg", "-hide_banner", "-nostdin", "-y", *args)

def seconds(path):
    return float(run("ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path).stdout.strip())

def lufs(path):
    err = ff("-i", path, "-af", "ebur128=peak=true", "-f", "null", "-").stderr
    summary = err[err.rindex("Summary:"):]
    return float(re.search(r"I:\s+(-?[\d.]+) LUFS", summary).group(1)), float(re.search(r"Peak:\s+(-?[\d.]+) dBFS", summary).group(1))

def voices():
    have = run("say", "-v", "?").stdout
    wanted = [v for v in ["Daniel", "Samantha", "Karen", "Moira", "Alex", "Fred"] if re.search(r"^%s\b" % v, have, re.M)]
    return (wanted + [None, None])[:2]

def main():
    os.makedirs(OUT, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix="jammer-dialogue-")
    a, b = voices()
    # The paragraphs, each read by one of two voices, each brought to the same loudness (-27 LUFS alone).
    paras = []
    for i, text in enumerate(TEXT):
        raw, wav = f"{tmp}/p{i}.aiff", f"{tmp}/p{i}.wav"
        voice = a if i % 2 == 0 else b
        run("say", *(["-v", voice] if voice else []), "-o", raw, text)
        ff("-i", raw, "-af", "silenceremove=start_periods=1:start_threshold=-50dB,areverse,silenceremove=start_periods=1:start_threshold=-50dB,areverse", "-ac", "2", "-ar", str(SR), "-c:a", "pcm_s24le", f"{tmp}/t{i}.wav")
        level, _ = lufs(f"{tmp}/t{i}.wav")
        ff("-i", f"{tmp}/t{i}.wav", "-af", f"volume={-27 - level:.2f}dB", "-c:a", "pcm_s24le", wav)
        paras.append((wav, seconds(wav)))
    # Music: a slow chord of tones that swells and falls; effects: bursts of low filtered noise. Each -27 LUFS alone.
    ff("-f", "lavfi", "-i", "sine=f=110:r=48000:d=200", "-f", "lavfi", "-i", "sine=f=164.8:r=48000:d=200", "-f", "lavfi", "-i", "sine=f=220:r=48000:d=200",
       "-f", "lavfi", "-i", "sine=f=277.2:r=48000:d=200", "-f", "lavfi", "-i", "sine=f=659.3:r=48000:d=200",
       "-filter_complex", "[0][1][2][3][4]amix=inputs=5:normalize=0,tremolo=f=0.4:d=0.6,aecho=0.8:0.7:90|140:0.4|0.3,pan=stereo|c0=c0|c1=c0", "-c:a", "pcm_s24le", f"{tmp}/music-raw.wav")
    ff("-f", "lavfi", "-i", "anoisesrc=color=brown:r=48000:d=200:seed=7", "-af", "lowpass=f=900,tremolo=f=1.3:d=0.95,pan=stereo|c0=c0|c1=c0", "-c:a", "pcm_s24le", f"{tmp}/fx-raw.wav")
    for name in ["music", "fx"]:
        level, _ = lufs(f"{tmp}/{name}-raw.wav")
        ff("-i", f"{tmp}/{name}-raw.wav", "-af", f"volume={-27 - level:.2f}dB", "-c:a", "pcm_s24le", f"{tmp}/{name}.wav")

    def build(name, what, speech, speech_db, beds):
        """speech: [(paragraph index, start seconds)]; speech_db: gain on the -27 LUFS paragraphs;
        beds: [(music|fx, gain dB on the -27 LUFS bed, start, end)]; the whole is `total` long."""
        total = max([s + paras[i][1] for i, s in speech] + [e for _, _, _, e in beds]) + 1.0
        inputs, chains, labels = [], [], []
        for k, (i, start) in enumerate(speech):
            inputs += ["-i", paras[i][0]]
            chains.append(f"[{len(labels)}]volume={speech_db}dB,adelay={int(start * 1000)}:all=1[a{len(labels)}]"); labels.append(f"[a{len(labels)}]")
        for bed, db, start, end in beds:
            inputs += ["-i", f"{tmp}/{bed}.wav"]
            n = len(labels)
            chains.append(f"[{n}]atrim=0:{end - start},afade=t=in:d=0.05,afade=t=out:st={end - start - 0.05}:d=0.05,volume={db}dB,adelay={int(start * 1000)}:all=1[a{n}]"); labels.append(f"[a{n}]")
        graph = ";".join(chains) + ";" + "".join(labels) + f"amix=inputs={len(labels)}:normalize=0,apad=whole_dur={total}[out]"
        path = f"{OUT}/{name}.wav"
        ff(*inputs, "-filter_complex", graph, "-map", "[out]", "-t", f"{total}", "-ar", str(SR), "-ac", "2", "-c:a", "pcm_s24le", path)
        placed = [(round(s, 3), round(s + paras[i][1], 3)) for i, s in speech]
        said = sum(e - s for s, e in placed)
        level, peak = lufs(path)
        return {"file": f"{name}.wav", "what": what, "seconds": round(total, 2), "speechPlaced": placed, "speechSeconds": round(said, 2),
                "speechShare": round(said / total, 3), "speechMadeAtLUFS": -27 + speech_db if speech else None,
                "beds": [{"kind": k, "madeAtLUFS": -27 + db, "start": s, "end": e} for k, db, s, e in beds],
                "ffmpegIntegratedLUFS": level, "ffmpegSamplePeakDBFS": peak}

    def row(indices, gap, at=0.5):
        out = []
        for i in indices:
            out.append((i, at)); at += paras[i][1] + gap
        return out, at

    def between(speech, total, kind, db, margin=0.4):
        """Beds in the gaps between the paragraphs (and after the last, to `total`)."""
        out, at = [], 0.0
        for i, s in speech:
            if s - margin - at > 1.0: out.append((kind, db, at + (margin if at else 0), s - margin))
            at = s + paras[i][1]
        if total - at - margin > 1.0: out.append((kind, db, at + margin, total))
        return out

    files = []
    s, end = row(range(6), 0.6)
    files.append(build("d1-speech-alone", "Speech all the way, nothing else.", s, 0, []))
    files.append(build("d2-speech-over-quiet-music", "Speech all the way at -27, music 12 dB under it all the way.", s, 0, [("music", -12, 0, end)]))
    files.append(build("d6-speech-under-music", "Speech all the way at -30, music 8 dB over it all the way.", s, -3, [("music", 5, 0, end)]))
    s, end = row([0, 1, 2, 3], 12.0)
    files.append(build("d3-half-speech-loud-music-between", "Speech about half the time at -27; between the paragraphs, music 10 dB louder.", s, 0, between(s, end, "music", 10)))
    files.append(build("d5-quiet-speech-loud-music-between", "Speech about half the time at -38; between the paragraphs, music at -20.", s, -11, between(s, end, "music", 7)))
    s, end = row([4], 0, at=30.0)
    files.append(build("d4-little-speech-loud-effects", "One paragraph of speech at -27 in a minute and a half; before and after it, effects 7 dB louder.", s, 0, between(s, 90.0, "fx", 7)))
    files.append(build("d7-music-only", "No speech at all: a minute of music at -24.", [], 0, [("music", 3, 0, 60.0)]))
    s, end = row([0, 1, 2, 3, 4, 5], 1.5)
    files.append(build("d8-two-voices-room-tone", "Two voices in turn at -27, with low noise under it all (30 dB under the speech).", s, 0, [("fx", -30, 0, end)]))
    files.sort(key=lambda f: f["file"])
    json.dump({"made": "scripts/make-dialogue-test-files.py", "sampleRate": SR, "voices": [a, b], "files": files}, open(f"{OUT}/manifest.json", "w"), indent=2, ensure_ascii=False)
    for f in files:
        print(f"{f['file']:44s} {f['seconds']:6.1f} s  speech {f['speechShare'] * 100:5.1f} %  whole {f['ffmpegIntegratedLUFS']:6.1f} LUFS  peak {f['ffmpegSamplePeakDBFS']:6.1f} dBFS")

main()
