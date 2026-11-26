#!/bin/zsh
# Starts the debug build of Jammer for a GUI check, runs a command with JAMMER_PORT set,
# and quits that instance on exit. Must run under the series' shared GUI lock, owned by
# "jammer" (wrap it in the lock tool; this script refuses otherwise).
#   <lock tool> jammer -- scripts/with-app.sh <command> [args…]
# JAMMER_PID, JAMMER_PORT and JAMMER_APP (the .app) are set for the command.
# Paid providers can't be reached: OPENROUTER_API_KEY is removed from the app's environment.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(cat /tmp/gui-test.lock/owner 2>/dev/null)" == "jammer" ]] || { echo "with-app: the GUI lock isn't held by jammer; not starting." >&2; exit 75; }
# A check that takes the foreground starts only when Anders isn't using the Mac (the series' rule): his
# typing makes a check fail, and a check steals his window. Idle for 90 s or more: go. Otherwise wait
# (JAMMER_IDLE_WAIT seconds, 600 by default) and, if he is still at it, give up with exit 76: "postponed,
# Anders at the Mac", which is not a run against a budget. The seconds are printed beside the run. A locked screen
# (after a long idle) gives exit 78, "postponed, the screen is locked", also not a try; 77 is a real failure to
# come to the front (another app keeps it).
idle="$root/../the-apps/tools/user-idle.sh"
if [[ -x "$idle" && -z "${JAMMER_IDLE_SKIP:-}" ]]; then
  waited=0
  until "$idle" --atleast 90 >/dev/null 2>&1; do
    (( waited >= ${JAMMER_IDLE_WAIT:-600} )) && { echo "with-app: postponed, Anders at the Mac (idle $("$idle" 2>/dev/null) s after waiting $waited s)." >&2; exit 76; }
    sleep 10; waited=$((waited + 10))
  done
  echo "with-app: the Mac has been idle $("$idle" 2>/dev/null) s; starting." >&2
fi
# JAMMER_APP_BUNDLE: another copy of the debug app to start (e.g. one re-signed with the
# hardened runtime, to see what a release build will refuse).
app="${JAMMER_APP_BUNDLE:-$root/build/dd/Build/Products/Debug/Jammer.app}/Contents/MacOS/Jammer"
[[ -x "$app" ]] || { echo "with-app: build the app first (xcodebuild … -derivedDataPath build/dd)." >&2; exit 1; }
# JAMMER_ARGS: extra launch arguments, e.g. "-linkAnyOpen Flimmer" (debug builds).
# JAMMER_LOG: a file for the app's output (default: discarded).
# JAMMER_WRAP: a command to run the app under, e.g. "sandbox-exec -f scripts/no-network.sb"
# to prove it works without a network (loopback stays open for the agent API).
# A test copy doesn't bring back the windows of the run before, and leaves none for the next:
# window restoration is off unless the check is about just that (JAMMER_RESTORE=1).
restore=()
[[ -n "${JAMMER_RESTORE:-}" ]] || restore=(-ApplePersistenceIgnoreState YES)
# A test copy makes no sound: the engine plays, meters and counts as usual and hands the device silence
# (debug builds; see EditorSession). A check that really needs sound in the room asks for it: JAMMER_SOUND=1.
quiet=(-silentOutput YES)
[[ -n "${JAMMER_SOUND:-}" ]] && quiet=()
# A test copy never touches the Keychain (keys are held in memory, debug builds): a copy with another
# signature than the app that saved a real key would otherwise wait on macOS's password question.
# A test copy's language is set here, never taken from the Mac's settings, so both languages can be
# tried on one Mac and a script knows which it gets: JAMMER_LANG=sv for Swedish, English otherwise.
# (Scripts find menus and texts by key: scripts/l10n.sh <key>.)
# (The app itself follows the Mac: Swedish on a Swedish Mac, English otherwise; a test copy is always told.)
language=(-language "${JAMMER_LANG:-en}")
# A test copy's journal of linked documents is its own and empty: what one check left waiting must not open
# in the next. A check that is about the journal names the folder itself: JAMMER_LINK_JOURNAL=<absolute path>.
journal="${JAMMER_LINK_JOURNAL:-$(mktemp -d "${TMPDIR:-/tmp/}jammer-linkjournal.XXXXXX")}"
# The app's output is always kept (in JAMMER_LOG when given), and at the end it and the app's entries in the system
# log are searched for AppKit's and SwiftUI's own warnings, which come before their asserts: a table view's delegate
# called reentrantly, "Publishing changes from within view updates", constraints that can't all hold, the main thread
# checker. The main thread checker only speaks when its library is loaded, so it is, for the test copy, when Xcode
# has it (JAMMER_NO_MTC=1 leaves it out). The warnings found go in the report; the full list to JAMMER_WARNINGS.
applog="${JAMMER_LOG:-$(mktemp "${TMPDIR:-/tmp/}jammer-applog.XXXXXX")}"
mtc=/Applications/Xcode.app/Contents/Developer/usr/lib/libMainThreadChecker.dylib
insert=()
[[ -z "${JAMMER_NO_MTC:-}" && -f "$mtc" ]] && insert=(DYLD_INSERT_LIBRARIES="$mtc")
started="$(date '+%Y-%m-%d %H:%M:%S')"
env -u OPENROUTER_API_KEY $insert ${=JAMMER_WRAP:-} "$app" $restore $quiet -ai.noKeychain YES -linkJournalFolder "$journal" $language ${=JAMMER_ARGS:-} >"$applog" 2>&1 &
pid=$!
# On the way out the test copy is stopped, and (unless the check is about restoration) the windows it
# would bring back next time are forgotten: the debug copy's saved state, nothing of the real app's.
# Asked to stop, then stopped: an app that is showing a sheet answers a polite request by waiting for
# the user, and a test must never be left holding the screen for that.
cleanup() {
  kill $pid 2>/dev/null
  for _ in {1..20}; do kill -0 $pid 2>/dev/null || break; sleep 0.25; done
  kill -9 $pid 2>/dev/null
  wait $pid 2>/dev/null
  [[ -n "${JAMMER_RESTORE:-}" ]] || rm -rf "${TMPDIR:-/tmp/}com.brattoo.jammer.debug.savedState"
  report_warnings
}
# AppKit's and SwiftUI's warnings in what the test copy wrote and logged (see above): counted by kind in the report.
report_warnings() {
  "$root/scripts/gui/warnings.sh" "$applog" "$pid" "$started" "${JAMMER_WARNINGS:-${TMPDIR:-/tmp/}jammer-warnings-$pid.txt}" >&2
  [[ -n "${JAMMER_LOG:-}" ]] || rm -f "$applog"
}
trap cleanup EXIT INT TERM HUP
export JAMMER_PID=$pid JAMMER_APP="${app%/Contents/MacOS/Jammer}"
for _ in {1..60}; do
  for p in 9003 {9301..9319}; do
    if [[ "$(curl -s -m 1 "http://127.0.0.1:$p/api/v1/status" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["app"]["name"])' 2>/dev/null)" == "Jammer" ]]; then
      export JAMMER_PORT=$p
      break 2
    fi
  done
  sleep 0.5
done
[[ -n "${JAMMER_PORT:-}" ]] || { echo "with-app: Jammer's agent API didn't come up." >&2; exit 1; }
# Before the first click or key: the test copy has to be able to come to the front. If another app keeps it (a
# Terminal, a sheet elsewhere), the check stops here with a reason, not a minute later (no AppleScript, no System
# Events: build/tools/front, from scripts/gui/front.swift). A check that never takes the front says JAMMER_NO_FRONT=1.
if [[ -z "${JAMMER_NO_FRONT:-}" ]]; then
  front="$root/build/tools/front"
  [[ -x "$front" && ! "$root/scripts/gui/front.swift" -nt "$front" ]] || { echo "with-app: build the GUI tools first, under the build lock (not this GUI lock): scripts/build-gui-tools.sh" >&2; exit 1; }
  "$front" $pid 5 >&2
  case $? in
    0) ;;
    # Locked or asleep: not a failed try. Postponed, as when Anders is at the Mac; run it again once it is unlocked
    # (the lock and screen-saver settings are his, never changed).
    3) echo "with-app: postponed, the screen is locked; not a try." >&2; exit 78 ;;
    *) echo "with-app: stopped before the check: the test copy couldn't come to the front." >&2; exit 77 ;;
  esac
fi
"$@"
