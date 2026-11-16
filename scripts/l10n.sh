#!/bin/sh
# Prints the catalogue's text for a key, so that a GUI script finds a menu or a text by its key and
# never by its English (or Swedish) words:
#
#   scripts/l10n.sh <key> [en|sv] [one|other]      default: en; for a count, the form `other`
#
# The language is the one the test copy was started in (JAMMER_LANG for scripts/with-app.sh).
exec python3 - "$(dirname "$0")/../App/Localizable.xcstrings" "$1" "${2:-${JAMMER_LANG:-en}}" "${3:-other}" <<'PY'
import json, sys
cat = json.load(open(sys.argv[1], encoding="utf-8"))
entry = cat["strings"].get(sys.argv[2])
if entry is None: sys.exit("l10n: no key " + sys.argv[2])
loc = entry["localizations"].get(sys.argv[3])
if loc is None: sys.exit("l10n: %s has no %s text" % (sys.argv[2], sys.argv[3]))
if "stringUnit" in loc: print(loc["stringUnit"]["value"])
else: print(loc["variations"]["plural"][sys.argv[4]]["stringUnit"]["value"])
PY
