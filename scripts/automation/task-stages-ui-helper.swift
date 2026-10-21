// Window helpers for remote-task-stages-check.py, by process ID, so a
// second Toastty instance with the same bundle ID is not confused with the
// first. Capturing needs Screen Recording for the calling tool and an
// unlocked screen.
//
// Usage: task-stages-ui-helper <command> [arguments]
//   capture <pid> <output.png>   captures the app's largest window, unfocused
//   activate <pid>               makes the app frontmost
//   frontmost-pid                prints the frontmost app's process ID
//   press <pid> <identifier>     presses the element with that
//                                Accessibility identifier

import AppKit
import CoreGraphics
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "capture":
    guard arguments.count == 3, let pid = Int32(arguments[1]) else { fail("capture <pid> <output.png>") }
    let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]) ?? []
    func area(_ window: [String: Any]) -> Double {
        let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
        return (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
    }
    guard let window = windows
        .filter({ ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 })
        .max(by: { area($0) < area($1) }),
        let number = window[kCGWindowNumber as String] as? Int else {
        fail("no on-screen window for pid \(pid)")
    }
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-o", "-l", String(number), arguments[2]]
    do { try capture.run() } catch { fail("screencapture did not start: \(error)") }
    capture.waitUntilExit()
    guard capture.terminationStatus == 0 else { fail("screencapture exited \(capture.terminationStatus)") }

case "activate":
    guard arguments.count == 2, let pid = Int32(arguments[1]),
          let app = NSRunningApplication(processIdentifier: pid) else { fail("activate <pid>: no such app") }
    app.activate(options: [])
    let element = AXUIElementCreateApplication(pid)
    AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

case "frontmost-pid":
    print(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)

case "press":
    guard arguments.count == 3, let pid = Int32(arguments[1]) else { fail("press <pid> <identifier>") }
    func value(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var result: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }
    func find(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        if value(element, "AXIdentifier") as? String == arguments[2] { return element }
        guard depth < 40 else { return nil }
        for child in (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            if let found = find(child, depth: depth + 1) { return found }
        }
        return nil
    }
    let app = AXUIElementCreateApplication(pid)
    let windows = (value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    guard let target = windows.lazy.compactMap({ find($0, depth: 0) }).first else {
        fail("no element \(arguments[2]) in pid \(pid)")
    }
    let error = AXUIElementPerformAction(target, kAXPressAction as CFString)
    guard error == .success else { fail("pressing \(arguments[2]) failed: \(error.rawValue)") }

default:
    fail("unknown command \(arguments.first ?? "")")
}
