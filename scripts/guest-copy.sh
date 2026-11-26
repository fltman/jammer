#!/bin/zsh
# A copy of the Debug build for a visiting test (another app's session trying its round trip against
# Jämmer): the same program under a bundle id of its own, com.brattoo.jammer.debug.guest (SIBLINGS.md §1).
#
#   scripts/guest-copy.sh                  → prints the copy's path (build/guest/Jammer.app)
#   scripts/guest-copy.sh <src.app> <out.app>   another build, another place, both inside build/ (with-app.sh's
#                                          test copies: build/test-guest/<the build's folder>/Jammer.app)
#
# Jämmer is not sandboxed, so the id alone doesn't keep a visitor out of our files. What follows the id
# by itself: settings (the defaults domain), saved windows, caches, Keychain items (none: a guest has no
# keys). What Jämmer was made to do for a guest: its own data folder, "~/Library/Application Support/
# Jammer Debug Guest" (media, recipes, the plugin catalogue), chosen from the ".guest" at the end of the
# id; `-dataFolder <absolute path>` puts it somewhere else. Not separated: untitled documents autosave
# where macOS puts every app's ("~/Library/Autosave Information"), under their own names, and are removed
# when they close; and a linked file is the visitor's own file, written back when the visitor saves.
#
# Start it without sound, without restored windows and without keys, under the GUI lock, and stop it by
# its pid:
#   env -u OPENROUTER_API_KEY <path>/Contents/MacOS/Jammer -silentOutput YES -ApplePersistenceIgnoreState YES -ai.noKeychain YES
# It takes the first free port of 9003, 9301–9319; GET /api/v1/status says app.bundleID, port and pid,
# so a visitor can see that it is talking to the copy it started.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="${1:-$PWD/build/dd/Build/Products/Debug/Jammer.app}"
OUT="${2:-$PWD/build/guest/Jammer.app}"
[[ -d "$SRC" ]] || { echo "Build the app first (xcodebuild … -derivedDataPath build/dd)." >&2; exit 1; }
# Both inside this repository's build folder, and the copy named Jammer.app: nothing else is ever written over.
[[ "$SRC" == "$PWD"/build/*/Jammer.app && "$OUT" == "$PWD"/build/*/Jammer.app ]] || { echo "guest-copy: both have to be a Jammer.app inside build/." >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
if [[ -d "$OUT" ]]; then mv "$OUT" "$(dirname "$OUT")/old-$$.app"; fi   # replaced, not deleted in place
cp -R "$SRC" "$OUT"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.brattoo.jammer.debug.guest" "$OUT/Contents/Info.plist"
ENT="$PWD/build/guest/guest.entitlements"
codesign -d --entitlements - --xml "$SRC" 2>/dev/null > "$ENT"
[[ -s "$ENT" ]] || { echo "Couldn't read the Debug build's entitlements." >&2; exit 1; }
# Ad hoc, with the Debug build's own entitlements and nothing added; what is inside it keeps its signatures.
codesign --force --sign - --entitlements "$ENT" "$OUT" >/dev/null 2>&1
codesign --verify "$OUT" 2>/dev/null || { echo "The copy's signature doesn't verify." >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$OUT/Contents/Info.plist")" == com.brattoo.jammer.debug.guest ]] || exit 1
echo "$OUT"
