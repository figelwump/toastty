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
//   click-last-label <prefix>     Click the last such element: in a transcript, the newest row.
//   label-frame <prefix>          Print the frame of the first element whose label starts with `prefix`.
//   click-text <fragment>         Click the middle of `fragment` inside a text area.
//   hover-text <fragment>         Move the pointer over the middle of `fragment`, with no click,
//                                 and print the point as "x y".
//   click-label-below <prefix> <y>
//                                 Click the element whose label starts with `prefix` and whose top
//                                 is nearest below `y`: the button under the message at `y`.
//   focus <identifier>            Click the element, so it takes the keyboard.
//   type <text>                   Type the text with key events.
//   key <return|shift-return|escape|up|down|tab|delete|cmd-a|cmd-c|cmd-z|cmd-period|cmd-shift-p|cmd-v|cmd-shift-g>
//   click-at <x> <y>              Click the point without bringing the app forward, as in an open menu.
//   drag <x1> <y1> <x2> <y2>      Press at the first point, move to the second with the button down,
//                                 and let go there: a drag and drop, as a hand makes it.
//   sheet-texts                   Print the text of the sheet on a window. Exit code 2: no sheet shows.
//   window-frame                  Print the frame of the app's first window as "x y width height".
//   window-set-frame <x> <y> <width> <height>
//                                 Move and size the app's first window, and print its frame.
//   menu <menu> <item>            Open the menu in the menu bar and choose the item.
//   menu-enabled <menu> <item>    Open the menu, print "enabled" or "disabled" for the item, and close the menu.
//   menu-open <menu>              Open the menu and leave it open. `key escape` closes it.
// `identifier` is an accessibility identifier. Exit code 2: not found.
// Exit code 4: a system prompt, such as a permission question, covers the
// place to click. No click is made: that prompt is the user's to answer.
// Exit code 5: another app's window covers the place to click. No click is
// made: the click and the keys after it would go to that app.
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

func findAll(_ element: AXUIElement, where matches: (AXUIElement) -> Bool, depth: Int = 0) -> [AXUIElement] {
    var found = matches(element) ? [element] : []
    guard depth < 60 else { return found }
    for child in children(element) { found += findAll(child, where: matches, depth: depth + 1) }
    return found
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

/// The processes that show the system's own prompts: a permission question
/// or a crash report.
let systemPromptOwners: Set<String> = ["UserNotificationCenter", "CoreServicesUIAgent", "SecurityAgent"]

/// Stops when a system prompt covers the point. A click there would answer
/// that prompt, which is the user's to answer, and would not reach the app.
/// With `orAnotherApp`, also stops when another app's window covers the
/// point (exit code 5): the click, and the keys typed after it, would go to
/// that app, such as the app of another check on a shared Mac.
func requireNoSystemPrompt(at point: CGPoint, orAnotherApp: Bool = false) {
    // Front to back: the app's own window in front of a prompt is fine.
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for window in windows {
        guard let bounds = window[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(point),
              (window[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
        let ownerPID = (window[kCGWindowOwnerPID as String] as? Int).map { pid_t($0) }
        if ownerPID == pid { return }
        let owner = window[kCGWindowOwnerName as String] as? String ?? ""
        if systemPromptOwners.contains(owner) {
            print("COVERED \(Int(point.x)),\(Int(point.y)) is under a system prompt of \(owner)")
            exit(4)
        }
        if orAnotherApp, owner != "Window Server", owner != "Dock" {
            print("COVERED \(Int(point.x)),\(Int(point.y)) is under a window of \(owner) (pid \(ownerPID ?? 0))")
            exit(5)
        }
    }
}

func click(at point: CGPoint) {
    requireNoSystemPrompt(at: point, orAnotherApp: true)
    let source = CGEventSource(stateID: .hidSystemState)
    for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        event?.post(tap: .cghidEventTap)
        usleep(60_000)
    }
}

func press(keyCode: CGKeyCode, flags: CGEventFlags = []) {
    let source = CGEventSource(stateID: .hidSystemState)
    func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
        usleep(40_000)
    }
    // The modifier keys go down before the key and up after it, as on a
    // keyboard. With the flags alone, the keys typed next would still
    // carry the modifiers.
    let modifierKeys: [(flag: CGEventFlags, key: CGKeyCode)] = [
        (.maskCommand, 55), (.maskShift, 56), (.maskAlternate, 58), (.maskControl, 59),
    ].filter { flags.contains($0.flag) }
    var held: CGEventFlags = []
    for modifier in modifierKeys {
        held.insert(modifier.flag)
        post(modifier.key, down: true, flags: held)
    }
    for keyDown in [true, false] { post(keyCode, down: keyDown, flags: flags) }
    for modifier in modifierKeys.reversed() {
        held.remove(modifier.flag)
        post(modifier.key, down: false, flags: held)
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

func drag(from start: CGPoint, to end: CGPoint) {
    requireNoSystemPrompt(at: end)
    let source = CGEventSource(stateID: .hidSystemState)
    func post(_ type: CGEventType, _ point: CGPoint) {
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }
    post(.mouseMoved, start)
    usleep(150_000)
    post(.leftMouseDown, start)
    usleep(200_000)
    // Small steps, so the source starts its drag and each view on the way
    // sees the drag enter.
    let steps = 40
    for step in 1 ... steps {
        let progress = CGFloat(step) / CGFloat(steps)
        post(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * progress, y: start.y + (end.y - start.y) * progress))
        usleep(25_000)
    }
    // Rest over the target before letting go, as a hand does.
    for _ in 0 ..< 10 {
        post(.leftMouseDragged, end)
        usleep(50_000)
    }
    post(.leftMouseUp, end)
    usleep(300_000)
}

/// The screen rectangle of `fragment` inside the text area that shows it.
func textBounds(_ fragment: String) -> CGRect {
    var range = CFRange()
    let area = waitFor("text \(fragment)") {
        find(app) { candidate in
            guard let value = attribute(candidate, kAXValueAttribute) as? String,
                  attribute(candidate, kAXRoleAttribute) as? String == (kAXTextAreaRole as String) else { return false }
            let found = (value as NSString).range(of: fragment)
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
        print("NO BOUNDS for \(fragment)")
        exit(2)
    }
    var bounds = CGRect.zero
    AXValueGetValue(boundsValue as! AXValue, .cgRect, &bounds)
    return bounds
}

/// Moves the pointer in a few steps, as a hand does, so that the views on
/// the way see it enter.
func move(to point: CGPoint) {
    requireNoSystemPrompt(at: point, orAnotherApp: true)
    let source = CGEventSource(stateID: .hidSystemState)
    for offset in [CGFloat(-12), -6, 0] {
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                mouseCursorPosition: CGPoint(x: point.x + offset, y: point.y), mouseButton: .left)?
            .post(tap: .cghidEventTap)
        usleep(80_000)
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

/// The item of a menu in the menu bar, once the menu is open.
func menuItem(in barItem: AXUIElement, titled title: String) -> AXUIElement? {
    for menu in children(barItem) {
        if let item = children(menu).first(where: { attribute($0, kAXTitleAttribute) as? String == title }) {
            return item
        }
    }
    return nil
}

switch command {
case "sheet-texts":
    guard let sheet = find(app, where: { attribute($0, kAXRoleAttribute) as? String == (kAXSheetRole as String) }) else {
        print("NO SHEET")
        exit(2)
    }
    print(texts(sheet).joined(separator: "\n"))
case "window-frame":
    guard let window = (attribute(app, kAXWindowsAttribute) as? [AXUIElement])?.first, let rect = frame(window) else {
        print("NO WINDOW")
        exit(2)
    }
    print("\(Int(rect.minX)) \(Int(rect.minY)) \(Int(rect.width)) \(Int(rect.height))")
case "window-set-frame":
    let numbers = arguments.dropFirst(3).compactMap(Double.init)
    guard numbers.count == 4, let window = (attribute(app, kAXWindowsAttribute) as? [AXUIElement])?.first else {
        print("NO WINDOW, or not four numbers")
        exit(2)
    }
    var origin = CGPoint(x: numbers[0], y: numbers[1])
    var size = CGSize(width: numbers[2], height: numbers[3])
    // The position again after the size: a window can move when it grows.
    for attributeName in [kAXPositionAttribute, kAXSizeAttribute, kAXPositionAttribute] {
        let value = attributeName == kAXSizeAttribute ? AXValueCreate(.cgSize, &size) : AXValueCreate(.cgPoint, &origin)
        if let value { AXUIElementSetAttributeValue(window, attributeName as CFString, value) }
        usleep(150_000)
    }
    guard let rect = frame(window) else { exit(2) }
    print("\(Int(rect.minX)) \(Int(rect.minY)) \(Int(rect.width)) \(Int(rect.height))")
case "menu", "menu-enabled", "menu-open":
    let itemTitle = arguments.count > 4 ? arguments[4] : ""
    activate()
    let barItem = waitFor("menu \(argument)") {
        guard let bar = attribute(app, kAXMenuBarAttribute) else { return nil }
        return children(bar as! AXUIElement).first { attribute($0, kAXTitleAttribute) as? String == argument }
    }
    // Open the menu as a person does, so its items are as the user sees them.
    AXUIElementPerformAction(barItem, kAXPressAction as CFString)
    usleep(400_000)
    if command == "menu-open" {
        print("opened \(argument)")
        break
    }
    let item = waitFor("\(itemTitle) in the menu \(argument)") { menuItem(in: barItem, titled: itemTitle) }
    let enabled = (attribute(item, kAXEnabledAttribute) as? Bool) ?? false
    if command == "menu-enabled" {
        print(enabled ? "enabled" : "disabled")
        // An open menu takes the keys and clicks that follow.
        press(keyCode: 53)
        break
    }
    guard enabled else {
        press(keyCode: 53)
        print("DISABLED \(itemTitle)")
        exit(3)
    }
    AXUIElementPerformAction(item, kAXPressAction as CFString)
    print("chose \(argument) > \(itemTitle)")
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
case "click-last-label":
    let target = waitFor("label \(argument)…") {
        findAll(app) { candidate in
            [kAXTitleAttribute, kAXDescriptionAttribute].contains {
                (attribute(candidate, $0) as? String)?.hasPrefix(argument) == true
            }
        }.last
    }
    guard let rect = frame(target) else { exit(2) }
    activate()
    click(at: CGPoint(x: rect.midX, y: rect.midY))
    print("clicked the last label \(argument) at \(Int(rect.midX)),\(Int(rect.midY))")
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
    let bounds = textBounds(argument)
    activate()
    click(at: CGPoint(x: bounds.midX, y: bounds.midY))
    print("clicked text \(argument) at \(Int(bounds.midX)),\(Int(bounds.midY))")
case "hover-text":
    let bounds = textBounds(argument)
    move(to: CGPoint(x: bounds.midX, y: bounds.midY))
    print("\(Int(bounds.midX)) \(Int(bounds.midY))")
case "click-label-below":
    guard arguments.count > 4, let top = Double(arguments[4]) else { exit(64) }
    let target = waitFor("label \(argument) below \(Int(top))") {
        findAll(app) { candidate in
            [kAXTitleAttribute, kAXDescriptionAttribute].contains {
                (attribute(candidate, $0) as? String)?.hasPrefix(argument) == true
            }
        }
        .compactMap { candidate in frame(candidate).map { (candidate, $0) } }
        .filter { $0.1.minY >= top }
        .min { $0.1.minY < $1.1.minY }?.0
    }
    guard let rect = frame(target) else { exit(2) }
    // No activation: it would move the pointer's window under the pointer.
    click(at: CGPoint(x: rect.midX, y: rect.midY))
    print("clicked label \(argument) at \(Int(rect.midX)),\(Int(rect.midY))")
case "click-at":
    guard arguments.count > 4, let x = Double(arguments[3]), let y = Double(arguments[4]) else { exit(64) }
    click(at: CGPoint(x: x, y: y))
    print("clicked at \(Int(x)),\(Int(y))")
case "drag":
    let numbers = arguments.dropFirst(3).compactMap(Double.init)
    guard numbers.count == 4 else { exit(64) }
    drag(from: CGPoint(x: numbers[0], y: numbers[1]), to: CGPoint(x: numbers[2], y: numbers[3]))
    print("dragged from \(Int(numbers[0])),\(Int(numbers[1])) to \(Int(numbers[2])),\(Int(numbers[3]))")
case "type":
    type(argument)
    print("typed \(argument.count) characters")
case "key":
    switch argument {
    case "return": press(keyCode: 36)
    case "shift-return": press(keyCode: 36, flags: .maskShift)
    case "cmd-return": press(keyCode: 36, flags: .maskCommand)
    case "escape": press(keyCode: 53)
    case "up": press(keyCode: 126)
    case "down": press(keyCode: 125)
    case "tab": press(keyCode: 48)
    case "delete": press(keyCode: 51)
    case "cmd-a": press(keyCode: 0, flags: .maskCommand)
    case "cmd-c": press(keyCode: 8, flags: .maskCommand)
    case "cmd-z": press(keyCode: 6, flags: .maskCommand)
    case "cmd-period": press(keyCode: 47, flags: .maskCommand)
    case "cmd-shift-p": press(keyCode: 35, flags: [.maskCommand, .maskShift])
    case "cmd-v": press(keyCode: 9, flags: .maskCommand)
    case "cmd-shift-g": press(keyCode: 5, flags: [.maskCommand, .maskShift])
    case "cmd-shift-k": press(keyCode: 40, flags: [.maskCommand, .maskShift])
    case "cmd-b": press(keyCode: 11, flags: .maskCommand)
    case "cmd-equal": press(keyCode: 24, flags: .maskCommand)
    case "cmd-0": press(keyCode: 29, flags: .maskCommand)
    case "cmd-w": press(keyCode: 13, flags: .maskCommand)
    default:
        print("unknown key \(argument)")
        exit(64)
    }
    print("pressed \(argument)")
default:
    print("unknown command \(command)")
    exit(64)
}
