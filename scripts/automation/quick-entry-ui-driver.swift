// Drives the real quick entry panel for remote-quick-entry-check.py: posts
// key events through the HID event tap, reads and presses Accessibility
// elements, and writes the pasteboard. It needs the Accessibility grant that
// an SSH session's compiled tools have on the remote Mac, and an unlocked
// screen.
//
// Usage: quick-entry-ui-driver <command> [arguments]
//   locked                              prints 1 when the screen is locked
//   activate <bundle-id>                makes an app frontmost
//   frontmost                           prints the frontmost app's bundle ID
//   key <virtual-key> [cmd,ctrl,opt,shift]
//   type <text>                         types text as key events
//   windows <pid>                       prints the app's windows as JSON
//   value <pid> <identifier>            prints an element's value or title
//   press-menu <pid> <identifier> <item-title>
//   pasteboard-png <path>               puts a PNG on the general pasteboard

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func find(_ element: AXUIElement, depth: Int = 0, where match: (AXUIElement) -> Bool) -> AXUIElement? {
    if match(element) { return element }
    guard depth < 40 else { return nil }
    for child in children(element) {
        if let found = find(child, depth: depth + 1, where: match) { return found }
    }
    return nil
}

func identifier(_ element: AXUIElement) -> String? {
    attribute(element, "AXIdentifier") as? String
}

func application(_ pidText: String) -> AXUIElement {
    guard let pid = pid_t(pidText) else { fail("bad pid \(pidText)") }
    return AXUIElementCreateApplication(pid)
}

func windows(of app: AXUIElement) -> [AXUIElement] {
    (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
}

func element(in app: AXUIElement, identifier wanted: String) -> AXUIElement? {
    for window in windows(of: app) {
        if let found = find(window, where: { identifier($0) == wanted }) { return found }
    }
    return nil
}

func post(key: CGKeyCode, flags: CGEventFlags) {
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else {
            fail("could not make a key event")
        }
        event.flags = flags
        event.post(tap: .cghidEventTap)
        usleep(20_000)
    }
}

func flags(_ text: String?) -> CGEventFlags {
    var result: CGEventFlags = []
    for name in (text ?? "").split(separator: ",") {
        switch name {
        case "cmd": result.insert(.maskCommand)
        case "ctrl": result.insert(.maskControl)
        case "opt": result.insert(.maskAlternate)
        case "shift": result.insert(.maskShift)
        default: fail("unknown modifier \(name)")
        }
    }
    return result
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail("no command") }

switch command {
case "locked":
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    print((session?["CGSSessionScreenIsLocked"] as? Bool) == true ? "1" : "0")

case "activate":
    guard arguments.count == 2,
          let app = NSRunningApplication.runningApplications(withBundleIdentifier: arguments[1]).first else {
        fail("app \(arguments.dropFirst()) is not running")
    }
    app.activate(options: [])
    let element = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

case "frontmost":
    print(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")

case "key":
    guard arguments.count >= 2, let code = CGKeyCode(arguments[1]) else { fail("key <virtual-key> [modifiers]") }
    post(key: code, flags: flags(arguments.count > 2 ? arguments[2] : nil))

case "type":
    guard arguments.count == 2 else { fail("type <text>") }
    let source = CGEventSource(stateID: .hidSystemState)
    for character in arguments[1] {
        let units = Array(String(character).utf16)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else {
                fail("could not make a key event")
            }
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            event.post(tap: .cghidEventTap)
        }
        usleep(8_000)
    }

case "windows":
    guard arguments.count == 2 else { fail("windows <pid>") }
    let app = application(arguments[1])
    let listed = windows(of: app).map { window -> [String: String] in
        [
            "identifier": identifier(window) ?? "",
            "title": attribute(window, kAXTitleAttribute) as? String ?? "",
            "subrole": attribute(window, kAXSubroleAttribute) as? String ?? "",
            "focused": (attribute(window, kAXFocusedAttribute) as? Bool) == true ? "1" : "0",
        ]
    }
    let data = try JSONSerialization.data(withJSONObject: listed)
    print(String(decoding: data, as: UTF8.self))

case "value":
    guard arguments.count == 3 else { fail("value <pid> <identifier>") }
    guard let found = element(in: application(arguments[1]), identifier: arguments[2]) else {
        fail("no element \(arguments[2])")
    }
    let value = attribute(found, kAXValueAttribute) as? String
        ?? attribute(found, kAXTitleAttribute) as? String
        ?? attribute(found, kAXDescriptionAttribute) as? String
        ?? ""
    print(value)

case "press-menu":
    guard arguments.count == 4 else { fail("press-menu <pid> <identifier> <item-title>") }
    let app = application(arguments[1])
    guard let button = element(in: app, identifier: arguments[2]) else { fail("no element \(arguments[2])") }
    AXUIElementPerformAction(button, kAXPressAction as CFString)
    var item: AXUIElement?
    for _ in 0..<50 {
        usleep(100_000)
        // The open menu hangs under the button, or the app.
        item = find(button, where: { attribute($0, kAXTitleAttribute) as? String == arguments[3]
            && attribute($0, kAXRoleAttribute) as? String == kAXMenuItemRole })
            ?? find(app, where: { attribute($0, kAXTitleAttribute) as? String == arguments[3]
                && attribute($0, kAXRoleAttribute) as? String == kAXMenuItemRole })
        if item != nil { break }
    }
    guard let item else { fail("no menu item \(arguments[3])") }
    AXUIElementPerformAction(item, kAXPressAction as CFString)

case "pasteboard-png":
    guard arguments.count == 2, let data = FileManager.default.contents(atPath: arguments[1]) else {
        fail("pasteboard-png <path>")
    }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setData(data, forType: .png)

default:
    fail("unknown command \(command)")
}
