#!/usr/bin/env python3
"""Makes the site's manual say what the release build has: for every feature in
Config/Features.xcconfig, puts the "on" or the "off" wording from Config/site-features.json
into the manual. With --check it changes nothing and fails when the manual is out of step.
Run by scripts/export-agents-guide.sh; the package tests run the check."""
import json, os, re, sys
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
flags = dict(re.findall(r"^JAMMER_(\w+)\s*=\s*(YES|NO)\s*$", open(os.path.join(root, "Config/Features.xcconfig")).read(), re.M))
check, stale = "--check" in sys.argv, []
for feature, pairs in json.load(open(os.path.join(root, "Config/site-features.json"))).items():
    on = flags.get(feature.upper()) == "YES"
    for p in pairs:
        path = os.path.join(root, p["file"])
        text = open(path).read()
        want, other = (p["on"], p["off"]) if on else (p["off"], p["on"])
        if want in text and (not other or other not in text or len(want) > len(other)): continue
        if other not in text: sys.exit(f"apply-features: can't find the {feature} wording in {p['file']}.")
        new = text.replace(other, want, 1)
        if check: stale.append(p["file"])
        else: open(path, "w").write(new)
if stale: sys.exit("The manual is out of step with Config/Features.xcconfig: run scripts/export-agents-guide.sh (" + ", ".join(sorted(set(stale))) + ")")
