// Captures only one app's windows (ScreenCaptureKit), never the desktop, for site screenshots.
//   winshot --pid P [--only "Title prefix"] out.png
// Without --only: every on-screen window of the app, cropped to their union. With --only:
// windows whose title starts with the prefix, plus untitled ones (sheets, popovers) that
// overlap them.
import AppKit
import ScreenCaptureKit

var pid: pid_t = 0, only: String?, out = ""
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    if a == "--pid" { pid = pid_t(args.removeFirst()) ?? 0 } else if a == "--only" { only = args.removeFirst() } else { out = a }
}
guard pid != 0, !out.isEmpty else { FileHandle.standardError.write(Data("usage: winshot --pid P [--only prefix] out.png\n".utf8)); exit(2) }

let sem = DispatchSemaphore(value: 0)
Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var windows = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 40 && $0.frame.height > 40 }
        if let only {
            let main = windows.filter { ($0.title ?? "").hasPrefix(only) }
            let frame = main.reduce(CGRect.null) { $0.union($1.frame) }
            windows = main + windows.filter { ($0.title ?? "").isEmpty && $0.frame.intersects(frame) }
        }
        guard !windows.isEmpty, let display = content.displays.first(where: { $0.frame.intersects(windows[0].frame) }) ?? content.displays.first else {
            let seen = content.windows.filter { $0.owningApplication?.processID == pid }.map { "\($0.title ?? "nil") layer \($0.windowLayer) \(Int($0.frame.width))x\(Int($0.frame.height))" }
            FileHandle.standardError.write(Data("winshot: no matching windows; the app has: \(seen)\n".utf8)); exit(1)
        }
        let union = windows.reduce(CGRect.null) { $0.union($1.frame) }.intersection(display.frame)
        let filter = SCContentFilter(display: display, including: windows)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.sourceRect = CGRect(x: union.minX - display.frame.minX, y: union.minY - display.frame.minY, width: union.width, height: union.height)
        config.width = Int(union.width * scale)
        config.height = Int(union.height * scale)
        config.showsCursor = false
        config.backgroundColor = .clear
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let rep = NSBitmapImageRep(cgImage: image)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
        print("\(image.width)x\(image.height) \(windows.map { $0.title ?? "" })")
    } catch {
        FileHandle.standardError.write(Data("winshot: \(error.localizedDescription)\n".utf8)); exit(1)
    }
    sem.signal()
}
sem.wait()
