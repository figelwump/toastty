// Drives one app's real UI through the Accessibility API and real input
// events, for a live check. It needs Accessibility permission for the
// process that runs it.
//
// Usage: ax-drive <pid> <command> [arguments]
//   activate                      Bring the app and its main window to the front.
//   frame <identifier>            Print the element's frame as "x y width height".
//   texts <identifier>            Print the text under the element, one item on each line.
//   status                        Print whether this process is trusted and the screen is locked.
//   click <identifier>            Click the middle of the element with the mouse.
//   click-prefix <prefix>         Click the first element whose identifier starts with `prefix`.
//   click-in <identifier> <label> Click the element with that label inside the element.
//   click-label <prefix>          Click the first element whose label starts with `prefix`.
//   label-frame <prefix>          Print the frame of the first element whose label starts with `prefix`.
//   click-text <fragment>         Click the middle of `fragment` inside a text area.
//   focus <identifier>            Click the element, so it takes the keyboard.
//   type <text>                   Type the text with key events.
//   key <return|shift-return|escape|cmd-period>
// `identifier` is an accessibility identifier. Exit code 2: not found.
import AppKit
import ApplicationServices
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 3, let pid = pid_t(arguments[1]) else {
    FileHandle.standardError.write(Data("usage: ax-drive <pid> <command> [arguments]\n".utf8))
    exit(64)
}
let command = arguments[2]
let argument = arguments.count > 3 ? arguments[3] : ""
let app = AXUIElementCreateApplication(pid)

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func find(_ element: AXUIElement, where matches: (AXUIElement) -> Bool, depth: Int = 0) -> AXUIElement? {
    if matches(element) { return element }
    guard depth < 60 else { return nil }
    for child in children(element) {
        if let found = find(child, where: matches, depth: depth + 1) { return found }
    }
    return nil
}

func waitFor(_ description: String, _ probe: () -> AXUIElement?) -> AXUIElement {
    for _ in 0 ..< 40 {
        if let found = probe() { return found }
        usleep(150_000)
    }
    print("NOT FOUND \(description)")
    exit(2)
}

func element(identifier: String) -> AXUIElement {
    waitFor(identifier) { find(app) { attribute($0, kAXIdentifierAttribute) as? String == identifier } }
}

func frame(_ element: AXUIElement) -> CGRect? {
    guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute) else { return nil }
    var origin = CGPoint.zero
    var extent = CGSize.zero
    AXValueGetValue(position as! AXValue, .cgPoint, &origin)
    AXValueGetValue(size as! AXValue, .cgSize, &extent)
    return CGRect(origin: origin, size: extent)
}

func texts(_ element: AXUIElement, depth: Int = 0) -> [String] {
    var result: [String] = []
    for name in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
        if let text = attribute(element, name) as? String, text.isEmpty == false { result.append(text) }
    }
    guard depth < 60 else { return result }
    for child in children(element) { result += texts(child, depth: depth + 1) }
    return result
}

func click(at point: CGPoint) {
    let source = CGEventSource(stateID: .hidSystemState)
    for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        event?.post(tap: .cghidEventTap)
        usleep(60_000)
    }
}

func press(keyCode: CGKeyCode, flags: CGEventFlags = []) {
    let source = CGEventSource(stateID: .hidSystemState)
    for keyDown in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
        usleep(40_000)
    }
}

func type(_ text: String) {
    let source = CGEventSource(stateID: .hidSystemState)
    for character in text {
        let units = Array(String(character).utf16)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
            event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            event?.post(tap: .cghidEventTap)
            usleep(12_000)
        }
    }
}

func activate() {
    NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
    AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    if let window = (attribute(app, kAXWindowsAttribute) as? [AXUIElement])?.first {
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }
    usleep(400_000)
}

switch command {
case "status":
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    let locked = (session?["CGSSessionScreenIsLocked"] as? Bool) ?? false
    print("trusted=\(AXIsProcessTrusted()) locked=\(locked)")
case "click-prefix":
    let target = waitFor("identifier \(argument)…") {
        find(app) { (attribute($0, kAXIdentifierAttribute) as? String)?.hasPrefix(argument) == true }
    }
    guard let rect = frame(target) else { exit(2) }
    activate()
    click(at: CGPoint(x: rect.midX, y: rect.midY))
    print("clicked \(attribute(target, kAXIdentifierAttribute) as? String ?? argument) at \(Int(rect.midX)),\(Int(rect.midY))")
case "click-label", "label-frame":
    let target = waitFor("label \(argument)…") {
        find(app) { candidate in
            [kAXTitleAttribute, kAXDescriptionAttribute].contains {
                (attribute(candidate, $0) as? String)?.hasPrefix(argument) == true
            }
        }
    }
    guard let rect = frame(target) else { exit(2) }
    if command == "label-frame" {
        print("\(Int(rect.minX)) \(Int(rect.minY)) \(Int(rect.width)) \(Int(rect.height))")
        break
    }
    activate()
    click(at: CGPoint(x: rect.midX, y: rect.midY))
    print("clicked label \(argument) at \(Int(rect.midX)),\(Int(rect.midY))")
case "click-in":
    let label = arguments.count > 4 ? arguments[4] : ""
    let container = element(identifier: argument)
    let target = waitFor("\(label) in \(argument)") {
        find(container) { candidate in
            [kAXTitleAttribute, kAXDescriptionAttribute].contains { attribute(candidate, $0) as? String == label }
        }
    }
    guard let rect = frame(target) else { exit(2) }
    activate()
    click(at: CGPoint(x: rect.midX, y: rect.midY))
    print("clicked \(label) in \(argument) at \(Int(rect.midX)),\(Int(rect.midY))")
case "activate":
    activate()
    print("frontmost \(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)")
case "frame":
    guard let rect = frame(element(identifier: argument)) else { exit(2) }
    print("\(Int(rect.minX)) \(Int(rect.minY)) \(Int(rect.width)) \(Int(rect.height))")
case "texts":
    print(texts(element(identifier: argument)).joined(separator: "\n"))
case "click", "focus":
    guard let rect = frame(element(identifier: argument)) else { exit(2) }
    activate()
    click(at: CGPoint(x: rect.midX, y: rect.midY))
    print("clicked \(argument) at \(Int(rect.midX)),\(Int(rect.midY))")
case "click-text":
    // The text area that shows the fragment, and where the fragment is in it.
    var range = CFRange()
    let area = waitFor("text \(argument)") {
        find(app) { candidate in
            guard let value = attribute(candidate, kAXValueAttribute) as? String,
                  attribute(candidate, kAXRoleAttribute) as? String == (kAXTextAreaRole as String) else { return false }
            let found = (value as NSString).range(of: argument)
            guard found.location != NSNotFound else { return false }
            range = CFRange(location: found.location, length: found.length)
            return true
        }
    }
    guard let rangeValue = AXValueCreate(.cfRange, &range) else { exit(2) }
    var boundsValue: AnyObject?
    guard AXUIElementCopyParameterizedAttributeValue(
        area, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &boundsValue
    ) == .success, let boundsValue else {
        print("NO BOUNDS for \(argument)")
        exit(2)
    }
    var bounds = CGRect.zero
    AXValueGetValue(boundsValue as! AXValue, .cgRect, &bounds)
    activate()
    click(at: CGPoint(x: bounds.midX, y: bounds.midY))
    print("clicked text \(argument) at \(Int(bounds.midX)),\(Int(bounds.midY))")
case "type":
    type(argument)
    print("typed \(argument.count) characters")
case "key":
    switch argument {
    case "return": press(keyCode: 36)
    case "shift-return": press(keyCode: 36, flags: .maskShift)
    case "escape": press(keyCode: 53)
    case "cmd-period": press(keyCode: 47, flags: .maskCommand)
    default:
        print("unknown key \(argument)")
        exit(64)
    }
    print("pressed \(argument)")
default:
    print("unknown command \(command)")
    exit(64)
}
