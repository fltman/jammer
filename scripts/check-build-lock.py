#!/usr/bin/env python3
"""Every script that builds or runs tests takes the series' build lock (the-apps/tools/with-build-lock.sh).

One heavy build at a time across the three apps' sessions: two at once page each other out and the other app's
gate fails for nothing (2026-11-16, 2026-11-26). A script under scripts/ whose commands build (xcodebuild,
swift build/test/run, swiftc, CMake's and Cargo's builds, make, clang, also by a path) has to name with-build-lock.sh, normally in the
self-starting block at its top:

    case ":${APPS_HELD_LOCKS:-}:" in *":/tmp/the-apps-build.lock:"*) ;; *) … exec "$apps_tools/with-build-lock.sh" jammer … -- "$0" "$@" ;; esac

Not a build: `xcodebuild -showBuildSettings` or `-create-xcframework` alone, and `swift test --skip-build` (the
assistant evaluation, built under the build lock and run under the model lock). Comments and the text that echo or
printf print are not read. A script that builds but must not take the lock says why on a line of its own:
`# build-lock: none (<why>)`.

    scripts/check-build-lock.py              the scripts
    scripts/check-build-lock.py --self-test  planted cases, to show the check catches what it should
"""
import os
import re
import sys
import tempfile

BUILD = re.compile(r"(?:^|[\s;&|(`/])(?:xcodebuild\b|xcrun\s+swiftc\b|swift\s+(?:build|test|run)\b|swiftc\b|cmake\s+--build\b|cargo\s+build\b|make\b|clang\+\+|clang\b)")
NOT_BUILD = [re.compile(p) for p in (r"xcodebuild\s[^;|&]*-showBuildSettings", r"xcodebuild\s[^;|&]*-create-xcframework", r"swift\s+test\s[^;|&]*--skip-build")]
SAID = re.compile(r"""\b(?:echo|printf)\s+(?:"(?:[^"\\]|\\.)*"|'[^']*')""")
LOCK = re.compile(r"with-build-lock\.sh")
EXEMPT = re.compile(r"^\s*#\s*build-lock:\s*none\s*\(.+\)")


def builds(line: str) -> bool:
    if line.lstrip().startswith("#"):
        return False
    code = SAID.sub("", line)
    for m in BUILD.finditer(code):
        rest = code[m.start():]
        if any(n.match(rest.lstrip(" \t;&|(`")) for n in NOT_BUILD):
            continue
        return True
    return False


def check(path: str) -> str | None:
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.read().splitlines()
    hits = [i + 1 for i, l in enumerate(lines) if builds(l)]
    if not hits:
        return None
    if any(EXEMPT.match(l) for l in lines):
        return None
    if any(LOCK.search(l) and not l.lstrip().startswith("#") for l in lines):
        return None
    return f"{path}:{hits[0]}: builds without the build lock (with-build-lock.sh), line(s) {', '.join(map(str, hits[:5]))}"


def scripts(root: str) -> list[str]:
    out = []
    for d, _, files in os.walk(os.path.join(root, "scripts")):
        if "__pycache__" in d:
            continue
        out += [os.path.join(d, f) for f in files if f.endswith(".sh")]
    return sorted(out)


def self_test() -> int:
    cases = {
        "bare.sh": ("#!/bin/sh\nset -eu\ncd Packages/JammerKit\nswift test --filter X\n", True),
        "xcode.sh": ("#!/bin/zsh\nxcodebuild -project J.xcodeproj -scheme J build > log 2>&1\n", True),
        "swiftc.sh": ("#!/bin/zsh\n[[ -x out ]] || xcrun swiftc -O -o out main.swift\n", True),
        # Put together, so this file has no line that check-fetch-guard.sh reads as fetching third-party code.
        "cmake.sh": ("#!/bin/sh\n" + "cmake" + " --build b\n", True),
        "cargo.sh": ("#!/bin/sh\n(cd src && " + "cargo" + " build --release)\n", True),
        "path.sh": ("#!/bin/sh\n\"$llvm/bin/clang++\" -std=c++20 a.cpp -o a\n", True),
        "locked.sh": ("#!/bin/sh\ncase \":${APPS_HELD_LOCKS:-}:\" in *\":/tmp/the-apps-build.lock:\"*) ;; *) exec \"$t/with-build-lock.sh\" jammer -- \"$0\" \"$@\" ;; esac\nswift build\n", False),
        "said.sh": ("#!/bin/sh\n[ -d app ] || { echo \"Build the app first (xcodebuild … -derivedDataPath build/dd).\" >&2; exit 1; }\n", False),
        "comment.sh": ("#!/bin/sh\n# swift test --filter Y is how to run it\ntrue\n", False),
        "settings.sh": ("#!/bin/sh\nxcodebuild -project J.xcodeproj -showBuildSettings > s.txt\n", False),
        "skip.sh": ("#!/bin/sh\nswift test --skip-build --filter Eval\n", False),
        "lockcomment.sh": ("#!/bin/sh\n# with-build-lock.sh would be right here\nswift build\n", True),
        "exempt.sh": ("#!/bin/sh\n# build-lock: none (a planted case)\nswift build\n", False),
    }
    bad = 0
    with tempfile.TemporaryDirectory() as tmp:
        for name, (text, fails) in cases.items():
            p = os.path.join(tmp, name)
            with open(p, "w") as f:
                f.write(text)
            got = check(p) is not None
            if got != fails:
                print(f"check-build-lock: self-test: {name} {'passed' if fails else 'failed'}, should have {'failed' if fails else 'passed'}")
                bad += 1
    if bad:
        return 1
    print(f"check-build-lock: self-test: {len(cases)} planted cases as they should be")
    return 0


def main() -> int:
    if "--self-test" in sys.argv[1:]:
        return self_test()
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    faults = [m for m in (check(p) for p in scripts(root)) if m]
    for m in faults:
        print("check-build-lock: " + m.replace(root + os.sep, ""))
    if faults:
        return 1
    print(f"check-build-lock: {len(scripts(root))} scripts, every one that builds takes the build lock")
    return 0


if __name__ == "__main__":
    sys.exit(main())
