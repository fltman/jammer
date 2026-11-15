#!/bin/zsh
# Starts the debug build of Jammer for a GUI check, runs a command with JAMMER_PORT set,
# and quits that instance on exit. Must run under the series' shared GUI lock, owned by
# "jammer" (wrap it in the lock tool; this script refuses otherwise).
#   <lock tool> jammer -- scripts/with-app.sh <command> [args…]
# Paid providers can't be reached: OPENROUTER_API_KEY is removed from the app's environment.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(cat /tmp/gui-test.lock/owner 2>/dev/null)" == "jammer" ]] || { echo "with-app: the GUI lock isn't held by jammer; not starting." >&2; exit 75; }
app="$root/build/dd/Build/Products/Debug/Jammer.app/Contents/MacOS/Jammer"
[[ -x "$app" ]] || { echo "with-app: build the app first (xcodebuild … -derivedDataPath build/dd)." >&2; exit 1; }
env -u OPENROUTER_API_KEY "$app" >/dev/null 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null; wait $pid 2>/dev/null' EXIT INT TERM HUP
export JAMMER_PID=$pid
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
