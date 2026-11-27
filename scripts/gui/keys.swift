// keys <pid> <key>…: types keys into the app with that pid, and nowhere else. Each key is posted to that pid
// (CGEvent.postToPid), and before each one the frontmost app is checked to be that pid: if it isn't, nothing more is
// sent and the exit is 1. (System Events sends keys to whatever app is in front; a run once typed into a chat.)
// Keys:  code <n>            a key code (36 Return, 53 Escape, 48 Tab, 49 Space, 123–126 arrows)
//        text <string>       the string, character by character
//        <mods> <letter>     a shortcut: mods are cmd, opt, ctrl, shift joined with + (cmd, cmd+opt, cmd+shift)
//        <mods> code:<n>     a shortcut on a key code (opt code:125 is ⌥↓); an arrow gets the flags a real one has
// A shortcut's character is found on the keyboard layout in use now (UCKeyTranslate): "+" is key 27 on a Swedish
// layout and ⇧ with key 24 on a US one (the round of 2026-11-27 sent US codes, and ⌃⌘= typed nothing on the Swedish
// Mac). The layout is only read, never changed.
//   keys --which <character>   the key and modifier that type it here, and nothing is sent
// Built by scripts/build-gui-tools.sh.
import AppKit
import Carbon
import CoreGraphics

/// The key, and whether it needs ⇧, that types `ch` on the current keyboard layout; the numeric pad last, so "+" and
/// "=" are the main keys'. nil when the layout has no Unicode data or no key for it.
func key(for ch: Character) -> (code: CGKeyCode, shift: Bool)? {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
    let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
    let pad = Set(65...92)
    let groups = [(0..<128).filter { !pad.contains($0) }, (0..<128).filter { pad.contains($0) }]
    return data.withUnsafeBytes { buffer -> (CGKeyCode, Bool)? in
        guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
        // The main keys, without ⇧ and then with it ("=" is ⇧0 on a Swedish layout), before the numeric pad.
        for group in groups { for shift in [false, true] {
            for code in group {
                var dead: UInt32 = 0, length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let mods: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), mods, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
                if status == noErr, length == 1, String(utf16CodeUnits: chars, count: 1) == String(ch) { return (CGKeyCode(code), shift) }
            }
        } }
        return nil
    }
}

var args = Array(CommandLine.arguments.dropFirst())
if args.first == "--which", args.count == 2, let ch = args[1].first {
    if let k = key(for: ch) { print("\(k.code)\(k.shift ? " shift" : "")"); exit(0) }
    print("keys: the layout in use has no key for \(ch)"); exit(1)
}
guard let first = args.first, let pid = pid_t(first) else { print("usage: keys <pid> code <n> | text <s> | <mods> <letter> … | keys --which <character>"); exit(2) }
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
// US key codes, for a layout that gives no Unicode data.
let letters: [Character: CGKeyCode] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
    "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28,
    "0": 29, "=": 24, "-": 27, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, ",": 43, ".": 47]
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
        if value.hasPrefix("code:") {
            guard let c = CGKeyCode(value.dropFirst(5)) else { print("keys: not a key code: \(value)"); exit(2) }
            // The arrows (123–126) are function keys on the numeric pad, as the keyboard sends them.
            if (123...126).contains(c) { flags.formUnion([.maskSecondaryFn, .maskNumericPad]) }
            post(c, flags: flags)
            continue
        }
        guard let ch = value.lowercased().first else { print("keys: no key for \(value)"); exit(2) }
        if let k = key(for: ch) {
            post(k.code, flags: k.shift ? flags.union(.maskShift) : flags)
        } else if let c = letters[ch] {
            post(c, flags: flags)
        } else {
            print("keys: no key for \(value) on this layout"); exit(2)
        }
    }
}
