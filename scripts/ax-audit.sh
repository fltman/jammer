#!/bin/zsh
# Reads Jämmer through the accessibility API with content in place, the way VoiceOver meets it:
# the splash, a document with tracks and a plugin, the assistant with an answer, a plan, a refusal
# and a note, the transcript with words, and every sheet with something in it. After each state the
# app has to be alive (a view that crashes when an assistive technology reads it is the worst
# finding there is) and axaudit lists what has no name.
#
# Empty panels pass an audit that filled ones fail, so the states are made here, not assumed.
#
#   <the-apps>/tools/with-gui-lock.sh jammer -- <the-apps>/tools/run-supervised.sh --timeout 600 -- \
#     env JAMMER_ARGS="-agent.splashAtLaunch YES -linkAnyOpen Flimmer -agentFolder <data>" scripts/with-app.sh scripts/ax-audit.sh <data> [<out> [note]]
#
# <data> holds the material: site/"Episode 7.wav" (speech), site/"Demo song.wav" (music),
# flimmer/Morgon_i_hamnen.fcpxml, packages/Settings.jammer, link/clip.wav. A state whose material
# is missing is skipped and said so. Each state is read twice: axaudit for controls without a name, axread
# for every element including static text. <out> gets one listing per state (every control, named or not).
set -u
data=${1:?the folder with the test material}; out=${2:-${TMPDIR:-/tmp}/jammer-ax-audit}
root="$(cd "$(dirname "$0")/.." && pwd)"; tools="$root/../the-apps/tools"
AX="$tools/axaudit/axaudit"; SM="$tools/safemenu/safemenu"; SP="$tools/safepointer/safepointer"; AR="$tools/axread/axread"
for t in "$AX" "$SM" "$SP" "$AR"; do [[ -x "$t" ]] || { echo "ax-audit: $t is missing (build the series' tools first)." >&2; exit 2; }; done
P=$JAMMER_PID; B=http://127.0.0.1:$JAMMER_PORT/api/v1; H='X-Jammer-Agent: 1'
mkdir -p "$out"; rm -f "$out"/*.txt(N)
unnamed=0; states=0; died=0; unfilled=0; unread=0; manual=0
crashes() { ls ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -c -i "^Jammer\|^Jämmer"; }
crashes0=$(crashes)

# Keys go to the test copy's pid only, each one after a check that it is in front (build/tools/keys); windows are read
# and moved through the accessibility API, aimed at the pid (build/tools/ax). Never System Events, which sends keys to
# whatever app is in front. Built by scripts/build-gui-tools.sh under the build lock.
gt="$root/build/tools"
for t in front keys ax; do [[ -x "$gt/$t" ]] || { echo "$(basename "$0"): build the GUI tools first, under the build lock: scripts/build-gui-tools.sh" >&2; exit 2; }; done
front() { "$gt/front" $P 5 >/dev/null || { echo "$(basename "$0"): the test copy isn't in front; stopping before a key goes elsewhere." >&2; exit 1; }; sleep 0.3; }
key() { "$gt/keys" $P "$@" || { echo "$(basename "$0"): the test copy isn't in front; stopping before a key goes elsewhere." >&2; exit 1; }; sleep 0.3; }
raise() { front; "$gt/ax" $P raise "$1"; sleep 0.4; }
# Menus by their keys in the string catalogue, never by their words: the script works in either language.
t() { "$root/scripts/l10n.sh" "$1"; }
menu() { front; "$SM" --pid $P "$(t $1)" "$(t $2)" >/dev/null || echo "   (menu not pressed: $1 › $2)"; sleep 1; }
can() { "$SM" --pid $P --check "$(t $1)" "$(t $2)" >/dev/null 2>&1; }
post() { curl -s -m 60 -X POST -H "$H" "$@"; }
json() { python3 -c "import json,sys; d=json.load(sys.stdin); $1" 2>/dev/null; }
open_audio() { post -H 'Content-Type: audio/wav' --data-binary @"$1" "$B/documents?name=$2" | json "print(d['document']['id'])"; }
steps() { post -o /dev/null -H 'Content-Type: application/json' -d "{\"steps\":[$2]}" "$B/documents/$1/steps"; }
wait_job() { for _ in {1..120}; do s=$(curl -s "$B/jobs/$1" | json "print(d['job']['status'])"); [[ $s == done || $s == failed ]] && break; sleep 1; done; }
winpos() { "$gt/ax" $P window-frame "$1"; }
# Puts a request in the assistant's field of the window named $1 and sends it. The field gets the
# keyboard from the app's own command (View › Show Assistant / Ask the Assistant, ⌥⌘A), which is also
# how a keyboard or VoiceOver user gets there. Nothing is typed unless the field really has the
# keyboard: keys that miss it land on the timeline, where the space bar is Play.
focused() { "$gt/ax" $P focused-description; }
ask() {
  raise "$1"
  if [[ "$(focused)" != "$(t assistant.field.ax)" ]]; then
    for key in view.askAssistant view.showAssistant; do
      can menu.view $key && { "$SM" --pid $P "$(t menu.view)" "$(t $key)" >/dev/null; break; }
    done
    sleep 0.6
  fi
  local focus="$(focused)"
  if [[ "$focus" != "$(t assistant.field.ax)" ]]; then echo "NOT TYPED the assistant's field isn't focused (focus is on \"$focus\"): \"$2\""; return 1; fi
  key text "$2"; key code 36; sleep ${3:-8}
}

# One state: the listing, the count of unnamed controls, and whether the app is still there. $2 is a text
# that belongs to just this state: unless the read found it, the state was not there and does not count
# (an audit of a panel that never opened passes everything).
audit() {
  states=$(( states + 1 ))
  local file="$out/$(printf '%02d' $states) $1.txt"
  "$AX" --pid $P --all > "$file" 2>&1; local rc=$?
  # Every element, static text and whole text ranges too, as an assistive technology reads them.
  "$AR" $P > "${file%.txt}.read.txt" 2>&1
  if ! tail -1 "${file%.txt}.read.txt" | grep -q '^READ '; then unread=$(( unread + 1 )); echo "UNREAD   $1: the read did not complete"; fi
  if ! kill -0 $P 2>/dev/null; then died=$(( died + 1 )); echo "CRASHED  $1: the app is gone after being read"; return; fi
  # $2 is a catalogue key (the text in the test copy's language, up to its first value), a count's key with
  # its number (import.tracks=2), or a name from the test material.
  local want
  if [[ "$2" == *=* ]]; then want="$("$root/scripts/l10n.sh" "${2%%=*}" "" "$([[ ${2#*=} == 1 ]] && echo one || echo other)")"; want="${want/\%lld/${2#*=}}"
  else want="$("$root/scripts/l10n.sh" "$2" 2>/dev/null || echo "$2")"; want="${want%%\%*}"; fi
  want="${want:0:40}"
  if ! grep -q -F -- "$want" "${file%.txt}.read.txt"; then unfilled=$(( unfilled + 1 )); echo "NOT FILLED $1: \"$want\" was not read, so the state was not there"; fi
  local n=$(grep -c '^UNNAMED' "$file")
  unnamed=$(( unnamed + n ))
  echo "$( (( n > 0 )) && echo 'UNNAMED ' || echo 'ok      ') $1: $(tail -1 "$file") (exit $rc)"
  grep '^UNNAMED\|^WEAK\|^OPAQUE\|^VALUE' "$file" | sed 's/^/           /'
}

speech="$data/site/Episode 7.wav"; music="$data/site/Demo song.wav"
sleep 2; front
# `note` as a third argument: only the assistant's note when a request can't be sent. Start the app with
# a provider chosen and no model (defaults write <bundle id> assistant.source berget), which is that case.
if [[ "${3:-}" == note ]]; then
  key code 53
  DOC=$(open_audio "$speech" Reading); sleep 1; raise Reading
  ask Reading "lower the volume by 3 dB" 3
  audit "assistant with a note that nothing was sent" "Note: Choose one of"
  echo "$states state read; $unnamed controls without a name; the app died $died time(s); $(( $(crashes) - crashes0 )) new crash report(s); $unread read(s) incomplete; $unfilled could not be filled."
  (( died == 0 && unnamed == 0 && unfilled == 0 && unread == 0 && $(crashes) == crashes0 )); exit
fi
audit "splash with the text for an agent" splash.agent.ax
key code 53

# The manual against the menus as they are (English only, where the manual's words are): build/menus lists every
# item with its shortcut, scripts/check-manual.py holds the manual and the FAQ to it, and the kept copy
# (Config/menus-en.txt, which the commit gate reads) must be what the app has. Left out because they change:
# the system's Window menu, Services and what macOS adds to Edit and View (Writing Tools, AutoFill, Dictation, Emoji,
# Full Screen: they differ from Mac to Mac), the recent files, Undo and Redo, whose titles name the step, and the
# order of an unmarked 7.1/7.1.4 file, shown only in a document that has one (scripts/check-manual.py excuses it).
if [[ "${JAMMER_LANG:-en}" == en ]]; then
  [[ -x "$root/build/menus" ]] || xcrun swiftc -O -o "$root/build/menus" "$root/scripts/menus/main.swift" 2>/dev/null
  perl -e 'alarm 60; exec @ARGV' "$root/build/menus" $P 2>/dev/null \
    | grep -v "^Window › [^MZPB]\|^Window › Move\|^Window › Pa\|^Window › Ba\|^Jämmer › Services\|^File › Open Recent › \|^Edit › Undo\|^Edit › Redo\|^Edit › Writing Tools\|^Edit › AutoFill\|^Edit › Start Dictation\|^Edit › Emoji \|^View › Enter Full Screen\|^Audio › Layout › Unmarked File: " > "$out/menus-live.txt"
  if [[ ! -s "$out/menus-live.txt" ]]; then echo "MANUAL   the menus couldn't be read"; manual=1
  else
    if report=$("$root/scripts/check-manual.py" "$out/menus-live.txt"); then echo "ok       $report"; else echo "$report" | sed 's/^/    /'; echo "MANUAL   the manual names menu items or shortcuts the app doesn't have (above)"; manual=1; fi
    if [[ ! -f "$root/Config/menus-en.txt" ]]; then cp "$out/menus-live.txt" "$root/Config/menus-en.txt"; echo "ok       the kept copy of the menus written for the first time (Config/menus-en.txt)"
    elif cmp -s "$out/menus-live.txt" "$root/Config/menus-en.txt"; then echo "ok       the kept copy of the menus is what the app has"
    else diff "$out/menus-live.txt" "$root/Config/menus-en.txt" | head -12 | sed 's/^/    /'; echo "MANUAL   the menus differ from Config/menus-en.txt (above): copy $out/menus-live.txt there if the change is meant"; manual=1; fi
  fi
fi

if [[ -f "$speech" && -f "$music" ]]; then
  DOC=$(open_audio "$speech" Reading); sleep 1
  post -o /dev/null -H 'Content-Type: audio/wav' --data-binary @"$music" "$B/documents/$DOC/tracks?name=Music&gainDB=-6"
  TR=$(curl -s "$B/documents/$DOC/tracks" | json "print(d['tracks'][0]['id'])")
  steps $DOC "{\"op\":\"add_insert\",\"params\":{\"track\":\"$TR\",\"plugin\":\"AULowpass\"}}"
  # Nothing here should play; if something does, it is not at full volume.
  steps $DOC '{"op":"set_volume","params":{"db":-50}}'
  raise Reading
  audit "document with two tracks and a plugin" import.tracks=2

  J=$(post -H 'Content-Type: application/json' -d '{"language":"sv-SE","engine":"apple"}' "$B/documents/$DOC/transcribe" | json "print(d['job']['id'])"); wait_job "$J"
  J=$(post -H 'Content-Type: application/json' -d '{"mode":"by_track"}' "$B/documents/$DOC/diarize" | json "print(d['job']['id'])"); [[ -n "$J" ]] && wait_job "$J"
  raise Reading; can menu.view view.showTranscript && menu menu.view view.showTranscript
  audit "transcript with words and speakers" transcript.title

  ask Reading "what is the loudness?" 10
  audit "assistant with a question and an answer" "$(t assistant.ax.you): what is the loudness"
  ask Reading "delete from 2 to 4 seconds" 10
  audit "assistant with a plan waiting" assistant.plan
  ask Reading "write a poem about the sea" 6
  audit "assistant with a refusal" "$(t assistant.ax.you): write a poem"
  [[ -x "$root/build/winshot" ]] && "$root/build/winshot" --pid $P --only Reading "$out/assistant.png" >/dev/null 2>&1
  echo "         playing: $(curl -s "$B/documents/$DOC" | json "print(d['document']['playing'])")"

  menu menu.audio audio.dehum; sleep 4
  audit "Repair sheet with what it found" restore.mains
  key code 53
  menu menu.audio audio.plugins; sleep 1.5
  audit "Plugins sheet with a plugin on the track" "AULowpass"
  key code 36; key code 53
  menu menu.audio audio.duck; sleep 1
  audit "Duck Under Speech sheet" duck.text
  key code 53
  key cmd k; sleep 1
  key text "fade"; sleep 1
  audit "omnibar with matches" omnibar.ask
  key code 53
else
  echo "skipped  the document states: $speech or $music is missing"
fi

if [[ -f "$data/flimmer/Morgon_i_hamnen.fcpxml" ]]; then
  post -o /dev/null -H 'Content-Type: application/json' -d "{\"path\":\"$data/flimmer/Morgon_i_hamnen.fcpxml\"}" "$B/import/fcpxml"; sleep 1.5
  raise "Morgon i hamnen"
  if can menu.file file.sendToFlimmer; then
    menu menu.file file.sendToFlimmer; sleep 1
    audit "Send to Flimmer sheet" flimmer.mode.mix
    key code 53
  else
    echo "skipped  Send to Flimmer: the menu item isn't there or isn't enabled"
  fi
else
  echo "skipped  Send to Flimmer: $data/flimmer/Morgon_i_hamnen.fcpxml is missing"
fi

if [[ -d "$data/packages/Settings.jammer" ]]; then
  open -b "$(defaults read "$JAMMER_APP/Contents/Info" CFBundleIdentifier)" "$data/packages/Settings.jammer"; sleep 3
  if [[ "$("$gt/ax" $P sheet-count Settings)" == 1 ]]; then
    audit "question about a project's plugin settings" pluginSettings.ask.title.one
    raise Settings; key code 36
  else
    echo "skipped  plugin settings question: not asked (these settings are already allowed in this copy)"
  fi
else
  echo "skipped  plugin settings question: $data/packages/Settings.jammer is missing"
fi

if [[ -f "$data/link/clip.wav" ]]; then
  open -b "$(defaults read "$JAMMER_APP/Contents/Info" CFBundleIdentifier)" "$data/link/clip.wav"; sleep 3
  LINKED=$(curl -s "$B/documents" | json "print(next((x['id'] for x in d['documents'] if x['linkedFile']), ''))")
  if [[ -n "$LINKED" ]]; then
    steps $LINKED '{"op":"gain","params":{"db":-1,"start":0,"end":1}}'; sleep 1
    raise clip; "$gt/ax" $P press-button clip 1; sleep 1.5
    audit "question when a linked document is closed with changes" link.close.title
    key code 53
  else
    echo "skipped  linked document: the file didn't open linked (start with -linkAnyOpen Flimmer)"
  fi
else
  echo "skipped  linked document: $data/link/clip.wav is missing"
fi

echo
new=$(( $(crashes) - crashes0 ))
echo "$states states read; $unnamed controls without a name; the app died $died time(s); $new new crash report(s); $unread read(s) incomplete; $unfilled state(s) could not be filled; the manual against the menus: $( (( manual == 0 )) && echo holds || echo differs). Listings in $out"
(( died == 0 && unnamed == 0 && unfilled == 0 && unread == 0 && new == 0 && manual == 0 ))
