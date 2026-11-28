#!/usr/bin/env python3 -I
"""No private path in what is committed (CLAUDE.md: "Never commit secrets, .env or private paths"): this Mac's home
folder, its user name and the names of the volumes mounted on it, in any file git tracks or would add.
    scripts/check-private-paths.py              exit 0 = none
    scripts/check-private-paths.py --self-test  shows that a planted path is caught and a made-up one isn't
What is private is read from this Mac when it runs (HOME, the user, /Volumes), so the check names none of it itself.
A made-up path in a test (/Volumes/Away/Film.jammer) is no volume here and passes. AGENTS.md is never committed."""
import getpass, os, re, subprocess, sys, tempfile

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def patterns():
    home = os.path.expanduser("~")
    user = getpass.getuser()
    pats = [re.escape(home.rstrip("/") + "/")]
    if len(user) >= 4: pats.append(r"(?<![A-Za-z0-9])" + re.escape(user) + r"(?![A-Za-z0-9])")
    try:
        for v in os.listdir("/Volumes"):
            # The system disk is in every Mac's paths; a volume of one's own is not.
            if v in ("Macintosh HD", "Recovery", "Preboot", "Data") or v.startswith("."): continue
            pats.append(re.escape("/Volumes/" + v))
    except OSError:
        pass
    return re.compile("|".join(pats))


def files(where):
    out = subprocess.run(["git", "-C", where, "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
                         capture_output=True, check=True).stdout.decode()
    return [f for f in out.split("\0") if f and f != "AGENTS.md"]


def scan(where, pat):
    found = []
    for f in files(where):
        p = os.path.join(where, f)
        if not os.path.isfile(p) or os.path.islink(p): continue
        try:
            text = open(p, encoding="utf-8").read()
        except (UnicodeDecodeError, OSError):
            continue   # binary: pictures and sounds carry no paths we write
        for n, line in enumerate(text.splitlines(), 1):
            if pat.search(line): found.append(f"{f}:{n}")
    return found


def self_test():
    pat = patterns()
    with tempfile.TemporaryDirectory() as d:
        subprocess.run(["git", "init", "-q", d], check=True)
        home = os.path.expanduser("~")
        open(os.path.join(d, "leak.md"), "w").write("see " + home + "/Projekt/x\n")
        open(os.path.join(d, "fine.swift"), "w").write('let p = "/Volumes/Away/Film.jammer"\n')
        got = scan(d, pat)
        if got != ["leak.md:1"]: sys.exit(f"check-private-paths: self-test expected only leak.md:1, got {got}")
    print("check-private-paths: self-test holds (a home path caught, a made-up volume passed)")


if "--self-test" in sys.argv:
    self_test()
    sys.exit(0)
found = scan(root, patterns())
if found:
    sys.exit("check-private-paths: a private path (this Mac's home, user or a volume of its own) in " + ", ".join(found[:10]))
print("check-private-paths: no private path in what is committed")
