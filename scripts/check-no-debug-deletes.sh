#!/bin/zsh
# No script deletes anything of the real app or the plain Debug app (the series' rule, 2026-11-26): test scripts touch
# only a guest's things (com.brattoo.jammer.debug.guest, "Jammer Debug Guest") or a data folder of their own. A line
# that deletes (rm, removeItem, defaults delete, trash) may not name:
#   - the Release id com.brattoo.jammer, or the Debug id com.brattoo.jammer.debug, without the guest;
#   - a folder of the user's Library named Jammer or Jämmer (Application Support, Caches, Preferences, Saved
#     Application State, Containers, Logs, HTTPStorages, WebKit) without "Debug Guest".
# Build products (build/…/Jammer.app, the release's zip) are this repository's own and not meant.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
python3 -I - "$root" <<'PY'
import os, re, sys
root = sys.argv[1]
deletes = re.compile(r'\brm\b|removeItem|defaults\s+delete|\btrash\b')
plain = re.compile(r'com\.brattoo\.jammer(?![\w.])|com\.brattoo\.jammer\.debug(?!\.guest)|Jammer Debug(?! Guest)'
                   r'|(?:Application\\? Support|Caches|Preferences|Saved\\? Application\\? State|Containers|Logs|HTTPStorages|WebKit)/J[aä]mmer(?!\\? Debug\\? Guest)')
found = 0
for base, _, files in os.walk(os.path.join(root, 'scripts')):
    for name in files:
        path = os.path.join(base, name)
        if name == 'check-no-debug-deletes.sh': continue
        try: lines = open(path, encoding='utf-8').read().splitlines()
        except (UnicodeDecodeError, OSError): continue
        for n, line in enumerate(lines, 1):
            code = line.strip()
            if code.startswith('#') or code.startswith('//'): continue
            if deletes.search(code) and plain.search(code):
                print(f"check-no-debug-deletes: {os.path.relpath(path, root)}:{n}: {code[:160]}")
                found = 1
if not found: print("check-no-debug-deletes: no script deletes anything of the real app or the plain Debug app")
sys.exit(found)
PY
