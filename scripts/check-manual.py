#!/usr/bin/env python3 -I
"""Every menu path and shortcut the manual and the FAQ name is in the app.

    scripts/check-manual.py [<menus file>]        exit 0 = holds

The menus file is what the running English app's menus are, one "Menu › Submenu › Item<TAB>shortcut" per line, as
build/menus <pid> prints them (scripts/menus/main.swift). Config/menus-en.txt is the kept copy the commit gate reads;
scripts/ax-audit.sh reads the menus again on every English pass and fails when they differ from it, so the copy can't
go stale unnoticed. The copy is of a debug build, which has every switched feature; a path that only a debug build
has is named in DEBUG_ONLY and refused in the manual, which describes what ships.

Checked in site/manual/*.md and site/faq.md:
  - a bold path that starts at a menu (**File › Export Timeline…**) names an item at that path; a bold path that
    lists items (**Audio › Remove Hum…, Repair Clipping…**) names each of them
  - a shortcut in brackets right after such a path (**File › Open…** (⌘O)) is that item's shortcut
  - every shortcut in the keyboard chapter's tables is some menu item's, or is named in NOT_IN_MENUS with where it lives
(Written for Jämmer after Glimmer's scripts/check-manual.py, which showed the way; nothing of it is imported.)
"""
import glob, os, re, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
menus = {}
for line in open(sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, "Config/menus-en.txt"), encoding="utf8"):
    path, _, key = line.rstrip("\n").partition("\t")
    if path: menus[path] = key
tops = {p.split(" › ")[0] for p in menus}

# Written with › but not menu items: Settings' tabs and what is inside them, items whose title carries a file's name,
# items only a window that edits a linked file has (or a document with a file of open channel order), and Undo and
# Redo, whose titles name the step.
def excused(path):
    parts = path.split(" › ")
    if parts[0] == "Jämmer" and len(parts) > 2 and parts[1] in ("Settings", "Settings…"): return True   # Jämmer › Settings… › Agents
    if path.startswith("File › Save Back to "): return True        # "Save Back to clip.wav"
    if path == "File › Save a Jämmer Copy…": return True           # only in a window that edits a file linked from Flimmer
    # Only in a document with a 7.1 or 7.1.4 file that names no loudspeakers (seen in such a window, 2026-11-17).
    if path in ("Audio › Layout › Unmarked File: Sides First (ITU-R BS.2051)", "Audio › Layout › Unmarked File: Rears First (WAV Order)"): return True
    if path in ("Edit › Undo", "Edit › Redo"): return True
    return False

# In a debug build's menus but not in a release (Config/Features.xcconfig, and debug-only work): the manual mustn't name them.
DEBUG_ONLY = ()   # automation moved into every build on 2026-11-18

# Keys that aren't letters or digits sit in different places on different keyboards, and macOS reports them as this
# Mac's layout has them: they are not compared.
def comparable(key): return bool(re.fullmatch(r"[⌃⌥⇧]*⌘[A-Z0-9]", key))

# Shortcuts that belong to no menu item, and where each lives (read in the source).
NOT_IN_MENUS = {
    "⌘Z": "Undo, whose item carries the step's name",
    "⇧⌘Z": "Redo, likewise",
    "⌃⌘F": "View › Enter Full Screen, which macOS adds (left out of the kept copy)",
    "⌘M": "Window › Minimize, in the system's Window menu (left out of the kept copy)",
    "⇧⌘C": "Copy the line for your agent, on the splash (AgentSplashView)",
}

def norm(s): return s.replace("...", "…").strip()

found = []
keys_in_menus = {k for k in menus.values() if k}
pages = sorted(glob.glob(os.path.join(root, "site/manual/*.md"))) + [os.path.join(root, "site/faq.md")]
for page in pages:
    name = os.path.basename(page)
    for number, line in enumerate(open(page, encoding="utf8"), 1):
        for m in re.finditer(r"\*\*([^*]+?›[^*]+?)\*\*(?:\s*\(([^)]{1,12})\))?", line):
            parts = [norm(p) for p in m.group(1).split("›")]
            if parts[0] not in tops: continue
            # "Audio › Remove Hum…, Repair Clipping…" names several items in one menu.
            # An item whose own title has a comma ("Buses, Groups and Master") is one item, not a list.
            whole = " › ".join(parts)
            last = [x.strip() for x in parts[-1].split(", ")] if ", " in parts[-1] and whole not in menus else [parts[-1]]
            for leaf in last:
                item = " › ".join(parts[:-1] + [leaf])
                if excused(item): continue
                if any(item == d or item.startswith(d + " › ") for d in DEBUG_ONLY):
                    found.append(f"{name}:{number}: “{item}” is in debug builds only")
                    continue
                if item not in menus:
                    found.append(f"{name}:{number}: no menu item “{item}”")
                    continue
                said = (m.group(2) or "").strip()
                if len(last) == 1 and said and re.search(r"[⌘⌥⇧⌃]", said) and " " not in said:
                    have = menus[item]
                    if comparable(said) and (not have or (comparable(have) and have != said)):
                        found.append(f"{name}:{number}: “{item}” is said to be {said}; the app has {have or 'no shortcut'}")
        if name.startswith("10-") and line.startswith("|") and line.count("|") > 2:
            for key in re.findall(r"(?<![A-Za-z0-9])([⌃⌥⇧]*⌘(?:Space|[A-Z0-9,.;'\[\]/\\=+\-⌫↩⇥]))(?![A-Za-z0-9])", line.split("|")[1]):
                if comparable(key) and key not in keys_in_menus and key not in NOT_IN_MENUS:
                    found.append(f"{name}:{number}: the shortcut {key} belongs to no menu item")

for f in found: print("✘ " + f)
print(f"{len(found)} place(s) where the manual and the menus differ." if found
      else f"Every menu path and shortcut in the manual and the FAQ is in the app ({len(menus)} menu items read).")
sys.exit(1 if found else 0)
