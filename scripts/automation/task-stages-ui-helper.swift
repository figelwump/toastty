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
//                                Accessibility identifier, or clicks it
//   exists <pid> <identifier>    exits 0 when the element is on screen
//   dump <pid>                   prints each element's depth, role,
//                                identifier and frame

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

case "press", "exists":
    guard arguments.count == 3, let pid = Int32(arguments[1]) else { fail("\(arguments[0]) <pid> <identifier>") }
    func value(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var result: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }
    func find(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        if value(element, "AXIdentifier") as? String == arguments[2] { return element }
        // SwiftUI nests the workspace content deeply.
        guard depth < 120 else { return nil }
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
    if arguments[0] == "exists" { break }
    if AXUIElementPerformAction(target, kAXPressAction as CFString) == .success { break }
    // Some SwiftUI buttons refuse AXPress; click the middle of the element
    // instead, with the app in front so the click reaches it.
    guard let positionValue = value(target, kAXPositionAttribute), let sizeValue = value(target, kAXSizeAttribute) else {
        fail("\(arguments[2]) has no frame to click")
    }
    var origin = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    NSRunningApplication(processIdentifier: pid)?.activate(options: [])
    AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    usleep(300_000)
    let point = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        guard let event = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left) else { fail("could not make a click") }
        event.post(tap: .cghidEventTap)
        usleep(60_000)
    }

case "dump":
    guard arguments.count == 2, let pid = Int32(arguments[1]) else { fail("dump <pid>") }
    func value(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var result: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }
    func describe(_ element: AXUIElement, depth: Int) {
        var origin = CGPoint.zero
        var size = CGSize.zero
        if let position = value(element, kAXPositionAttribute) { AXValueGetValue(position as! AXValue, .cgPoint, &origin) }
        if let extent = value(element, kAXSizeAttribute) { AXValueGetValue(extent as! AXValue, .cgSize, &size) }
        let role = value(element, kAXRoleAttribute) as? String ?? "?"
        let identifier = value(element, "AXIdentifier") as? String ?? ""
        let title = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].lazy
            .compactMap { value(element, $0) as? String }.first { $0.isEmpty == false } ?? ""
        print("\(depth) \(role) id=\(identifier) title=\(title.prefix(40)) frame=\(Int(origin.x)),\(Int(origin.y)) \(Int(size.width))x\(Int(size.height))")
        guard depth < 150 else { return }
        for child in (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            describe(child, depth: depth + 1)
        }
    }
    for window in (value(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
        describe(window, depth: 0)
    }

default:
    fail("unknown command \(arguments.first ?? "")")
}
