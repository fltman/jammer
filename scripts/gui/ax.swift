// ax <pid> <command> …: reads and sets what the GUI checks need through the accessibility API, aimed at the app with
// that pid (never System Events). Commands:
//   window-frame <name part>             x y w h of the first window whose title contains it
//   set-window-frame <name part> x y w h    moves and sizes the first window whose title contains it
//   window-count                         the app's windows
//   sheet-count <name part>              sheets on the first window whose title contains it
//   press-button <name part> <n>         presses the n-th (1-based) button of that window
//   focused-description                  the AXDescription of the focused element
//   raise <name part>                    brings the first window whose title contains it to the front of the app's
// Built by scripts/build-gui-tools.sh.
import ApplicationServices
import Foundation

let a = CommandLine.arguments
guard a.count >= 3, let pid = pid_t(a[1]) else { print("usage: ax <pid> <command> …"); exit(2) }
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 3)
func attr(_ e: AXUIElement, _ n: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil }
func children(_ e: AXUIElement, role: String? = nil) -> [AXUIElement] {
    ((attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []).filter { role == nil || (attr($0, kAXRoleAttribute) as? String) == role }
}
func windows() -> [AXUIElement] { (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] }
func title(_ w: AXUIElement) -> String { (attr(w, kAXTitleAttribute) as? String) ?? "" }
func window(_ part: String, prefix: Bool = false) -> AXUIElement? { windows().first { prefix ? title($0).hasPrefix(part) : title($0).contains(part) } }
func point(_ v: AnyObject?) -> CGPoint { var p = CGPoint.zero; if let v { AXValueGetValue(v as! AXValue, .cgPoint, &p) }; return p }
func size(_ v: AnyObject?) -> CGSize { var s = CGSize.zero; if let v { AXValueGetValue(v as! AXValue, .cgSize, &s) }; return s }

switch a[2] {
case "window-frame":
    guard a.count > 3, let w = window(a[3]) else { exit(1) }
    let p = point(attr(w, kAXPositionAttribute)), s = size(attr(w, kAXSizeAttribute))
    print(Int(p.x), Int(p.y), Int(s.width), Int(s.height))
case "set-window-frame":
    guard a.count > 7, let w = window(a[3]), let x = Double(a[4]), let y = Double(a[5]), let wd = Double(a[6]), let h = Double(a[7]) else { exit(1) }
    var p = CGPoint(x: x, y: y), s = CGSize(width: wd, height: h)
    AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &p)!)
    AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &s)!)
case "window-count":
    print(windows().count)
case "sheet-count":
    guard a.count > 3, let w = window(a[3]) else { print(0); exit(0) }
    print(children(w, role: kAXSheetRole).count)
case "press-button":
    guard a.count > 4, let w = window(a[3]), let n = Int(a[4]) else { exit(1) }
    let buttons = children(w, role: kAXButtonRole)
    guard buttons.indices.contains(n - 1) else { exit(1) }
    exit(AXUIElementPerformAction(buttons[n - 1], kAXPressAction as CFString) == .success ? 0 : 1)
case "raise":
    guard a.count > 3, let w = window(a[3]) else { exit(1) }
    exit(AXUIElementPerformAction(w, kAXRaiseAction as CFString) == .success ? 0 : 1)
case "focused-description":
    guard let f = attr(app, kAXFocusedUIElementAttribute) else { exit(1) }
    print((attr(f as! AXUIElement, kAXDescriptionAttribute) as? String) ?? "")
default:
    print("ax: unknown command \(a[2])"); exit(2)
}
