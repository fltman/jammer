// front <pid> [seconds]: asks the app with that pid to become the frontmost app, through AppKit (no AppleScript, no
// System Events), and waits until it is. Exit 0 when it is; 1, saying which app holds the front, when it isn't in
// time. A GUI check calls it before its first click or key, so it stops at once with a reason instead of failing a
// minute later because another app (a Terminal, a sheet elsewhere) kept the focus. Built by scripts/build-gui-tools.sh.
import AppKit

let args = CommandLine.arguments
guard args.count >= 2, let pid = pid_t(args[1]) else { print("usage: front <pid> [seconds]"); exit(2) }
let limit = args.count > 2 ? Double(args[2]) ?? 5 : 5
guard let app = NSRunningApplication(processIdentifier: pid) else { print("front: no app with pid \(pid)"); exit(1) }
let deadline = Date().addingTimeInterval(limit)
var asked = 0
while Date() < deadline {
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { print("front: \(app.localizedName ?? "pid \(pid)") is in front"); exit(0) }
    if asked % 10 == 0 { app.unhide(); _ = app.activate(options: [.activateAllWindows]) }
    asked += 1
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
let holder = NSWorkspace.shared.frontmostApplication
if holder?.bundleIdentifier == "com.apple.loginwindow" {
    print("front: the Mac is locked or its screen is asleep (loginwindow is in front): no GUI check can run until someone unlocks it.")
    exit(1)
}
print("front: \(app.localizedName ?? "pid \(pid)") didn't come to the front in \(Int(limit)) s: \(holder?.localizedName ?? "another app") (pid \(holder?.processIdentifier ?? 0)) keeps it. macOS lets the app in front refuse; bring the test copy forward or leave the Mac alone, and run the check again.")
exit(1)
