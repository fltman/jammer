#!/bin/zsh
# Takes the manual's pictures again, each the way its caption describes it, from the test material: one document
# at a time in a window of one size, the picture of Jämmer's own windows only (build/winshot). Writes PNGs to <out>;
# the ones that are kept are made into site/screens/<name>.webp by hand after they have been looked at.
#
#   <the-apps>/tools/with-gui-lock.sh jammer -- <the-apps>/tools/run-supervised.sh --timeout 900 -- \
#     env JAMMER_LANG=en JAMMER_ARGS="-asRelease YES -AppleLocale en_US -agent.splashAtLaunch YES -linkAnyOpen Flimmer -agentFolder <data>" \
#     scripts/with-app.sh scripts/site-shots.sh <data> <out> [name…]
#
# -asRelease leaves off what a debug build has and a release doesn't (automation, CLAP); -AppleLocale en_US gives the
# English site American numbers (the app writes numbers in the Mac's region).
# <data> as for scripts/ax-audit.sh (site/, flimmer/, link/). Names: splash hero history export restore spectrogram
# assistant plugins-au speakers ducking film mixer linked models (all when none is given). Not here: stems and
# soundtrack (they need the separation models), storage and batch (each needs a data folder of its own).
set -u
data=${1:?the folder with the test material}; out=${2:?a folder for the pictures}; shift 2
root="$(cd "$(dirname "$0")/.." && pwd)"; tools="$root/../the-apps/tools"
AX="$tools/axaudit/axaudit"; SM="$tools/safemenu/safemenu"; SP="$tools/safepointer/safepointer"; AR="$tools/axread/axread"
P=$JAMMER_PID; B=http://127.0.0.1:$JAMMER_PORT/api/v1; H='X-Jammer-Agent: 1'; site="$data/site"
mkdir -p "$out"
# Keys go to the test copy's pid only, each one after a check that it is in front (build/tools/keys); windows are read
# and moved through the accessibility API, aimed at the pid (build/tools/ax). Never System Events, which sends keys to
# whatever app is in front. Built by scripts/build-gui-tools.sh under the build lock.
gt="$root/build/tools"
for t in front keys ax; do [[ -x "$gt/$t" ]] || { echo "$(basename "$0"): build the GUI tools first, under the build lock: scripts/build-gui-tools.sh" >&2; exit 2; }; done
front() { "$gt/front" $P 5 >/dev/null || { echo "$(basename "$0"): the test copy isn't in front; stopping before a key goes elsewhere." >&2; exit 1; }; sleep 0.3; }
key() { "$gt/keys" $P "$@" || { echo "$(basename "$0"): the test copy isn't in front; stopping before a key goes elsewhere." >&2; exit 1; }; sleep 0.3; }
t() { "$root/scripts/l10n.sh" "$1"; }
menu() { front; "$SM" --pid $P "$@" >/dev/null || echo "   (menu not pressed: $*)"; sleep 1.2; }
post() { curl -s -m 120 -X POST -H "$H" "$@"; }
json() { python3 -c "import json,sys; d=json.load(sys.stdin); $1" 2>/dev/null; }
open_audio() { post -H 'Content-Type: audio/wav' --data-binary @"$1" "$B/documents?name=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$2")" | json "print(d['document']['id'])"; }
add_track() { post -o /dev/null -H 'Content-Type: audio/wav' --data-binary @"$2" "$B/documents/$1/tracks?name=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$3")${4:-}"; }
steps() { post -H 'Content-Type: application/json' -d "{\"steps\":[$2]}" "$B/documents/$1/steps" | json "print(d.get('error',{}).get('message','') or 'ok')"; }
job() { local J=$(post -H 'Content-Type: application/json' -d "$3" "$B/documents/$1/$2" | json "print(d['job']['id'])")
  for _ in {1..240}; do s=$(curl -s "$B/jobs/$J" | json "print(d['job']['status'])"); [[ $s == done || $s == failed ]] && break; sleep 1; done; echo "   $2: $s"; }
# The window as every picture has it: same place, same size.
size() { front; "$gt/ax" $P set-window-frame "$1" 30 40 ${2:-1480} ${3:-880}; sleep 0.8; key cmd 0; sleep 0.5; }   # and View › Zoom to Fit
raise() { front; "$gt/ax" $P raise "$1"; sleep 0.5; }
shot() { local why; why=$("$root/build/winshot" --pid $P ${2:+--only "$2"} "$out/$1.png" 2>&1 >/dev/null) && echo "   $1.png" || echo "   $1: no picture ($why)"; }
at() { "$AX" --pid $P --all | grep -F -- "$1" | grep -o 'at [0-9-]*,[0-9-]*' | head -1 | sed 's/at //; s/,/ /'; }
# Closes every document window, answering "Delete" (don't save) where it asks.
closeall() {
  for _ in {1..12}; do
    local n=$("$gt/ax" $P window-count); [[ -z "$n" || "$n" == 0 ]] && return
    key code 53; key cmd w; sleep 1
    local xy=($(at "id=DontSaveButton"))
    (( ${#xy} == 2 )) && { "$SP" --pid $P click $(( ${xy[1]} + 20 )) $(( ${xy[2]} + 8 )) >/dev/null; sleep 1; }
  done
}

pic_splash() { front; sleep 3; shot splash; key code 53; sleep 0.5; }
pic_hero() {
  local D=$(open_audio "$site/Episode 7.wav" "Episode 7"); sleep 1; size "Episode 7"
  steps $D '{"op":"add_marker","params":{"at":0.1,"name":"Intro"}},{"op":"add_marker","params":{"at":10.4,"name":"Rummet"}},{"op":"add_marker","params":{"at":18.8,"name":"Klippning"}}' >/dev/null
  job $D transcribe '{"language":"sv-SE","engine":"apple"}'
  steps $D '{"op":"select","params":{"start":5.2,"end":9.6}}' >/dev/null; sleep 1.5
  shot hero "Episode 7"; closeall
}
pic_history() {
  local D=$(open_audio "$site/Episode 7.wav" "Episode 7"); sleep 1; size "Episode 7"
  # Four changes, two undone, and a new one: the two undone stay in the list as a side branch.
  steps $D '{"op":"gain","params":{"db":-3}}' >/dev/null
  steps $D '{"op":"select","params":{"start":0,"end":1}},{"op":"fade_in"}' >/dev/null
  steps $D '{"op":"select","params":{"start":24,"end":25}},{"op":"fade_out"}' >/dev/null
  steps $D '{"op":"gain","params":{"db":2}}' >/dev/null
  post -o /dev/null "$B/documents/$D/undo"; post -o /dev/null "$B/documents/$D/undo"
  steps $D '{"op":"select","params":{"start":12,"end":12.5}},{"op":"silence"}' >/dev/null
  menu "$(t menu.view)" "$(t view.history)"; sleep 1
  shot history; closeall
}
pic_export() {
  local D=$(open_audio "$site/Episode 7.wav" "Episode 7"); sleep 1; size "Episode 7"
  steps $D '{"op":"add_marker","params":{"at":0.1,"name":"Intro"}},{"op":"add_marker","params":{"at":18.8,"name":"Editing"}}' >/dev/null
  menu "$(t menu.file)" "$(t file.export)"; sleep 1.5
  local xy=($(at 'PopUpButton “Format'))
  if (( ${#xy} == 2 )); then "$SP" --pid $P click $(( ${xy[1]} + 30 )) $(( ${xy[2]} + 8 )) >/dev/null; sleep 0.8; key text "MP3"; key code 36; sleep 0.8; fi
  shot export "Episode 7"; key code 53; closeall
}
pic_restore() {
  local D=$(open_audio "$site/Kitchen take.wav" "Kitchen take"); sleep 1; size "Kitchen take"
  menu "$(t menu.audio)" "$(t audio.dehum)"; sleep 4
  shot restore "Kitchen take"; key code 53; closeall
}
pic_spectrogram() {
  local D=$(open_audio "$site/Phone rang.wav" "Phone rang"); sleep 1; size "Phone rang"
  menu "$(t menu.view)" "$(t view.showSpectrogram)"; sleep 1
  steps $D '{"op":"select","params":{"start":6,"end":10.4}}' >/dev/null
  menu "$(t menu.view)" "$(t view.zoomToSelection)"; steps $D '{"op":"deselect"}' >/dev/null; sleep 1
  # A box round the two ring tones (7.98–8.45 s, about 1.6–4.3 kHz), dragged as a user would: the lane runs from the
  # window's left edge to the assistant (320 pt) and from under the ruler (y 115) to over the transcript (160 pt).
  local w=1160 top=$(( 40 + 115 )) h=$(( 880 - 115 - 200 ))
  "$SP" --pid $P drag $(( 30 + w * 198 / 440 )) $(( top + h * 23 / 100 )) $(( 30 + w * 245 / 440 )) $(( top + h * 39 / 100 )) >/dev/null; sleep 1
  shot spectrogram "Phone rang"; closeall
}
pic_assistant() {
  local D=$(open_audio "$site/Episode 7.wav" "Episode 7"); sleep 1; size "Episode 7"
  key cmd+opt a; sleep 0.8   # the field gets the keyboard (View › Show/Ask the Assistant)
  key text "remove the silences longer than a second"; key code 36; sleep 12
  shot assistant "Episode 7"; closeall
}
pic_plugins-au() {
  local D=$(open_audio "$site/Episode 7.wav" "Episode 7"); sleep 1; size "Episode 7"
  local T=$(curl -s "$B/documents/$D/tracks" | json "print(d['tracks'][0]['id'])")
  for p in aufx/lmtr/appl aufx/nbeq/appl aufx/dcmp/appl; do steps $D "{\"op\":\"add_insert\",\"params\":{\"track\":\"$T\",\"plugin\":\"$p\"}}" >/dev/null; done
  menu "$(t menu.audio)" "$(t audio.plugins)"; sleep 1.5
  shot plugins-au "Episode 7"; key code 36; sleep 0.5; closeall   # Return: Done
}
pic_speakers() {
  local D=$(open_audio "$site/Flo.wav" "Interview"); sleep 1
  add_track $D "$site/Daniel.wav" Daniel; sleep 1; size "Interview"
  local T=$(curl -s "$B/documents/$D/tracks" | json "print(d['tracks'][0]['id'])")
  steps $D "{\"op\":\"set_track\",\"params\":{\"track\":\"$T\",\"name\":\"Flo\"}}" >/dev/null
  job $D transcribe '{"language":"en-US","engine":"apple"}'
  # Each microphone hears the other: the bleed words are dropped once the speakers are known (one per track).
  job $D diarize '{}'; sleep 1.5
  shot speakers "Interview"; closeall
}
pic_ducking() {
  local D=$(open_audio "$site/Episode 7.wav" "Episode 7"); sleep 1
  add_track $D "$site/Music bed.wav" "Music bed"; sleep 1; size "Episode 7"
  local M=$(curl -s "$B/documents/$D/tracks" | json "print(d['tracks'][1]['id'])")
  steps $D "{\"op\":\"duck\",\"params\":{\"tracks\":[\"$M\"]}}"; sleep 1.5
  shot ducking "Episode 7"; closeall
}
pic_film() {
  post -o /dev/null -H 'Content-Type: application/json' -d "{\"path\":\"$data/flimmer/Morgon_i_hamnen.fcpxml\"}" "$B/import/fcpxml"; sleep 2
  size "Morgon"; shot film "Morgon"; closeall
}
pic_mixer() {
  local D=$(open_audio "$site/Episode 7.wav" "Episode 7"); sleep 1
  add_track $D "$site/Music bed.wav" "Music"; sleep 1; size "Episode 7"
  local ids=$(curl -s "$B/documents/$D/tracks" | json "print(','.join('\"%s\"' % t['id'] for t in d['tracks']))")
  steps $D "{\"op\":\"add_vca\",\"params\":{\"name\":\"Everything\",\"members\":[$ids]}}" >/dev/null
  local V=$(curl -s "$B/documents/$D/mixer" | json "print(d['mixer']['vcas'][0]['id'])")
  steps $D "{\"op\":\"set_vca\",\"params\":{\"vca\":\"$V\",\"gainDB\":-6}}"
  menu "$(t menu.audio)" "$(t audio.mixer)"; sleep 1.5
  front; "$gt/ax" $P set-window-frame Mixer 50 120 1400 520; sleep 1
  shot mixer "Mixer"; key cmd w; closeall
}
pic_linked() {
  open -b "$(defaults read "$JAMMER_APP/Contents/Info" CFBundleIdentifier)" "$data/link/clip.wav"; sleep 3
  size "clip"; shot linked "clip"; closeall
}
pic_models() {
  closeall
  menu "Jämmer" "$(t app.settings)"; sleep 1.5
  local xy=($(at "$(t settings.models)"))
  (( ${#xy} == 2 )) && { "$SP" --pid $P click $(( ${xy[1]} + 10 )) $(( ${xy[2]} + 8 )) >/dev/null; sleep 1.5; }
  shot models; key cmd w
}

names=("$@"); (( ${#names} )) || names=(splash hero history export restore spectrogram assistant plugins-au speakers ducking film mixer linked models)
for n in $names; do echo "-- $n"; pic_$n; done
