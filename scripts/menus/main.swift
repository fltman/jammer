// Prints a running app's menus, one item per line: "File › Import Timeline…<TAB>⇧⌘I" (empty after the tab when
// the item has no shortcut). Read through accessibility, without opening a menu or pressing anything.
//   build/menus <pid>
// Used by scripts/ax-audit.sh (English) to hold the manual against the app: scripts/check-manual.py.
import ApplicationServices
import Foundation

guard CommandLine.arguments.count == 2, let pid = pid_t(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: menus <pid>\n".utf8)); exit(64)
}
func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func title(_ e: AXUIElement) -> String { (attr(e, kAXTitleAttribute) as? String) ?? "" }

/// The shortcut as a menu shows it: ⌃⌥⇧⌘ then the key.
func shortcut(_ item: AXUIElement) -> String {
    var key = (attr(item, "AXMenuItemCmdChar") as? String) ?? ""
    if key.isEmpty, let glyph = attr(item, "AXMenuItemCmdGlyph") as? Int {
        let glyphs: [Int: String] = [0x17: "⌫", 0x0B: "↩", 0x02: "⇥", 0x10: "Space", 0x1B: "⎋"]
        key = glyphs[glyph] ?? ""
    }
    guard !key.isEmpty else { return "" }
    key = key == " " ? "Space" : key.uppercased()
    let m = (attr(item, "AXMenuItemCmdModifiers") as? Int) ?? 0   // 1 shift, 2 option, 4 control, 8 no command
    return (m & 4 != 0 ? "⌃" : "") + (m & 2 != 0 ? "⌥" : "") + (m & 1 != 0 ? "⇧" : "") + (m & 8 == 0 ? "⌘" : "") + key
}

let app = AXUIElementCreateApplication(pid)
guard let bar = attr(app, kAXMenuBarAttribute) else { FileHandle.standardError.write(Data("menus: no menu bar (accessibility not allowed?)\n".utf8)); exit(1) }
var lines: [String] = []
func walk(_ menu: AXUIElement, _ path: [String]) {
    for item in children(menu) {
        let t = title(item)
        guard !t.isEmpty else { continue }   // separators
        let here = path + [t]
        if let sub = children(item).first, (attr(sub, kAXRoleAttribute) as? String) == kAXMenuRole as String {
            lines.append(here.joined(separator: " › ") + "\t")
            walk(sub, here)
        } else {
            lines.append(here.joined(separator: " › ") + "\t" + shortcut(item))
        }
    }
}
for top in children(bar as! AXUIElement) {
    let t = title(top)
    guard !t.isEmpty, t != "Apple", let menu = children(top).first else { continue }
    walk(menu, [t])
}
print(lines.joined(separator: "\n"))
