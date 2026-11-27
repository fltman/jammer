#!/usr/bin/env python3
"""An agent's request is answered only when its work is in the document (or the file), never when it has started.

Glimmer, 2026-11-26 (COMFORT.md e32a6c8): a window action that began its work in a detached Task and returned made
the agent's step say "done" before the filter was there, and the next step saw the layer unchanged. The menu may go
on at once; an agent's answer may not. Here: a function in App/ that is not async and starts a Task it doesn't keep
(a `Task {` or `Task.detached {` as a statement of its own) does its work after it returns. App/AgentServer.swift may
call such a function only

- with a completion it waits for, on the same line: `withCheckedContinuation` or `withCheckedThrowingContinuation`,
- awaited (`await session.f(…)`: an async function of that name, which returns when its work is done),
- or when the function is in ALLOWED below, with why its Task is no work an agent waits for.

Jobs (`JobRegistry … start…`) are outside this: they answer 202 with a job, and the job is done only when its
work is in the document.

    scripts/check-agent-waits.py              App/
    scripts/check-agent-waits.py --self-test  planted cases, to show the check catches what it should
"""
import os
import re
import sys
import tempfile

ALLOWED = {
    # Its Task lets the audio device sleep five seconds later; playback has stopped when it returns.
    "stop": "the device sleeps later; playback has stopped",
}
FUNC = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:private|fileprivate|internal|public|nonisolated|static|override|final|@objc)\s+)*func\s+(\w+)\s*(?:<[^>]*>)?\(")
LOOSE_TASK = re.compile(r"^\s*(?:_\s*=\s*)?Task(?:\.detached)?\s*(?:\([^)]*\))?\s*\{")
CALL = re.compile(r"\bsession\??\.(\w+)\(")
WAITED = re.compile(r"withChecked(?:Throwing)?Continuation")


def bodies(text: str):
    """(name, signature, body lines) of every function, by counting braces from its declaration."""
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        m = FUNC.match(lines[i])
        if not m:
            i += 1
            continue
        sig, j = lines[i], i
        while "{" not in lines[j] and j + 1 < len(lines):
            j += 1
            sig += " " + lines[j]
        depth, k, body = 0, j, []
        while k < len(lines):
            line = re.sub(r'"(?:[^"\\]|\\.)*"', '""', lines[k])
            depth += line.count("{") - line.count("}")
            body.append(lines[k])
            if depth <= 0:
                break
            k += 1
        yield m.group(1), sig, body[1:]
        i = j + 1


def loose(folder: str) -> dict[str, str]:
    """Functions that start a Task they don't keep and aren't async: name -> where."""
    out = {}
    for f in sorted(os.listdir(folder)):
        if not f.endswith(".swift"):
            continue
        p = os.path.join(folder, f)
        with open(p, encoding="utf-8") as fh:
            text = fh.read()
        for name, sig, body in bodies(text):
            head = sig.split("{", 1)[0]
            if re.search(r"\)\s*(?:async|.*\basync\b)", head):
                continue
            # Only the function's own statements, not those of functions or closures declared in it on lines of their own.
            if any(LOOSE_TASK.match(l) for l in body):
                out.setdefault(name, f)
    return out


def check(folder: str, server: str) -> list[str]:
    found = loose(folder)
    faults = []
    with open(server, encoding="utf-8") as fh:
        for n, line in enumerate(fh, 1):
            if line.lstrip().startswith("//"):
                continue
            for m in CALL.finditer(line):
                name = m.group(1)
                # An awaited call is to an async function of that name (the menu's `cloneVoice(_ sender:)` starts a
                # Task; `try await session.cloneVoice(name: …)` is the async one).
                if re.search(r"\bawait\b", line[:m.start()]):
                    continue
                if name in found and name not in ALLOWED and not WAITED.search(line):
                    faults.append(f"{os.path.basename(server)}:{n}: session.{name}() starts its work in a Task and returns ({found[name]}); "
                                  "the answer would come before the work is done")
    return faults


def self_test() -> int:
    session = '''
final class EditorSession {
    func saveBack(then done: ((Error?) -> Void)? = nil) {
        status = "saving"
        Task {
            try await write()
            done?(nil)
        }
    }
    func stop() {
        output.stop()
        Task { try? await Task.sleep(for: .seconds(5)) }
    }
    func analyze() async -> Int {
        Task { await other() }
        return 1
    }
    func kept() {
        let work = Task.detached { 1 }
        _ = work
    }
    func plain() { x = 1 }
    @objc func cloneVoice(_ sender: Any?) {
        Task { await ask() }
    }
    func cloneVoice(name: String) async throws -> Int { 1 }
}
'''
    cases = {
        "bare": ("session.saveBack()", True),
        "waited": ("let e = await withCheckedContinuation { c in session.saveBack { c.resume(returning: $0) } }", False),
        "allowed": ("session.stop()", False),
        "async": ("let r = await session.analyze()", False),
        "kept": ("session.kept()", False),
        "plain": ("session.plain()", False),
        "comment": ("// session.saveBack() is not called here", False),
        "overload async": ("let v = try await session.cloneVoice(name: n)", False),
        "overload menu": ("session.cloneVoice(nil)", True),
    }
    bad = 0
    with tempfile.TemporaryDirectory() as tmp:
        with open(os.path.join(tmp, "EditorSession.swift"), "w") as f:
            f.write(session)
        for name, (call, fails) in cases.items():
            server = os.path.join(tmp, "Server.txt")
            with open(server, "w") as f:
                f.write("enum R {\n    static func route() async {\n        " + call + "\n    }\n}\n")
            got = bool(check(tmp, server))
            if got != fails:
                print(f"check-agent-waits: self-test: {name} {'passed' if fails else 'failed'}, should have {'failed' if fails else 'passed'}")
                bad += 1
    if bad:
        return 1
    print(f"check-agent-waits: self-test: {len(cases)} planted cases as they should be")
    return 0


def main() -> int:
    if "--self-test" in sys.argv[1:]:
        return self_test()
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    app = os.path.join(root, "App")
    faults = check(app, os.path.join(app, "AgentServer.swift"))
    for f in faults:
        print("check-agent-waits: " + f)
    if faults:
        return 1
    print(f"check-agent-waits: the agent's routes wait for what they start ({len(loose(app))} functions in App/ start a Task and return)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
