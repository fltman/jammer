#!/bin/zsh
# guest-clean.sh on a planted tree in a folder of its own: the guest's files go, each named; our own debug
# copy's, another document among the autosaves, and a path the guest's list names outside the autosave
# folder all stay. Nothing outside the planted folder is touched.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
R=$(mktemp -d "${TMPDIR:-/tmp/}jammer-guestclean.XXXXXX"); trap 'rm -rf "$R"' EXIT
G="$R/Library/Application Support/Jammer Debug Guest"; O="$R/Library/Application Support/Jammer Debug"; A="$R/Library/Autosave Information"
mkdir -p "$G/Media" "$G/Link Journal" "$O/Media" "$A/Unsaved Jämmer Document.jammer/Media" "$A/Unsaved Jämmer Document 2.jammer" "$R/tmp/com.brattoo.jammer.debug.guest.savedState" "$R/tmp/com.brattoo.jammer.debug.savedState"
touch "$G/Media/a.wav" "$G/Link Journal/x.jammerlink" "$O/Media/ours.wav" "$A/Unsaved Jämmer Document.jammer/project.json" "$A/Unsaved Jämmer Document.jammer/Media/m.wav" \
      "$A/Unsaved Jämmer Document 2.jammer/project.json" "$A/com.brattoo.jammer.debug.plist" "$R/tmp/com.brattoo.jammer.debug.guest.savedState/windows.plist" "$R/tmp/com.brattoo.jammer.debug.savedState/windows.plist"
python3 - "$R" <<'PY'
import plistlib, sys, urllib.parse
r = sys.argv[1]
doc = r + "/Library/Autosave Information/Unsaved Jämmer Document.jammer"
plistlib.dump({"docs": [{"url": "file://" + urllib.parse.quote(doc) + "/"}, {"url": "file://" + urllib.parse.quote(r + "/Library/Application Support/Jammer Debug/Media/ours.wav")}]},
              open(r + "/Library/Autosave Information/com.brattoo.jammer.debug.guest.plist", "wb"))
PY
before=$(cd "$R" && find . -type f | sort)
dry=$(JAMMER_GUEST_CLEAN_ROOT="$R" "$here/guest-clean.sh" --dry)
[[ "$(cd "$R" && find . -type f | sort)" == "$before" ]] || { echo "test-guest-clean: --dry removed something"; exit 1; }
out=$(JAMMER_GUEST_CLEAN_ROOT="$R" "$here/guest-clean.sh")
left=$(cd "$R" && find . -type f | LC_ALL=C sort | tr '\n' '|')
want="./Library/Application Support/Jammer Debug/Media/ours.wav|./Library/Autosave Information/Unsaved Jämmer Document 2.jammer/project.json|./Library/Autosave Information/com.brattoo.jammer.debug.plist|./tmp/com.brattoo.jammer.debug.savedState/windows.plist|"
[[ "$left" == "$want" ]] || { echo "test-guest-clean: what is left is not what should be: $left"; exit 1; }
[[ $(echo "$out" | grep -c "^removed $R") == 6 && $(echo "$dry" | grep -c "^would remove $R") == 6 ]] || { echo "test-guest-clean: not every removed file was named"; exit 1; }
[[ ! -d "$G" ]] || { echo "test-guest-clean: the guest's data folder is still there"; exit 1; }
echo "test-guest-clean: the guest's six files went, each named; the four that are not the guest's stayed; --dry removed nothing"
