#!/bin/zsh
# No script deletes anything of the plain Debug app (the series' rule, 2026-11-26): test scripts touch only a guest's
# things (com.brattoo.jammer.debug.guest, "Jammer Debug Guest") or a data folder of their own. A line that deletes
# (rm, removeItem, defaults delete, trash) may not name com.brattoo.jammer.debug or "Jammer Debug" without the guest.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
python3 -I - "$root" <<'PY'
import os, re, sys
root = sys.argv[1]
deletes = re.compile(r'\brm\b|removeItem|defaults\s+delete|\btrash\b')
plain = re.compile(r'com\.brattoo\.jammer\.debug(?!\.guest)|Jammer Debug(?! Guest)')
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
if not found: print("check-no-debug-deletes: no script deletes anything of the plain Debug app")
sys.exit(found)
PY
