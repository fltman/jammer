// keys <pid> <key>…: types keys into the app with that pid, and nowhere else. Each key is posted to that pid
// (CGEvent.postToPid), and before each one the frontmost app is checked to be that pid: if it isn't, nothing more is
// sent and the exit is 1. (System Events sends keys to whatever app is in front; a run once typed into a chat.)
// Keys:  code <n>            a key code (36 Return, 53 Escape, 48 Tab, 49 Space, 123–126 arrows)
//        text <string>       the string, character by character
//        <mods> <letter>     a shortcut: mods are cmd, opt, ctrl, shift joined with + (cmd, cmd+opt, cmd+shift)
// Built by scripts/build-gui-tools.sh.
import AppKit
import CoreGraphics

var args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first, let pid = pid_t(first) else { print("usage: keys <pid> code <n> | text <s> | <mods> <letter> …"); exit(2) }
args.removeFirst()

func inFront() -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
func post(_ code: CGKeyCode, flags: CGEventFlags = [], text: String? = nil) {
    guard inFront() else {
        print("keys: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "another app") is in front, not pid \(pid): no key sent")
        exit(1)
    }
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
        e.flags = flags
        if let text { let u = Array(text.utf16); e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u) }
        e.postToPid(pid)
    }
    usleep(30_000)
}
// US key codes for the letters and digits a shortcut uses.
let letters: [Character: CGKeyCode] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
    "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28,
    "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, ",": 43, ".": 47]
var i = 0
while i < args.count {
    let word = args[i]
    guard i + 1 < args.count else { print("keys: \(word) needs a value"); exit(2) }
    let value = args[i + 1]
    i += 2
    switch word {
    case "code":
        guard let c = CGKeyCode(value) else { print("keys: not a key code: \(value)"); exit(2) }
        post(c)
    case "text":
        for ch in value { post(0, text: String(ch)) }
    default:
        var flags: CGEventFlags = []
        for m in word.split(separator: "+") {
            switch m {
            case "cmd": flags.insert(.maskCommand)
            case "opt": flags.insert(.maskAlternate)
            case "ctrl": flags.insert(.maskControl)
            case "shift": flags.insert(.maskShift)
            default: print("keys: unknown modifier \(m)"); exit(2)
            }
        }
        guard let ch = value.lowercased().first, let c = letters[ch] else { print("keys: no key code for \(value)"); exit(2) }
        post(c, flags: flags)
    }
}
