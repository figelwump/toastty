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
//   activate-pid <pid>                  makes an app frontmost by process ID
//   frontmost-pid                       prints the frontmost app's process ID
//   frame <pid> <identifier>            prints an element's frame: x y width height
//   drag <from-x> <from-y> <to-x> <to-y>
//                                       drags with the mouse between two points
//   click <x> <y>                       clicks at a point
//   windows-at <x> <y>                  prints the windows under a point, front first, as JSON
//   pasteboard-text <text>              puts text on the general pasteboard
//   pasteboard-png <path>               puts a PNG on the general pasteboard
//   labels <pid> <identifier>           prints the labels of the elements with
//                                       that identifier, or of all with *, in
//                                       tree order, as JSON
//   texts <pid> <identifier|*>          prints the static texts under the
//                                       element, or in every window, as JSON
//   context-menu <pid> <identifier|*> <label-prefix|-> [item-title|@keep]
//                                       right-clicks the element, prints the
//                                       open menu's item titles as JSON, then
//                                       presses the item, leaves the menu open
//                                       with @keep, or closes it
//   close-menu <pid>                    closes the app's open menu
//   menu-frames <pid>                   prints the open menu's frame and its
//                                       items' titles and frames as JSON
//   dialog <pid>                        prints a dialog window's texts and
//                                       buttons as JSON, or {}
//   dialog-press <pid> <button-title>   presses a dialog window's button

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

/// Like `attribute`, but an Accessibility failure ends the run instead of
/// reading as "no value", so a failed read cannot pass for a closed panel.
func checkedAttribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    switch error {
    case .success: return value
    case .noValue, .attributeUnsupported: return nil
    default: fail("Accessibility could not read \(name): error \(error.rawValue)")
    }
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func find(
    _ element: AXUIElement,
    depth: Int = 0,
    skippingMenuBar: Bool = false,
    where match: (AXUIElement) -> Bool
) -> AXUIElement? {
    if skippingMenuBar, attribute(element, kAXRoleAttribute) as? String == kAXMenuBarRole { return nil }
    if match(element) { return element }
    guard depth < 40 else { return nil }
    for child in children(element) {
        if let found = find(child, depth: depth + 1, skippingMenuBar: skippingMenuBar, where: match) { return found }
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

/// Visits every element under `element`, as deep as SwiftUI nests the
/// workspace content.
func visit(_ element: AXUIElement, depth: Int = 0, _ body: (AXUIElement) -> Void) {
    body(element)
    guard depth < 150 else { return }
    for child in children(element) {
        visit(child, depth: depth + 1, body)
    }
}

/// An element's accessibility label: SwiftUI puts it in AXDescription,
/// AppKit buttons and menu items in AXTitle.
func label(_ element: AXUIElement) -> String {
    for name in [kAXDescriptionAttribute, kAXTitleAttribute] {
        if let text = attribute(element, name) as? String, text.isEmpty == false { return text }
    }
    return ""
}

func center(of element: AXUIElement) -> CGPoint? {
    guard let positionValue = attribute(element, kAXPositionAttribute),
          let sizeValue = attribute(element, kAXSizeAttribute) else { return nil }
    var origin = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    return CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
}

/// Waits for the app's open menu to close, so later keys reach the app,
/// and presses Esc if it stays open.
func waitForMenuToClose(_ app: AXUIElement) {
    func menuIsOpen() -> Bool {
        find(app, skippingMenuBar: true, where: { attribute($0, kAXRoleAttribute) as? String == kAXMenuRole }) != nil
    }
    for _ in 0..<30 where menuIsOpen() {
        usleep(100_000)
    }
    if menuIsOpen() {
        post(key: 53, flags: [])
    }
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
        // Paced like a fast typist: events posted closer together are
        // sometimes dropped by the event system.
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else {
                fail("could not make a key event")
            }
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            // Plain characters: an event takes the system's current modifier
            // state otherwise, and a stale Fn turns "f" into a menu shortcut.
            event.flags = []
            event.post(tap: .cghidEventTap)
            usleep(12_000)
        }
        usleep(30_000)
    }

case "windows":
    guard arguments.count == 2 else { fail("windows <pid>") }
    let app = application(arguments[1])
    let windowList = (checkedAttribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    let listed = windowList.map { window -> [String: String] in
        [
            "identifier": checkedAttribute(window, "AXIdentifier") as? String ?? "",
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

case "set-value":
    guard arguments.count == 4 else { fail("set-value <pid> <identifier> <text>") }
    guard let found = element(in: application(arguments[1]), identifier: arguments[2]) else {
        fail("no element \(arguments[2])")
    }
    let error = AXUIElementSetAttributeValue(found, kAXValueAttribute as CFString, arguments[3] as CFString)
    guard error == .success else { fail("could not set the value: error \(error.rawValue)") }

case "labels":
    guard arguments.count == 3 else { fail("labels <pid> <identifier>") }
    var labels: [String] = []
    for window in windows(of: application(arguments[1])) {
        visit(window) { if arguments[2] == "*" || identifier($0) == arguments[2] { labels.append(label($0)) } }
    }
    let data = try JSONSerialization.data(withJSONObject: labels)
    print(String(decoding: data, as: UTF8.self))

case "texts":
    guard arguments.count == 3 else { fail("texts <pid> <identifier|*>") }
    let app = application(arguments[1])
    let roots: [AXUIElement]
    if arguments[2] == "*" {
        roots = windows(of: app)
    } else {
        guard let found = element(in: app, identifier: arguments[2]) else { fail("no element \(arguments[2])") }
        roots = [found]
    }
    var texts: [String] = []
    for root in roots {
        visit(root) { element in
            if attribute(element, kAXRoleAttribute) as? String == kAXStaticTextRole,
               let value = attribute(element, kAXValueAttribute) as? String {
                texts.append(value)
            }
        }
    }
    let data = try JSONSerialization.data(withJSONObject: texts)
    print(String(decoding: data, as: UTF8.self))

case "context-menu":
    guard arguments.count == 4 || arguments.count == 5, let pid = pid_t(arguments[1]) else {
        fail("context-menu <pid> <identifier> <label-prefix|-> [item-title]")
    }
    let app = application(arguments[1])
    let prefix = arguments[3] == "-" ? "" : arguments[3]
    var target: AXUIElement?
    for window in windows(of: app) where target == nil {
        visit(window) { element in
            if target == nil, arguments[2] == "*" || identifier(element) == arguments[2], label(element).hasPrefix(prefix) {
                target = element
            }
        }
    }
    guard let target else { fail("no element \(arguments[2]) labelled \(prefix)") }
    // A real right-click, as a user opens the menu; AXShowMenu on a row
    // can open its parent's menu instead. A click while the app is still
    // coming to the front can miss, so it is tried again.
    var menu: AXUIElement?
    for _ in 0..<3 where menu == nil {
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        usleep(500_000)
        guard let center = center(of: target) else { fail("\(prefix) has no frame") }
        for type in [CGEventType.rightMouseDown, .rightMouseUp] {
            guard let event = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type,
                                      mouseCursorPosition: center, mouseButton: .right) else { fail("could not make a click") }
            event.post(tap: .cghidEventTap)
            usleep(60_000)
        }
        for _ in 0..<25 where menu == nil {
            usleep(100_000)
            menu = find(app, skippingMenuBar: true, where: { attribute($0, kAXRoleAttribute) as? String == kAXMenuRole })
        }
    }
    guard let menu else { fail("no context menu opened") }
    let items = children(menu).filter { attribute($0, kAXRoleAttribute) as? String == kAXMenuItemRole }
    // A divider is an item without a title.
    let titles = items.map { (attribute($0, kAXTitleAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "—" }
    let data = try JSONSerialization.data(withJSONObject: titles)
    print(String(decoding: data, as: UTF8.self))
    if arguments.count == 5, arguments[4] == "@keep" {
        break
    }
    if arguments.count == 5 {
        guard let item = items.first(where: { attribute($0, kAXTitleAttribute) as? String == arguments[4] }) else {
            AXUIElementPerformAction(menu, kAXCancelAction as CFString)
            fail("no menu item \(arguments[4])")
        }
        AXUIElementPerformAction(item, kAXPressAction as CFString)
    } else {
        AXUIElementPerformAction(menu, kAXCancelAction as CFString)
    }
    // Wait for the menu to close, so later keys reach the app.
    waitForMenuToClose(app)

case "menu-frames":
    guard arguments.count == 2 else { fail("menu-frames <pid>") }
    let app = application(arguments[1])
    guard let menu = find(app, skippingMenuBar: true, where: { attribute($0, kAXRoleAttribute) as? String == kAXMenuRole }) else {
        fail("no open menu")
    }
    func frame(_ element: AXUIElement) -> [Double] {
        var origin = CGPoint.zero
        var size = CGSize.zero
        if let position = attribute(element, kAXPositionAttribute) { AXValueGetValue(position as! AXValue, .cgPoint, &origin) }
        if let extent = attribute(element, kAXSizeAttribute) { AXValueGetValue(extent as! AXValue, .cgSize, &size) }
        return [origin.x, origin.y, size.width, size.height].map(Double.init)
    }
    let items = children(menu).filter { attribute($0, kAXRoleAttribute) as? String == kAXMenuItemRole }.map { item -> [String: Any] in
        ["title": attribute(item, kAXTitleAttribute) as? String ?? "", "frame": frame(item),
         "enabled": (attribute(item, kAXEnabledAttribute) as? Bool) ?? true]
    }
    let data = try JSONSerialization.data(withJSONObject: ["frame": frame(menu), "items": items])
    print(String(decoding: data, as: UTF8.self))

case "close-menu":
    guard arguments.count == 2 else { fail("close-menu <pid>") }
    let app = application(arguments[1])
    if let menu = find(app, skippingMenuBar: true, where: { attribute($0, kAXRoleAttribute) as? String == kAXMenuRole }) {
        AXUIElementPerformAction(menu, kAXCancelAction as CFString)
    }
    waitForMenuToClose(app)

case "dialog", "dialog-press":
    guard arguments.count == (arguments[0] == "dialog" ? 2 : 3) else { fail("dialog <pid> | dialog-press <pid> <button-title>") }
    let app = application(arguments[1])
    // NSAlert's window is a dialog; a SwiftUI alert is a sheet on its window.
    var dialog: AXUIElement?
    for window in windows(of: app) where dialog == nil {
        if ["AXDialog", "AXSystemDialog"].contains(attribute(window, kAXSubroleAttribute) as? String ?? "") {
            dialog = window
        } else {
            dialog = children(window).first { attribute($0, kAXRoleAttribute) as? String == "AXSheet" }
        }
    }
    guard let dialog else {
        guard arguments[0] == "dialog" else { fail("no dialog") }
        print("{}")
        break
    }
    var texts: [String] = []
    var buttons: [AXUIElement] = []
    visit(dialog) { element in
        switch attribute(element, kAXRoleAttribute) as? String {
        case kAXStaticTextRole?: (attribute(element, kAXValueAttribute) as? String).map { texts.append($0) }
        case kAXButtonRole?, kAXCheckBoxRole?: buttons.append(element)
        default: break
        }
    }
    if arguments[0] == "dialog-press" {
        guard let button = buttons.first(where: { label($0) == arguments[2] }) else { fail("no button \(arguments[2])") }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
        break
    }
    let data = try JSONSerialization.data(withJSONObject: ["texts": texts, "buttons": buttons.map(label)])
    print(String(decoding: data, as: UTF8.self))

case "press-menu":
    guard arguments.count == 4 else { fail("press-menu <pid> <identifier> <item-title>") }
    let app = application(arguments[1])
    guard let button = element(in: app, identifier: arguments[2]) else { fail("no element \(arguments[2])") }
    // A SwiftUI menu button offers AXShowMenu; other styles offer AXPress.
    var actionNames: CFArray?
    AXUIElementCopyActionNames(button, &actionNames)
    let opensWithShowMenu = ((actionNames as? [String]) ?? []).contains(kAXShowMenuAction)
    AXUIElementPerformAction(button, (opensWithShowMenu ? kAXShowMenuAction : kAXPressAction) as CFString)
    var item: AXUIElement?
    for _ in 0..<50 {
        usleep(100_000)
        // The open menu hangs under the button, or the app. The app's menu
        // bar can hold an item with the same title, such as a workspace.
        item = find(button, where: { attribute($0, kAXTitleAttribute) as? String == arguments[3]
            && attribute($0, kAXRoleAttribute) as? String == kAXMenuItemRole })
            ?? find(app, skippingMenuBar: true, where: { attribute($0, kAXTitleAttribute) as? String == arguments[3]
                && attribute($0, kAXRoleAttribute) as? String == kAXMenuItemRole })
        if item != nil { break }
    }
    guard let item else { fail("no menu item \(arguments[3])") }
    AXUIElementPerformAction(item, kAXPressAction as CFString)

case "focused":
    // The app's focused element, for diagnosing where key events go.
    guard arguments.count == 2 else { fail("focused <pid>") }
    let app = application(arguments[1])
    guard let focused = attribute(app, kAXFocusedUIElementAttribute) else {
        print("{}")
        break
    }
    let element = focused as! AXUIElement
    let described: [String: String] = [
        "role": attribute(element, kAXRoleAttribute) as? String ?? "",
        "identifier": identifier(element) ?? "",
        "value": attribute(element, kAXValueAttribute) as? String ?? "",
    ]
    let data = try JSONSerialization.data(withJSONObject: described)
    print(String(decoding: data, as: UTF8.self))

case "activate-pid":
    guard arguments.count == 2, let pid = pid_t(arguments[1]),
          let app = NSRunningApplication(processIdentifier: pid) else {
        fail("activate-pid <pid>")
    }
    app.activate(options: [])
    AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)

case "frontmost-pid":
    print(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)

case "frame":
    // An element's frame as "x y width height", in global coordinates with
    // the origin at the top left, as CGEvent uses.
    guard arguments.count == 3 else { fail("frame <pid> <identifier>") }
    guard let found = element(in: application(arguments[1]), identifier: arguments[2]) else {
        fail("no element \(arguments[2])")
    }
    var origin = CGPoint.zero, size = CGSize.zero
    guard let position = attribute(found, kAXPositionAttribute), let extent = attribute(found, kAXSizeAttribute),
          AXValueGetValue(position as! AXValue, .cgPoint, &origin),
          AXValueGetValue(extent as! AXValue, .cgSize, &size) else {
        fail("no frame for \(arguments[2])")
    }
    print("\(origin.x) \(origin.y) \(size.width) \(size.height)")

case "drag":
    // Presses at one point, moves in steps to another, waits there so the
    // destination sees the drag, and releases.
    let values = arguments.dropFirst().compactMap(Double.init)
    guard arguments.count == 5, values.count == 4 else {
        fail("drag <from-x> <from-y> <to-x> <to-y>")
    }
    let from = CGPoint(x: values[0], y: values[1]), to = CGPoint(x: values[2], y: values[3])
    let source = CGEventSource(stateID: .hidSystemState)
    func mouse(_ type: CGEventType, _ point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
            fail("could not make a mouse event")
        }
        event.flags = []
        event.post(tap: .cghidEventTap)
    }
    mouse(.mouseMoved, from)
    usleep(200_000)
    mouse(.leftMouseDown, from)
    usleep(200_000)
    let steps = 30
    for index in 1...steps {
        let t = Double(index) / Double(steps)
        mouse(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
        usleep(25_000)
    }
    for offset in [1.0, 2.0, 1.0, 0.0] {
        mouse(.leftMouseDragged, CGPoint(x: to.x + offset, y: to.y))
        usleep(120_000)
    }
    mouse(.leftMouseUp, to)
    usleep(300_000)

case "click":
    let values = arguments.dropFirst().compactMap(Double.init)
    guard arguments.count == 3, values.count == 2 else { fail("click <x> <y>") }
    let point = CGPoint(x: values[0], y: values[1])
    let source = CGEventSource(stateID: .hidSystemState)
    for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
            fail("could not make a mouse event")
        }
        event.flags = []
        event.post(tap: .cghidEventTap)
        usleep(120_000)
    }

case "windows-at":
    // The window server's front-to-back list under a point, for telling
    // whether a click there can reach the window it is meant for. A
    // click-through overlay is listed too, so read the list as a whole.
    let values = arguments.dropFirst().compactMap(Double.init)
    guard arguments.count == 3, values.count == 2 else { fail("windows-at <x> <y>") }
    let point = CGPoint(x: values[0], y: values[1])
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let found = list.compactMap { window -> [String: String]? in
        guard let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
              bounds.contains(point) else { return nil }
        return [
            "owner": window[kCGWindowOwnerName as String] as? String ?? "",
            "layer": "\(window[kCGWindowLayer as String] as? Int ?? 0)",
            "bounds": "\(bounds)",
        ]
    }
    let data = try JSONSerialization.data(withJSONObject: Array(found.prefix(4)))
    print(String(decoding: data, as: UTF8.self))

case "pasteboard-text":
    guard arguments.count == 2 else { fail("pasteboard-text <text>") }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(arguments[1], forType: .string)

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
