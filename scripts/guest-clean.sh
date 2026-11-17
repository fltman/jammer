#!/bin/zsh
# After a visit: removes what Jämmer's GUEST copy (bundle id com.brattoo.jammer.debug.guest, made by
# scripts/guest-copy.sh) left on this Mac, and nothing else (the-apps/SIBLINGS.md §1). A visiting
# session runs it when it is done.
#
# What it touches, each by its exact path, and prints as it goes:
#   1. the guest's own data folder, ~/Library/Application Support/Jammer Debug Guest (its media, its
#      plugin catalogue, its link journal), file by file;
#   2. the guest's autosaved documents: only those its own list names
#      (~/Library/Autosave Information/com.brattoo.jammer.debug.guest.plist), and that list;
#   3. the guest's saved windows ($TMPDIR/com.brattoo.jammer.debug.guest.savedState).
# Nothing is found by a pattern outside these three places; our own debug copy's and the real app's
# files have other names and are never looked at. Files are unlinked and folders removed only when
# empty; a folder that still has something in it afterwards is said and left.
#   scripts/guest-clean.sh           do it
#   scripts/guest-clean.sh --dry     only say what would go
set -u
id=com.brattoo.jammer.debug.guest
dry=0; [[ "${1:-}" == "--dry" ]] && dry=1
# For the script's own test: another folder in place of the home folder and the temporary folder.
home="${JAMMER_GUEST_CLEAN_ROOT:-$HOME}"; tmp="${JAMMER_GUEST_CLEAN_ROOT:+$JAMMER_GUEST_CLEAN_ROOT/tmp/}"; tmp="${tmp:-${TMPDIR:-/tmp/}}"
if pgrep -f "build/guest/Jammer.app/Contents/MacOS/Jammer" >/dev/null; then echo "guest-clean: the guest copy is running; quit it first. Nothing was removed." >&2; exit 1; fi
gone=0
unlink_one() { if (( dry )); then echo "would remove $1"; else rm -f -- "$1" && echo "removed $1"; fi; gone=$((gone + 1)); }
rmdir_one() { if (( dry )); then echo "would remove the folder $1 (if empty)"; else rmdir -- "$1" 2>/dev/null && echo "removed the folder $1" || echo "left the folder $1 (not empty)"; fi; }
tree() { # every file under a folder, then its folders from the deepest up
  local root="$1"
  [[ -d "$root" ]] || { echo "not there: $root"; return; }
  find "$root" \( -type f -o -type l \) -print0 | while IFS= read -r -d '' f; do unlink_one "$f"; done
  find "$root" -depth -type d -print0 | while IFS= read -r -d '' d; do rmdir_one "$d"; done
}
echo "--- the guest's data folder"
tree "$home/Library/Application Support/Jammer Debug Guest"
echo "--- the guest's autosaved documents"
list="$home/Library/Autosave Information/$id.plist"
if [[ -f "$list" ]]; then
  # The paths the list itself names, and only those that lie in the autosave folder.
  named=$(plutil -convert json -r -o - "$list" 2>/dev/null | AS_ROOT="$home/Library/Autosave Information/" python3 -c '
import json, sys, os, urllib.parse
root = os.environ["AS_ROOT"]
def walk(o):
    if isinstance(o, dict):
        for v in o.values(): yield from walk(v)
    elif isinstance(o, list):
        for v in o: yield from walk(v)
    elif isinstance(o, str):
        p = urllib.parse.unquote(o[7:]) if o.startswith("file://") else o
        if p.startswith(root) and p.rstrip("/").endswith(".jammer"): yield p.rstrip("/")
try: print("\n".join(sorted(set(walk(json.load(sys.stdin))))))
except Exception: pass')
  if [[ -z "$named" ]]; then echo "the guest's list names no document this script can read a path for; its documents (if any) are left: $list"
  else echo "$named" | while IFS= read -r doc; do tree "$doc"; done; fi
  unlink_one "$list"
else echo "not there: $list"; fi
echo "--- the guest's saved windows"
tree "$tmp$id.savedState"
(( dry )) && echo "guest-clean: nothing was removed (--dry)." || echo "guest-clean: done."
