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
env -u OPENROUTER_API_KEY ${=JAMMER_WRAP:-} "$app" $restore $quiet ${=JAMMER_ARGS:-} >"${JAMMER_LOG:-/dev/null}" 2>&1 &
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
"$@"
