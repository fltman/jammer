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
#     env JAMMER_ARGS="-forceAgentSplash YES -linkAnyOpen Flimmer -agentFolder <data>" scripts/with-app.sh scripts/ax-audit.sh <data> [<out> [note]]
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
unnamed=0; states=0; died=0; unfilled=0; unread=0
crashes() { ls ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -c -i "^Jammer\|^Jämmer"; }
crashes0=$(crashes)

osa() { osascript -e "tell application \"System Events\" to tell (first process whose unix id is $P) to $1" 2>/dev/null; }
front() { osa 'set frontmost to true' >/dev/null; sleep 0.3; }
key() { front; osascript -e "tell application \"System Events\" to $1" >/dev/null 2>&1; sleep 0.3; }
raise() { front; osa "perform action \"AXRaise\" of (first window whose name contains \"$1\")" >/dev/null; sleep 0.4; }
menu() { front; "$SM" --pid $P "$@" >/dev/null || echo "   (menu not pressed: $*)"; sleep 1; }
post() { curl -s -m 60 -X POST -H "$H" "$@"; }
json() { python3 -c "import json,sys; d=json.load(sys.stdin); $1" 2>/dev/null; }
open_audio() { post -H 'Content-Type: audio/wav' --data-binary @"$1" "$B/documents?name=$2" | json "print(d['document']['id'])"; }
steps() { post -o /dev/null -H 'Content-Type: application/json' -d "{\"steps\":[$2]}" "$B/documents/$1/steps"; }
wait_job() { for _ in {1..120}; do s=$(curl -s "$B/jobs/$1" | json "print(d['job']['status'])"); [[ $s == done || $s == failed ]] && break; sleep 1; done; }
winpos() { osa "get {position, size} of (first window whose name contains \"$1\")" | tr -d ','; }
# Puts a request in the assistant's field of the window named $1 and sends it. Focus is given through the
# accessibility API (a click can be refused: a notification banner may cover the spot), with a click as
# the second try, and nothing is typed unless the field really has the keyboard: keys that miss it land
# on the timeline, where the space bar is Play.
focused() { osa 'get value of attribute "AXDescription" of (value of attribute "AXFocusedUIElement")'; }
ask() {
  front
  osascript >/dev/null 2>&1 <<EOF
tell application "System Events" to tell (first process whose unix id is $P)
  repeat with e in (entire contents of (first window whose name contains "$1"))
    try
      set el to contents of e
      if (value of attribute "AXDescription" of el) is "Ask the assistant" then
        set value of attribute "AXFocused" of el to true
        exit repeat
      end if
    end try
  end repeat
end tell
EOF
  sleep 0.4
  if [[ "$(focused)" != "Ask the assistant" ]]; then
    # Out of the way of whatever covers the spot (a notification banner sits at the screen's right edge).
    osa "set position of (first window whose name contains \"$1\") to {20, 40}" >/dev/null
    osa "set size of (first window whose name contains \"$1\") to {1000, 680}" >/dev/null; sleep 0.5
    local pos=($(winpos "$1"))
    # Twice: the first click on a window that isn't key only makes it key.
    for _ in 1 2; do "$SP" --pid $P click $(( ${pos[1]} + ${pos[3]} - 150 )) $(( ${pos[2]} + ${pos[4]} - 18 )) >/dev/null; sleep 0.4; done
  fi
  local focus="$(focused)"
  if [[ "$focus" != "Ask the assistant" ]]; then echo "NOT TYPED the assistant's field isn't focused (focus is on \"$focus\"): \"$2\""; return 1; fi
  key "keystroke \"$2\""; key 'key code 36'; sleep ${3:-8}
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
  if ! grep -q -- "$2" "${file%.txt}.read.txt"; then unfilled=$(( unfilled + 1 )); echo "NOT FILLED $1: \"$2\" was not read, so the state was not there"; fi
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
  key 'key code 53'
  DOC=$(open_audio "$speech" Reading); sleep 1; raise Reading
  ask Reading "lower the volume by 3 dB" 3
  audit "assistant with a note that nothing was sent" "Nothing was sent"
  echo "$states state read; $unnamed controls without a name; the app died $died time(s); $(( $(crashes) - crashes0 )) new crash report(s); $unread read(s) incomplete; $unfilled could not be filled."
  (( died == 0 && unnamed == 0 && unfilled == 0 && unread == 0 && $(crashes) == crashes0 )); exit
fi
audit "splash with the text for an agent" "Text for your agent: "
key 'key code 53'

if [[ -f "$speech" && -f "$music" ]]; then
  DOC=$(open_audio "$speech" Reading); sleep 1
  post -o /dev/null -H 'Content-Type: audio/wav' --data-binary @"$music" "$B/documents/$DOC/tracks?name=Music&gainDB=-6"
  TR=$(curl -s "$B/documents/$DOC/tracks" | json "print(d['tracks'][0]['id'])")
  steps $DOC "{\"op\":\"add_insert\",\"params\":{\"track\":\"$TR\",\"plugin\":\"AULowpass\"}}"
  # Nothing here should play; if something does, it is not at full volume.
  steps $DOC '{"op":"set_volume","params":{"db":-50}}'
  raise Reading
  audit "document with two tracks and a plugin" "2 tracks"

  J=$(post -H 'Content-Type: application/json' -d '{"language":"sv-SE","engine":"apple"}' "$B/documents/$DOC/transcribe" | json "print(d['job']['id'])"); wait_job "$J"
  J=$(post -H 'Content-Type: application/json' -d '{"mode":"by_track"}' "$B/documents/$DOC/diarize" | json "print(d['job']['id'])"); [[ -n "$J" ]] && wait_job "$J"
  raise Reading; "$SM" --pid $P --check View "Show Transcript" >/dev/null 2>&1 && menu View "Show Transcript"
  audit "transcript with words and speakers" "Description=Transcript  Value=."

  ask Reading "what is the loudness?" 10
  audit "assistant with a question and an answer" "You: what is the loudness"
  ask Reading "delete from 2 to 4 seconds" 10
  audit "assistant with a plan waiting" "The plan"
  ask Reading "write a poem about the sea" 6
  audit "assistant with a refusal" "You: write a poem"
  [[ -x "$root/build/winshot" ]] && "$root/build/winshot" --pid $P --only Reading "$out/assistant.png" >/dev/null 2>&1
  echo "         playing: $(curl -s "$B/documents/$DOC" | json "print(d['document']['playing'])")"

  menu Audio "Remove Hum…"; sleep 4
  audit "Repair sheet with what it found" "Value=Mains"
  key 'key code 53'
  menu Audio "Plugins…"; sleep 1.5
  audit "Plugins sheet with a plugin on the track" "AULowpass"
  key 'key code 36'; key 'key code 53'
  menu Audio "Duck Under Speech…"; sleep 1
  audit "Duck Under Speech sheet" "Tick the tracks to lower"
  key 'key code 53'
  key 'keystroke "k" using {command down}'; sleep 1
  audit "command palette" "Ask the Assistant…"
  key 'key code 53'
else
  echo "skipped  the document states: $speech or $music is missing"
fi

if [[ -f "$data/flimmer/Morgon_i_hamnen.fcpxml" ]]; then
  post -o /dev/null -H 'Content-Type: application/json' -d "{\"path\":\"$data/flimmer/Morgon_i_hamnen.fcpxml\"}" "$B/import/fcpxml"; sleep 1.5
  raise "Morgon i hamnen"
  if "$SM" --pid $P --check File "Send to Flimmer…" >/dev/null 2>&1; then
    menu File "Send to Flimmer…"; sleep 1
    audit "Send to Flimmer sheet" "The whole mix as one clip"
    key 'key code 53'
  else
    echo "skipped  Send to Flimmer: the menu item isn't there or isn't enabled"
  fi
else
  echo "skipped  Send to Flimmer: $data/flimmer/Morgon_i_hamnen.fcpxml is missing"
fi

if [[ -d "$data/packages/Settings.jammer" ]]; then
  open -b "$(defaults read "$JAMMER_APP/Contents/Info" CFBundleIdentifier)" "$data/packages/Settings.jammer"; sleep 3
  if [[ "$(osa 'get count of sheets of (first window whose name contains "Settings")')" == 1 ]]; then
    audit "question about a project's plugin settings" "wants to load settings"
    raise Settings; key 'key code 36'
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
    raise clip; osa 'click button 1 of (first window whose name contains "clip")' >/dev/null; sleep 1.5
    audit "question when a linked document is closed with changes" "Save your changes back"
    key 'key code 53'
  else
    echo "skipped  linked document: the file didn't open linked (start with -linkAnyOpen Flimmer)"
  fi
else
  echo "skipped  linked document: $data/link/clip.wav is missing"
fi

echo
new=$(( $(crashes) - crashes0 ))
echo "$states states read; $unnamed controls without a name; the app died $died time(s); $new new crash report(s); $unread read(s) incomplete; $unfilled state(s) could not be filled. Listings in $out"
(( died == 0 && unnamed == 0 && unfilled == 0 && unread == 0 && new == 0 ))
