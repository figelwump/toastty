#if TOASTTY_HAS_GHOSTTY_KIT
import AppKit
import CoreState
import CoreVideo
import Darwin
import Foundation
import GhosttyKit
import UniformTypeIdentifiers

@MainActor
protocol GhosttyRuntimeActionHandling: AnyObject {
    func handleGhosttyRuntimeAction(_ action: GhosttyRuntimeAction) -> Bool
    func handleGhosttyCloseSurfaceRequest(surfaceHandle: UInt?, confirmed: Bool) -> Bool
}

struct GhosttyRuntimeAction: Sendable {
    enum Intent: Sendable {
        case split(SlotSplitDirection)
        case focus(SlotFocusDirection)
        case resizeSplit(SplitResizeDirection, amount: Int)
        case equalizeSplits
        case toggleFocusedPanelMode
        case startSearch(needle: String)
        case endSearch
        case searchTotal(Int?)
        case searchSelected(Int?)
        case setTerminalTitle(String)
        case setTerminalCWD(String)
        case showChildExited(exitCode: Int)
        case commandFinished(exitCode: Int?)
        case desktopNotification(title: String, body: String)
    }

    let surfaceHandle: UInt?
    let intent: Intent

    var logIntentName: String {
        switch intent {
        case .split(let direction):
            return "split.\(direction.rawValue)"
        case .focus(let direction):
            return "focus.\(direction.rawValue)"
        case .resizeSplit(let direction, _):
            return "resize_split.\(direction.rawValue)"
        case .equalizeSplits:
            return "equalize_splits"
        case .toggleFocusedPanelMode:
            return "toggle_focused_panel_mode"
        case .startSearch:
            return "start_search"
        case .endSearch:
            return "end_search"
        case .searchTotal:
            return "search_total"
        case .searchSelected:
            return "search_selected"
        case .setTerminalTitle:
            return "set_terminal_title"
        case .setTerminalCWD:
            return "set_terminal_cwd"
        case .showChildExited:
            return "show_child_exited"
        case .commandFinished:
            return "command_finished"
        case .desktopNotification:
            return "desktop_notification"
        }
    }
}

private final class GhosttyActionCallbackResult: @unchecked Sendable {
    var handled = false
}

private final class WeakTerminalHostViewBox {
    weak var value: TerminalHostView?

    init(_ value: TerminalHostView) {
        self.value = value
    }
}

private enum GhosttyDirectHostViewAction: Sendable {
    case mouseShape(surfaceHandle: UInt, shape: ghostty_action_mouse_shape_e)
    case mouseVisibility(surfaceHandle: UInt, visibility: ghostty_action_mouse_visibility_e)
    case mouseOverLink(surfaceHandle: UInt, url: String?, rawByteLength: Int)
    case scrollbar(surfaceHandle: UInt, totalRows: Int, offsetRows: Int, visibleRows: Int)

    var logIntentName: String {
        switch self {
        case .mouseShape:
            return "mouse_shape"
        case .mouseVisibility:
            return "mouse_visibility"
        case .mouseOverLink:
            return "mouse_over_link"
        case .scrollbar:
            return "scrollbar"
        }
    }
}

private func ghosttyString(
    pointer: UnsafePointer<CChar>?,
    length: Int
) -> String? {
    guard let pointer, length > 0 else {
        return nil
    }

    let bytePointer = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
    let buffer = UnsafeBufferPointer(start: bytePointer, count: length)
    return String(bytes: buffer, encoding: .utf8)
}

private enum GhosttyMainThreadAction: Sendable {
    case directHostView(GhosttyDirectHostViewAction)
    case runtime(GhosttyRuntimeAction)

    var logIntentName: String {
        switch self {
        case .directHostView(let action):
            return action.logIntentName
        case .runtime(let action):
            return action.logIntentName
        }
    }
}

private func ghosttyTargetName(_ target: ghostty_target_s) -> String {
    switch target.tag {
    case GHOSTTY_TARGET_SURFACE:
        return "surface"
    case GHOSTTY_TARGET_APP:
        return "app"
    default:
        return "unknown(\(target.tag.rawValue))"
    }
}

private func ghosttyActionName(_ action: ghostty_action_s) -> String {
    switch action.tag {
    case GHOSTTY_ACTION_NEW_SPLIT:
        return "new_split"
    case GHOSTTY_ACTION_GOTO_SPLIT:
        return "goto_split"
    case GHOSTTY_ACTION_RESIZE_SPLIT:
        return "resize_split"
    case GHOSTTY_ACTION_EQUALIZE_SPLITS:
        return "equalize_splits"
    case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
        return "toggle_split_zoom"
    case GHOSTTY_ACTION_START_SEARCH:
        return "start_search"
    case GHOSTTY_ACTION_END_SEARCH:
        return "end_search"
    case GHOSTTY_ACTION_SEARCH_TOTAL:
        return "search_total"
    case GHOSTTY_ACTION_SEARCH_SELECTED:
        return "search_selected"
    case GHOSTTY_ACTION_SCROLLBAR:
        return "scrollbar"
    case GHOSTTY_ACTION_SET_TITLE:
        return "set_title"
    case GHOSTTY_ACTION_PWD:
        return "pwd"
    case GHOSTTY_ACTION_MOUSE_SHAPE:
        return "mouse_shape"
    case GHOSTTY_ACTION_MOUSE_VISIBILITY:
        return "mouse_visibility"
    case GHOSTTY_ACTION_MOUSE_OVER_LINK:
        return "mouse_over_link"
    case GHOSTTY_ACTION_COMMAND_FINISHED:
        return "command_finished"
    case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
        return "desktop_notification"
    default:
        return "unknown(\(action.tag.rawValue))"
    }
}

private func makeGhosttyRuntimeAction(target: ghostty_target_s, action: ghostty_action_s) -> GhosttyRuntimeAction? {
    let surfaceHandle: UInt?
    switch target.tag {
    case GHOSTTY_TARGET_SURFACE:
        guard let surface = target.target.surface else {
            return nil
        }
        surfaceHandle = UInt(bitPattern: surface)

    case GHOSTTY_TARGET_APP:
        surfaceHandle = nil

    default:
        return nil
    }

    let intent: GhosttyRuntimeAction.Intent
    switch action.tag {
    case GHOSTTY_ACTION_NEW_SPLIT:
        guard let direction = SlotSplitDirection(ghosttyDirection: action.action.new_split) else {
            return nil
        }
        intent = .split(direction)

    case GHOSTTY_ACTION_GOTO_SPLIT:
        guard let direction = SlotFocusDirection(ghosttyDirection: action.action.goto_split) else {
            return nil
        }
        intent = .focus(direction)

    case GHOSTTY_ACTION_RESIZE_SPLIT:
        guard let direction = SplitResizeDirection(ghosttyDirection: action.action.resize_split.direction) else {
            return nil
        }
        intent = .resizeSplit(direction, amount: Int(action.action.resize_split.amount))

    case GHOSTTY_ACTION_EQUALIZE_SPLITS:
        intent = .equalizeSplits

    case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
        intent = .toggleFocusedPanelMode

    case GHOSTTY_ACTION_START_SEARCH:
        let needle = action.action.start_search.needle.map { String(cString: $0) } ?? ""
        intent = .startSearch(needle: needle)

    case GHOSTTY_ACTION_END_SEARCH:
        intent = .endSearch

    case GHOSTTY_ACTION_SEARCH_TOTAL:
        let rawTotal = Int(action.action.search_total.total)
        intent = .searchTotal(rawTotal >= 0 ? rawTotal : nil)

    case GHOSTTY_ACTION_SEARCH_SELECTED:
        let rawSelected = Int(action.action.search_selected.selected)
        intent = .searchSelected(rawSelected >= 0 ? rawSelected : nil)

    case GHOSTTY_ACTION_SET_TITLE:
        let title = action.action.set_title.title.map { String(cString: $0) } ?? ""
        intent = .setTerminalTitle(title)

    case GHOSTTY_ACTION_PWD:
        let pwd = action.action.pwd.pwd.map { String(cString: $0) } ?? ""
        intent = .setTerminalCWD(pwd)

    case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
        intent = .showChildExited(exitCode: Int(action.action.child_exited.exit_code))

    case GHOSTTY_ACTION_COMMAND_FINISHED:
        let rawExitCode = Int(action.action.command_finished.exit_code)
        let exitCode = rawExitCode >= 0 ? rawExitCode : nil
        intent = .commandFinished(exitCode: exitCode)

    case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
        let notification = action.action.desktop_notification
        let title = notification.title.map { String(cString: $0) } ?? ""
        let body = notification.body.map { String(cString: $0) } ?? ""
        intent = .desktopNotification(title: title, body: body)

    default:
        return nil
    }

    return GhosttyRuntimeAction(surfaceHandle: surfaceHandle, intent: intent)
}

private func makeGhosttyDirectHostViewAction(
    target: ghostty_target_s,
    action: ghostty_action_s
) -> GhosttyDirectHostViewAction? {
    switch action.tag {
    case GHOSTTY_ACTION_MOUSE_SHAPE:
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface else {
            return nil
        }
        return .mouseShape(
            surfaceHandle: UInt(bitPattern: surface),
            shape: action.action.mouse_shape
        )
    case GHOSTTY_ACTION_MOUSE_VISIBILITY:
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface else {
            return nil
        }
        return .mouseVisibility(
            surfaceHandle: UInt(bitPattern: surface),
            visibility: action.action.mouse_visibility
        )
    case GHOSTTY_ACTION_MOUSE_OVER_LINK:
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface else {
            return nil
        }
        let hoverLink = action.action.mouse_over_link
        let rawByteLength = Int(hoverLink.len)
        return .mouseOverLink(
            surfaceHandle: UInt(bitPattern: surface),
            url: ghosttyString(pointer: hoverLink.url, length: rawByteLength),
            rawByteLength: rawByteLength
        )
    case GHOSTTY_ACTION_SCROLLBAR:
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface else {
            return nil
        }
        let scrollbar = action.action.scrollbar
        return .scrollbar(
            surfaceHandle: UInt(bitPattern: surface),
            totalRows: Int(scrollbar.total),
            offsetRows: Int(scrollbar.offset),
            visibleRows: Int(scrollbar.len)
        )
    default:
        return nil
    }
}

private func makeGhosttyMainThreadAction(
    target: ghostty_target_s,
    action: ghostty_action_s
) -> GhosttyMainThreadAction? {
    if let directHostViewAction = makeGhosttyDirectHostViewAction(target: target, action: action) {
        return .directHostView(directHostViewAction)
    }
    if let runtimeAction = makeGhosttyRuntimeAction(target: target, action: action) {
        return .runtime(runtimeAction)
    }
    return nil
}

@MainActor
private func routeGhosttyMainThreadAction(
    _ action: GhosttyMainThreadAction,
    managerHandle: UInt
) -> Bool {
    switch action {
    case .directHostView(let directHostViewAction):
        return GhosttyRuntimeManager.shared.handleDirectHostViewAction(directHostViewAction)

    case .runtime(let runtimeAction):
        guard let pointer = UnsafeMutableRawPointer(bitPattern: managerHandle) else {
            ToasttyLog.warning("Ghostty callback missing manager pointer", category: .ghostty)
            return false
        }
        let manager = Unmanaged<GhosttyRuntimeManager>.fromOpaque(pointer).takeUnretainedValue()
        return manager.routeRuntimeAction(runtimeAction)
    }
}

private func ghosttyWakeupCallback(_ userdata: UnsafeMutableRawPointer?) {
    guard let userdata else { return }
    // Store as an integer handle to satisfy strict Sendable checks across dispatch hops.
    let managerHandle = UInt(bitPattern: userdata)
    DispatchQueue.main.async {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: managerHandle) else { return }
        let manager = Unmanaged<GhosttyRuntimeManager>.fromOpaque(pointer).takeUnretainedValue()
        // Tick directly once on the main queue — matching Ghostty's reference
        // wakeup implementation. The previous double-hop (dispatch → scheduleImmediateTick
        // → dispatch → tick) deferred the tick by an extra runloop cycle, allowing
        // variable amounts of SwiftUI layout work to interleave and cause irregular
        // cursor blink timing and sporadic input delays.
        // scheduleImmediateTick remains available for internal callers that need
        // reentrancy-safe deferral (e.g. requesting a tick from within a callback
        // that ghostty_app_tick itself triggered).
        manager.tick()
    }
}

@MainActor
private func handleGhosttyCloseSurfaceRequestOnMain(
    hostViewHandle: UInt,
    confirmed: Bool,
    callbackThread: String
) {
    let manager = GhosttyRuntimeManager.shared
    let surfaceHandle = manager.surfaceHandle(forHostViewHandle: hostViewHandle)
    if surfaceHandle == nil {
        ToasttyLog.debug(
            "Ghostty close-surface callback arrived after surface association was released",
            category: .ghostty,
            metadata: [
                "host_view_handle": String(hostViewHandle),
                "thread": callbackThread,
            ]
        )
    }
    let handled = manager.routeCloseSurfaceRequest(surfaceHandle: surfaceHandle, confirmed: confirmed)
    ToasttyLog.debug(
        "Handled Ghostty close-surface request",
        category: .ghostty,
        metadata: [
            "confirmed": confirmed ? "true" : "false",
            "handled": handled ? "true" : "false",
            "surface_handle": surfaceHandle.map(String.init) ?? "nil",
            "thread": callbackThread,
        ]
    )
}

private func ghosttyCloseSurfaceCallback(userdata: UnsafeMutableRawPointer?, confirmed: Bool) {
    guard let userdata else {
        ToasttyLog.warning("Ghostty close-surface callback missing userdata", category: .ghostty)
        return
    }

    let hostViewHandle = UInt(bitPattern: userdata)
    let callbackThread = Thread.isMainThread ? "main" : "background"
    // Ghostty passes surface userdata here, which Toastty sets to the host
    // view pointer. Defer close handling to the next main-queue turn so
    // Ghostty can finish unwinding Surface.close/childExited before Toastty
    // invalidates the controller and frees the surface.
    Task { @MainActor in
        handleGhosttyCloseSurfaceRequestOnMain(
            hostViewHandle: hostViewHandle,
            confirmed: confirmed,
            callbackThread: callbackThread
        )
    }
}

private func ghosttyActionCallback(app: ghostty_app_t?, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
    guard let app else {
        ToasttyLog.warning("Ghostty callback missing app handle", category: .ghostty)
        return false
    }
    guard let userdata = ghostty_app_userdata(app) else {
        ToasttyLog.warning("Ghostty callback missing app userdata", category: .ghostty)
        return false
    }
    guard let mainThreadAction = makeGhosttyMainThreadAction(target: target, action: action) else {
        ToasttyLog.debug(
            "Skipping Ghostty action without Toastty handler",
            category: .ghostty,
            metadata: [
                "target": ghosttyTargetName(target),
                "action": ghosttyActionName(action),
            ]
        )
        return false
    }

    // Keep callback semantics synchronous for Ghostty while safely hopping to main when needed.
    let managerHandle = UInt(bitPattern: userdata)
    if Thread.isMainThread {
        let handled = MainActor.assumeIsolated {
            routeGhosttyMainThreadAction(mainThreadAction, managerHandle: managerHandle)
        }
        ToasttyLog.debug(
            "Handled Ghostty runtime action",
            category: .ghostty,
            metadata: [
                "intent": mainThreadAction.logIntentName,
                "target": ghosttyTargetName(target),
                "handled": handled ? "true" : "false",
                "thread": "main",
            ]
        )
        return handled
    }

    let result = GhosttyActionCallbackResult()
    let semaphore = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
        result.handled = routeGhosttyMainThreadAction(mainThreadAction, managerHandle: managerHandle)
        semaphore.signal()
    }

    // Avoid deadlocking callback threads if the main queue is blocked behind runtime internals.
    guard semaphore.wait(timeout: .now() + .milliseconds(250)) == .success else {
        ToasttyLog.warning(
            "Ghostty action callback timed out waiting for main queue",
            category: .ghostty,
            metadata: [
                "intent": mainThreadAction.logIntentName,
                "target": ghosttyTargetName(target),
                "thread": "background",
            ]
        )
        return false
    }
    ToasttyLog.debug(
        "Handled Ghostty runtime action",
        category: .ghostty,
        metadata: [
            "intent": mainThreadAction.logIntentName,
            "target": ghosttyTargetName(target),
            "handled": result.handled ? "true" : "false",
            "thread": "background",
        ]
    )
    return result.handled
}

private struct GhosttyClipboardEntry {
    let mime: String
    let value: String
}

enum GhosttyClipboardBridge {
    nonisolated(unsafe) private static let selectionPasteboard = NSPasteboard.withUniqueName()
    static var selectionPasteboardName: NSPasteboard.Name {
        selectionPasteboard.name
    }
    static let supportsSelectionClipboard = true
    static var runtimeSupportsSelectionClipboard: Bool {
        makeGhosttyRuntimeConfig(userdata: nil).supports_selection_clipboard
    }

    static func pasteboard(for location: ghostty_clipboard_e) -> NSPasteboard? {
        switch location {
        case GHOSTTY_CLIPBOARD_STANDARD:
            return .general
        case GHOSTTY_CLIPBOARD_SELECTION:
            // macOS has no shared X11-style selection clipboard. Keep Ghostty's
            // selection buffer available for selection-paste semantics without
            // treating every text selection as an implicit system clipboard copy.
            return selectionPasteboard
        default:
            return nil
        }
    }

    static func releaseSelectionPasteboardIfNeeded() {
        selectionPasteboard.releaseGlobally()
    }
}

private func ghosttyPasteboard(for location: ghostty_clipboard_e) -> NSPasteboard? {
    GhosttyClipboardBridge.pasteboard(for: location)
}

private func ghosttyShellEscape(_ path: String) -> String {
    guard !path.isEmpty else { return "''" }
    return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func ghosttyClipboardStringContents(from pasteboard: NSPasteboard) -> String? {
    if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
       !urls.isEmpty {
        return urls
            .map { $0.isFileURL ? ghosttyShellEscape($0.path) : $0.absoluteString }
            .joined(separator: " ")
    }

    return pasteboard.string(forType: .string)
}

private func ghosttyClipboardLocationName(_ location: ghostty_clipboard_e) -> String {
    switch location {
    case GHOSTTY_CLIPBOARD_STANDARD:
        return "standard"
    case GHOSTTY_CLIPBOARD_SELECTION:
        return "selection"
    default:
        return "unknown(\(location.rawValue))"
    }
}

private func ghosttyClipboardRequestName(_ request: ghostty_clipboard_request_e) -> String {
    switch request {
    case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
        return "paste"
    case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ:
        return "osc_52_read"
    case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE:
        return "osc_52_write"
    default:
        return "unknown(\(request.rawValue))"
    }
}

private func ghosttyPasteboardType(for mime: String) -> NSPasteboard.PasteboardType {
    if mime == "text/plain" {
        return .string
    }
    if let type = UTType(mimeType: mime) {
        return NSPasteboard.PasteboardType(type.identifier)
    }
    return NSPasteboard.PasteboardType(mime)
}

private func ghosttyClipboardEntries(
    from content: UnsafePointer<ghostty_clipboard_content_s>?,
    count: Int
) -> [GhosttyClipboardEntry] {
    guard let content, count > 0 else { return [] }

    let buffer = UnsafeBufferPointer(start: content, count: count)
    return buffer.compactMap { entry in
        guard let mimePointer = entry.mime,
              let valuePointer = entry.data else {
            return nil
        }
        return GhosttyClipboardEntry(
            mime: String(cString: mimePointer),
            value: String(cString: valuePointer)
        )
    }
}

private func ghosttyCompleteClipboardRead(
    surface: ghostty_surface_t?,
    state: UnsafeMutableRawPointer?,
    data: String,
    confirmed: Bool
) {
    guard let state else {
        ToasttyLog.warning(
            "Skipping Ghostty clipboard completion because request state is missing",
            category: .ghostty
        )
        return
    }
    guard let surface else {
        ToasttyLog.debug(
            "Skipping Ghostty clipboard completion because surface is unavailable",
            category: .ghostty
        )
        return
    }
    data.withCString { pointer in
        ghostty_surface_complete_clipboard_request(surface, pointer, state, confirmed)
    }
}

private func ghosttyResolveSurfaceHandle(hostViewHandle: UInt) -> UInt? {
    MainActor.assumeIsolated {
        GhosttyRuntimeManager.shared.surfaceHandle(forHostViewHandle: hostViewHandle)
    }
}

private func ghosttyRunClipboardWorkOnMainThread(_ work: () -> Void) {
    if Thread.isMainThread {
        work()
        return
    }
    // Clipboard callbacks include C pointers that are only valid for the
    // callback lifetime, so complete the work synchronously before returning.
    DispatchQueue.main.sync(execute: work)
}

// Ghostty v1.3.1 expects this callback to report whether a request started,
// while older builds treat it as a fire-and-forget void callback.
@discardableResult
private func ghosttyReadClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    location: ghostty_clipboard_e,
    state: UnsafeMutableRawPointer?
) -> Bool {
    guard let userdata else {
        ToasttyLog.warning("Ghostty read clipboard callback missing userdata", category: .ghostty)
        return false
    }
    guard let state else { return false }

    let hostViewHandle = UInt(bitPattern: userdata)
    // This helper runs inline on main and synchronously hops to main otherwise,
    // so the callback result is determined before returning to Ghostty.
    var didStartRequest = false
    ghosttyRunClipboardWorkOnMainThread {
        let surfaceHandle = ghosttyResolveSurfaceHandle(hostViewHandle: hostViewHandle)
        guard let surfaceHandle else { return }
        guard let surface = ghostty_surface_t(bitPattern: surfaceHandle) else { return }
        guard let pasteboard = ghosttyPasteboard(for: location) else { return }
        guard let clipboardValue = ghosttyClipboardStringContents(from: pasteboard) else { return }
        ghosttyCompleteClipboardRead(
            surface: surface,
            state: state,
            data: clipboardValue,
            confirmed: false
        )
        didStartRequest = true
    }
    return didStartRequest
}

private func ghosttyConfirmReadClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    string: UnsafePointer<CChar>?,
    state: UnsafeMutableRawPointer?,
    request: ghostty_clipboard_request_e
) {
    guard let userdata else {
        ToasttyLog.warning("Ghostty confirm clipboard callback missing userdata", category: .ghostty)
        return
    }

    let hostViewHandle = UInt(bitPattern: userdata)
    let content = string.map { String(cString: $0) } ?? ""

    ghosttyRunClipboardWorkOnMainThread {
        let surfaceHandle = ghosttyResolveSurfaceHandle(hostViewHandle: hostViewHandle)
        let surface = surfaceHandle.flatMap { ghostty_surface_t(bitPattern: $0) }
        ToasttyLog.info(
            "Auto-confirming Ghostty clipboard request because Toastty has no confirmation UI yet",
            category: .ghostty,
            metadata: ["request": ghosttyClipboardRequestName(request)]
        )
        ghosttyCompleteClipboardRead(
            surface: surface,
            state: state,
            data: content,
            confirmed: true
        )
    }
}

private func ghosttyWriteClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    location: ghostty_clipboard_e,
    content: UnsafePointer<ghostty_clipboard_content_s>?,
    count: Int,
    confirm: Bool
) {
    guard userdata != nil else {
        ToasttyLog.warning("Ghostty write clipboard callback missing userdata", category: .ghostty)
        return
    }

    let entries = ghosttyClipboardEntries(from: content, count: count)
    guard entries.isEmpty == false else { return }
    let locationName = ghosttyClipboardLocationName(location)

    ghosttyRunClipboardWorkOnMainThread {
        guard let pasteboard = ghosttyPasteboard(for: location) else {
            ToasttyLog.warning(
                "Skipping Ghostty clipboard write for unsupported clipboard location",
                category: .ghostty,
                metadata: ["location": locationName]
            )
            return
        }

        if confirm {
            ToasttyLog.info(
                "Applying Ghostty clipboard write without confirmation prompt",
                category: .ghostty,
                metadata: ["location": locationName]
            )
        }

        let entriesByType = entries.map { (type: ghosttyPasteboardType(for: $0.mime), value: $0.value) }
        pasteboard.declareTypes(entriesByType.map(\.type), owner: nil)
        for entry in entriesByType {
            pasteboard.setString(entry.value, forType: entry.type)
        }
    }
}

private extension SlotSplitDirection {
    init?(ghosttyDirection: ghostty_action_split_direction_e) {
        switch ghosttyDirection {
        case GHOSTTY_SPLIT_DIRECTION_RIGHT:
            self = .right
        case GHOSTTY_SPLIT_DIRECTION_DOWN:
            self = .down
        case GHOSTTY_SPLIT_DIRECTION_LEFT:
            self = .left
        case GHOSTTY_SPLIT_DIRECTION_UP:
            self = .up
        default:
            return nil
        }
    }
}

private extension SlotFocusDirection {
    init?(ghosttyDirection: ghostty_action_goto_split_e) {
        switch ghosttyDirection {
        case GHOSTTY_GOTO_SPLIT_PREVIOUS:
            self = .previous
        case GHOSTTY_GOTO_SPLIT_NEXT:
            self = .next
        case GHOSTTY_GOTO_SPLIT_UP:
            self = .up
        case GHOSTTY_GOTO_SPLIT_DOWN:
            self = .down
        case GHOSTTY_GOTO_SPLIT_LEFT:
            self = .left
        case GHOSTTY_GOTO_SPLIT_RIGHT:
            self = .right
        default:
            return nil
        }
    }
}

private extension SplitResizeDirection {
    init?(ghosttyDirection: ghostty_action_resize_split_direction_e) {
        switch ghosttyDirection {
        case GHOSTTY_RESIZE_SPLIT_UP:
            self = .up
        case GHOSTTY_RESIZE_SPLIT_DOWN:
            self = .down
        case GHOSTTY_RESIZE_SPLIT_LEFT:
            self = .left
        case GHOSTTY_RESIZE_SPLIT_RIGHT:
            self = .right
        default:
            return nil
        }
    }
}

private func makeGhosttyRuntimeConfig(userdata: UnsafeMutableRawPointer?) -> ghostty_runtime_config_s {
    ghostty_runtime_config_s(
        userdata: userdata,
        // Ghostty only uses the selection-clipboard callbacks for selection
        // copy/paste semantics when the embedder advertises support here.
        supports_selection_clipboard: GhosttyClipboardBridge.supportsSelectionClipboard,
        wakeup_cb: { userdata in
            // Ghostty may invoke wakeup from a renderer thread; all app ticks must return to main.
            ghosttyWakeupCallback(userdata)
        },
        action_cb: { app, target, action in
            ghosttyActionCallback(app: app, target: target, action: action)
        },
        read_clipboard_cb: { userdata, location, state in
            ghosttyReadClipboardCallback(userdata: userdata, location: location, state: state)
        },
        confirm_read_clipboard_cb: { userdata, string, state, request in
            ghosttyConfirmReadClipboardCallback(
                userdata: userdata,
                string: string,
                state: state,
                request: request
            )
        },
        write_clipboard_cb: { userdata, location, content, count, confirm in
            ghosttyWriteClipboardCallback(
                userdata: userdata,
                location: location,
                content: content,
                count: count,
                confirm: confirm
            )
        },
        close_surface_cb: { userdata, confirmed in
            ghosttyCloseSurfaceCallback(userdata: userdata, confirmed: confirmed)
        }
    )
}

private enum GhosttyConfigSource: String {
    case envPath = "env_path"
    case userPath = "user_path"
    case defaultFiles = "default_files"
    case currentEffective = "current_effective"
}

@MainActor
final class GhosttyRuntimeManager {
    struct SurfaceCreationResult {
        let surface: ghostty_surface_t
        let workingDirectory: String
    }

    static let shared = GhosttyRuntimeManager()

    private static let ghosttyConfigPathEnvironmentKey = "TOASTTY_GHOSTTY_CONFIG_PATH"
    private static let ghosttyParseCLIArgsEnvironmentKey = "TOASTTY_GHOSTTY_PARSE_CLI_ARGS"
    private static let ghosttyResourcesDirectoryEnvironmentKey = "GHOSTTY_RESOURCES_DIR"

    weak var actionHandler: (any GhosttyRuntimeActionHandling)?

    private var app: ghostty_app_t?
    private var config: ghostty_config_t?
    private(set) var configuredTerminalFontPoints: Double?
    private var isTickScheduled = false
    private var displayLinkVsyncFallbackAttempted = false
    private var displayLinkVsyncFallbackActive = false
    private var surfaceHandleByHostViewHandle: [UInt: UInt] = [:]
    private var hostViewBySurfaceHandle: [UInt: WeakTerminalHostViewBox] = [:]

    private init() {
        guard Self.initializeGhosttyRuntime() else {
            ToasttyLog.error("Ghostty initialization failed", category: .ghostty)
            return
        }

        guard let config = ghostty_config_new() else {
            ToasttyLog.error("Ghostty config allocation failed", category: .ghostty)
            return
        }
        self.config = config

        let configSource = Self.loadGhosttyConfig(config)
        Self.logGhosttyConfigDiagnostics(config, source: configSource)
        configuredTerminalFontPoints = Self.resolveConfiguredTerminalFontPoints(config)
        Self.applyHostStyle(config)
        Self.withDebugLoginShellOverrideIfNeeded {
            ghostty_config_finalize(config)
        }

        var runtimeConfig = makeGhosttyRuntimeConfig(
            userdata: Unmanaged.passUnretained(self).toOpaque()
        )

        app = ghostty_app_new(&runtimeConfig, config)
        if app == nil {
            ToasttyLog.error("Ghostty runtime creation failed", category: .ghostty)
        }
        if let app {
            let initialAppFocus = NSApp?.isActive ?? false
            ghostty_app_set_focus(app, initialAppFocus)
        }
        scheduleImmediateTick()
    }

    func setAppFocus(_ focused: Bool) {
        guard let app else { return }
        ghostty_app_set_focus(app, focused)
    }

    func makeSurface(
        hostView: NSView,
        workingDirectory: String,
        fontPoints: Double,
        inheritFrom sourceSurface: ghostty_surface_t? = nil,
        launchConfiguration: TerminalSurfaceLaunchConfiguration = .empty
    ) -> SurfaceCreationResult? {
        guard let app else {
            ToasttyLog.warning(
                "Ghostty surface creation requested before app initialization",
                category: .ghostty,
                metadata: Self.surfaceCreationDiagnostics(
                    hostView: hostView,
                    fontPoints: fontPoints,
                    sourceSurface: sourceSurface,
                    launchConfiguration: launchConfiguration,
                    resolvedWorkingDirectory: Self.normalizedWorkingDirectoryValue(workingDirectory) ?? "nil"
                )
            )
            return nil
        }

        var surfaceConfig: ghostty_surface_config_s
        var inheritedWorkingDirectory: String?
        if let sourceSurface {
            surfaceConfig = ghostty_surface_inherited_config(sourceSurface, GHOSTTY_SURFACE_CONTEXT_SPLIT)
            if let inheritedPointer = surfaceConfig.working_directory {
                if let candidate = Self.normalizedWorkingDirectoryValue(String(cString: inheritedPointer)) {
                    inheritedWorkingDirectory = candidate
                }
            }
        } else {
            surfaceConfig = ghostty_surface_config_new()
        }

        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform.macos.nsview = Unmanaged.passUnretained(hostView).toOpaque()
        surfaceConfig.userdata = Unmanaged.passUnretained(hostView).toOpaque()
        let hostScale = hostView.window?.screen?.backingScaleFactor
            ?? hostView.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
        surfaceConfig.scale_factor = max(Double(hostScale), 1)
        surfaceConfig.font_size = Float(fontPoints)
        surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_SPLIT
        surfaceConfig.command = nil
        surfaceConfig.initial_input = nil
        surfaceConfig.env_vars = nil
        surfaceConfig.env_var_count = 0
        surfaceConfig.wait_after_command = false

        let requestedWorkingDirectory = Self.normalizedWorkingDirectoryValue(workingDirectory)
        let resolvedWorkingDirectory: String
        if let requestedWorkingDirectory {
            if let inheritedWorkingDirectory,
               requestedWorkingDirectory != inheritedWorkingDirectory {
                ToasttyLog.info(
                    "Split surface inherited cwd differed from requested cwd; using requested cwd",
                    category: .terminal,
                    metadata: [
                        "requested_cwd": requestedWorkingDirectory,
                        "inherited_cwd": inheritedWorkingDirectory,
                    ]
                )
            }
            resolvedWorkingDirectory = requestedWorkingDirectory
        } else if let inheritedWorkingDirectory {
            resolvedWorkingDirectory = inheritedWorkingDirectory
        } else {
            resolvedWorkingDirectory = NSHomeDirectory()
        }

        let surface = Self.createGhosttySurface(
            app: app,
            surfaceConfig: &surfaceConfig,
            resolvedWorkingDirectory: resolvedWorkingDirectory,
            launchConfiguration: launchConfiguration
        )
        if let surface {
            registerSurfaceAssociation(surface, forHostView: hostView)
            scheduleImmediateTick()
            ToasttyLog.debug(
                "Ghostty runtime created surface",
                category: .ghostty,
                metadata: Self.surfaceCreationDiagnostics(
                    hostView: hostView,
                    fontPoints: fontPoints,
                    sourceSurface: sourceSurface,
                    launchConfiguration: launchConfiguration,
                    resolvedWorkingDirectory: resolvedWorkingDirectory,
                    extra: ["surface_handle": String(UInt(bitPattern: surface))]
                )
            )
            return SurfaceCreationResult(
                surface: surface,
                workingDirectory: resolvedWorkingDirectory
            )
        }

        let failureMetadata = Self.surfaceCreationDiagnostics(
            hostView: hostView,
            fontPoints: fontPoints,
            sourceSurface: sourceSurface,
            launchConfiguration: launchConfiguration,
            resolvedWorkingDirectory: resolvedWorkingDirectory
        )
        if activateDisplayLinkVsyncFallbackIfNeeded(
            app: app,
            failureMetadata: failureMetadata
        ) {
            let retrySurface = Self.createGhosttySurface(
                app: app,
                surfaceConfig: &surfaceConfig,
                resolvedWorkingDirectory: resolvedWorkingDirectory,
                launchConfiguration: launchConfiguration
            )
            if let retrySurface {
                registerSurfaceAssociation(retrySurface, forHostView: hostView)
                scheduleImmediateTick()
                ToasttyLog.info(
                    "Ghostty runtime created surface after display-link vsync fallback",
                    category: .ghostty,
                    metadata: Self.surfaceCreationDiagnostics(
                        hostView: hostView,
                        fontPoints: fontPoints,
                        sourceSurface: sourceSurface,
                        launchConfiguration: launchConfiguration,
                        resolvedWorkingDirectory: resolvedWorkingDirectory,
                        extra: [
                            "surface_handle": String(UInt(bitPattern: retrySurface)),
                            "retry_reason": "display_link_vsync_fallback",
                        ]
                    )
                )
                return SurfaceCreationResult(
                    surface: retrySurface,
                    workingDirectory: resolvedWorkingDirectory
                )
            }

            scheduleImmediateTick()
            ToasttyLog.warning(
                "Ghostty runtime surface factory returned nil after display-link vsync fallback",
                category: .ghostty,
                metadata: failureMetadata.merging(
                    ["retry_reason": "display_link_vsync_fallback"],
                    uniquingKeysWith: { _, new in new }
                )
            )
            return nil
        }

        scheduleImmediateTick()
        ToasttyLog.warning(
            "Ghostty runtime surface factory returned nil",
            category: .ghostty,
            metadata: failureMetadata
        )
        return nil
    }

    private static func createGhosttySurface(
        app: ghostty_app_t,
        surfaceConfig: inout ghostty_surface_config_s,
        resolvedWorkingDirectory: String,
        launchConfiguration: TerminalSurfaceLaunchConfiguration
    ) -> ghostty_surface_t? {
        withGhosttyEnvironmentVariables(launchConfiguration.environmentVariables) { envVarsPointer, envVarCount in
            resolvedWorkingDirectory.withCString { cwdPointer in
                surfaceConfig.working_directory = cwdPointer
                surfaceConfig.env_vars = envVarsPointer
                surfaceConfig.env_var_count = envVarCount
                return withOptionalCString(launchConfiguration.normalizedInitialInput) { inputPointer in
                    surfaceConfig.initial_input = inputPointer
                    return ghostty_surface_new(app, &surfaceConfig)
                }
            }
        }
    }

    private func activateDisplayLinkVsyncFallbackIfNeeded(
        app: ghostty_app_t,
        failureMetadata: [String: String]
    ) -> Bool {
        guard displayLinkVsyncFallbackActive == false,
              displayLinkVsyncFallbackAttempted == false else {
            return false
        }

        guard let currentConfig = config else {
            ToasttyLog.warning(
                "Skipped Ghostty display-link vsync fallback because config is unavailable",
                category: .ghostty,
                metadata: failureMetadata
            )
            return false
        }

        guard Self.windowVsyncEnabled(in: currentConfig) != false else {
            ToasttyLog.info(
                "Skipped Ghostty display-link vsync fallback because window-vsync is already disabled",
                category: .ghostty,
                metadata: failureMetadata
            )
            return false
        }

        let displayLinkProbe = Self.probeActiveDisplayLinkCreation()
        guard displayLinkProbe.matchesVsyncFallbackFailure else {
            ToasttyLog.warning(
                "Skipped Ghostty display-link vsync fallback because CoreVideo did not report the expected failure",
                category: .ghostty,
                metadata: failureMetadata.merging(displayLinkProbe.metadata) { _, new in new }
            )
            return false
        }
        displayLinkVsyncFallbackAttempted = true

        guard let fallbackConfig = ghostty_config_clone(currentConfig) else {
            ToasttyLog.error(
                "Ghostty config clone failed during display-link vsync fallback",
                category: .ghostty,
                metadata: failureMetadata.merging(displayLinkProbe.metadata) { _, new in new }
            )
            return false
        }

        guard let overlayPath = Self.loadWindowVsyncFallbackOverlay(into: fallbackConfig) else {
            ghostty_config_free(fallbackConfig)
            ToasttyLog.error(
                "Failed to apply Ghostty display-link vsync fallback overlay",
                category: .ghostty,
                metadata: failureMetadata.merging(displayLinkProbe.metadata) { _, new in new }
            )
            return false
        }

        let configSource = GhosttyConfigSource.currentEffective
        Self.logGhosttyConfigDiagnostics(fallbackConfig, source: configSource)
        configuredTerminalFontPoints = Self.resolveConfiguredTerminalFontPoints(fallbackConfig)
        Self.applyHostStyle(fallbackConfig)
        Self.withDebugLoginShellOverrideIfNeeded {
            ghostty_config_finalize(fallbackConfig)
        }

        ghostty_app_update_config(app, fallbackConfig)
        ghostty_config_free(currentConfig)
        config = fallbackConfig
        displayLinkVsyncFallbackActive = true
        scheduleImmediateTick()

        ToasttyLog.warning(
            "Activated Ghostty display-link vsync fallback",
            category: .ghostty,
            metadata: failureMetadata
                .merging(displayLinkProbe.metadata) { _, new in new }
                .merging([
                    "config_source": configSource.rawValue,
                    "overlay_path": overlayPath,
                    "window_vsync": "false",
                ]) { _, new in new }
        )
        return true
    }

    private struct DisplayLinkCreationProbe {
        let status: CVReturn
        let createdLink: Bool

        var matchesVsyncFallbackFailure: Bool {
            status == kCVReturnInvalidArgument && createdLink == false
        }

        var metadata: [String: String] {
            [
                "cv_display_link_created": createdLink ? "true" : "false",
                "cv_return": String(status),
                "cv_return_name": GhosttyRuntimeManager.cvReturnName(status),
            ]
        }
    }

    private static func probeActiveDisplayLinkCreation() -> DisplayLinkCreationProbe {
        var displayLink: CVDisplayLink?
        let status = CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        return DisplayLinkCreationProbe(
            status: status,
            createdLink: displayLink != nil
        )
    }

    private static func windowVsyncEnabled(in config: ghostty_config_t) -> Bool? {
        var enabled = true
        let key = "window-vsync"
        guard ghostty_config_get(
            config,
            &enabled,
            key,
            UInt(key.lengthOfBytes(using: .utf8))
        ) else {
            ToasttyLog.warning(
                "Ghostty config missing window-vsync value",
                category: .ghostty,
                metadata: ["key": key]
            )
            return nil
        }
        return enabled
    }

    private static func loadWindowVsyncFallbackOverlay(into config: ghostty_config_t) -> String? {
        let overlayURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "toastty-ghostty-vsync-fallback-\(UUID().uuidString).conf",
                isDirectory: false
            )
        do {
            try Data("window-vsync = false\n".utf8).write(to: overlayURL, options: [.atomic])
        } catch {
            ToasttyLog.error(
                "Failed to write Ghostty display-link vsync fallback overlay",
                category: .ghostty,
                metadata: [
                    "path": overlayURL.path,
                    "error": String(describing: error),
                ]
            )
            return nil
        }

        defer {
            try? FileManager.default.removeItem(at: overlayURL)
        }

        overlayURL.path.withCString { pathPointer in
            ghostty_config_load_file(config, pathPointer)
        }

        guard windowVsyncEnabled(in: config) == false else {
            ToasttyLog.error(
                "Ghostty display-link vsync fallback overlay did not disable window-vsync",
                category: .ghostty,
                metadata: ["path": overlayURL.path]
            )
            return nil
        }
        return overlayURL.path
    }

    nonisolated private static func cvReturnName(_ status: CVReturn) -> String {
        switch status {
        case kCVReturnSuccess:
            return "success"
        case kCVReturnError:
            return "error"
        case kCVReturnInvalidArgument:
            return "invalid_argument"
        case kCVReturnAllocationFailed:
            return "allocation_failed"
        case kCVReturnUnsupported:
            return "unsupported"
        case kCVReturnInvalidDisplay:
            return "invalid_display"
        case kCVReturnDisplayLinkAlreadyRunning:
            return "display_link_already_running"
        case kCVReturnDisplayLinkNotRunning:
            return "display_link_not_running"
        case kCVReturnDisplayLinkCallbacksNotSet:
            return "display_link_callbacks_not_set"
        default:
            return "unknown"
        }
    }

    private static func surfaceCreationDiagnostics(
        hostView: NSView,
        fontPoints: Double,
        sourceSurface: ghostty_surface_t?,
        launchConfiguration: TerminalSurfaceLaunchConfiguration,
        resolvedWorkingDirectory: String,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var metadata = [
            "host_view_id": String(describing: Unmanaged.passUnretained(hostView).toOpaque()),
            "host_has_superview": hostView.superview == nil ? "false" : "true",
            "host_superview_id": hostView.superview.map {
                String(describing: Unmanaged.passUnretained($0).toOpaque())
            } ?? "nil",
            "host_has_window": hostView.window == nil ? "false" : "true",
            "host_window_id": hostView.window.map {
                String(describing: Unmanaged.passUnretained($0).toOpaque())
            } ?? "nil",
            "host_window_key": hostView.window?.isKeyWindow == true ? "true" : "false",
            "host_window_visible": hostView.window?.isVisible == true ? "true" : "false",
            "host_hidden": hostView.isHidden ? "true" : "false",
            "host_hidden_ancestor": hostView.ghosttyLogHasHiddenAncestor ? "true" : "false",
            "host_width": String(format: "%.1f", hostView.bounds.width),
            "host_height": String(format: "%.1f", hostView.bounds.height),
            "host_backing_scale": String(
                format: "%.3f",
                hostView.window?.screen?.backingScaleFactor
                    ?? hostView.window?.backingScaleFactor
                    ?? NSScreen.main?.backingScaleFactor
                    ?? 1
            ),
            "font_points": String(format: "%.1f", fontPoints),
            "inherited_source_surface": sourceSurface == nil ? "false" : "true",
            "launch_environment_count": String(launchConfiguration.environmentVariables.count),
            "launch_initial_input_present": launchConfiguration.normalizedInitialInput == nil ? "false" : "true",
            "resolved_working_directory_present": resolvedWorkingDirectory.isEmpty ? "false" : "true",
        ]
        for (key, value) in extra {
            metadata[key] = value
        }
        return metadata
    }

    func unregisterSurfaceAssociation(forHostView hostView: NSView, surface: ghostty_surface_t?) {
        let hostViewHandle = UInt(bitPattern: Unmanaged.passUnretained(hostView).toOpaque())
        guard let currentSurfaceHandle = surfaceHandleByHostViewHandle[hostViewHandle] else {
            return
        }
        if let surface, currentSurfaceHandle != UInt(bitPattern: surface) {
            return
        }
        surfaceHandleByHostViewHandle.removeValue(forKey: hostViewHandle)
        hostViewBySurfaceHandle.removeValue(forKey: currentSurfaceHandle)
    }

    fileprivate func surfaceHandle(forHostViewHandle hostViewHandle: UInt) -> UInt? {
        surfaceHandleByHostViewHandle[hostViewHandle]
    }

    private func registerSurfaceAssociation(_ surface: ghostty_surface_t, forHostView hostView: NSView) {
        let hostViewHandle = UInt(bitPattern: Unmanaged.passUnretained(hostView).toOpaque())
        let surfaceHandle = UInt(bitPattern: surface)
        surfaceHandleByHostViewHandle[hostViewHandle] = surfaceHandle
        if let terminalHostView = hostView as? TerminalHostView {
            hostViewBySurfaceHandle[surfaceHandle] = WeakTerminalHostViewBox(terminalHostView)
        }
    }

    private static func withOptionalCString<T>(
        _ value: String?,
        body: (UnsafePointer<CChar>?) -> T
    ) -> T {
        guard let value else {
            return body(nil)
        }
        return value.withCString { body($0) }
    }

    private static func withGhosttyEnvironmentVariables<T>(
        _ environmentVariables: [String: String],
        body: (UnsafeMutablePointer<ghostty_env_var_s>?, Int) -> T
    ) -> T {
        guard environmentVariables.isEmpty == false else {
            return body(nil, 0)
        }

        let pairs = environmentVariables.sorted { lhs, rhs in
            if lhs.key == rhs.key {
                return lhs.value < rhs.value
            }
            return lhs.key < rhs.key
        }

        let keyPointers = pairs.map { strdup($0.key) }
        let valuePointers = pairs.map { strdup($0.value) }
        defer {
            keyPointers.forEach { free($0) }
            valuePointers.forEach { free($0) }
        }

        var ghosttyEnvVars = zip(keyPointers, valuePointers).map { pair in
            let (keyPointer, valuePointer) = pair
            return ghostty_env_var_s(
                key: UnsafePointer(keyPointer),
                value: UnsafePointer(valuePointer)
            )
        }

        return ghosttyEnvVars.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress, buffer.count)
        }
    }

    fileprivate func handleDirectHostViewAction(_ action: GhosttyDirectHostViewAction) -> Bool {
        switch action {
        case .mouseShape(let surfaceHandle, let shape):
            guard let hostView = hostView(forSurfaceHandle: surfaceHandle) else {
                return false
            }
            hostView.setGhosttyMouseShape(shape)
            return true
        case .mouseVisibility(let surfaceHandle, let visibility):
            guard let hostView = hostView(forSurfaceHandle: surfaceHandle) else {
                return false
            }
            hostView.setGhosttyMouseVisibility(visibility)
            return true
        case .mouseOverLink(let surfaceHandle, let url, let rawByteLength):
            guard let hostView = hostView(forSurfaceHandle: surfaceHandle) else {
                return false
            }
            ToasttyLog.debug(
                "Received Ghostty mouse-over-link payload",
                category: .ghostty,
                metadata: [
                    "surface_handle": String(surfaceHandle),
                    "raw_byte_length": String(rawByteLength),
                    "decoded_utf8": url == nil ? "false" : "true",
                    "raw_url": url ?? "nil",
                ]
            )
            hostView.setGhosttyMouseOverLink(url, rawByteLength: rawByteLength)
            return true
        case .scrollbar(let surfaceHandle, let totalRows, let offsetRows, let visibleRows):
            guard let hostView = hostView(forSurfaceHandle: surfaceHandle) else {
                return false
            }
            hostView.setGhosttyScrollbar(
                totalRows: totalRows,
                offsetRows: offsetRows,
                visibleRows: visibleRows
            )
            return true
        }
    }

    private func hostView(forSurfaceHandle surfaceHandle: UInt) -> TerminalHostView? {
        guard let hostViewBox = hostViewBySurfaceHandle[surfaceHandle] else {
            return nil
        }
        guard let hostView = hostViewBox.value else {
            hostViewBySurfaceHandle.removeValue(forKey: surfaceHandle)
            return nil
        }
        return hostView
    }

    #if DEBUG
    func associateHostViewForTesting(_ hostView: TerminalHostView, surfaceHandle: UInt) {
        let hostViewHandle = UInt(bitPattern: Unmanaged.passUnretained(hostView).toOpaque())
        surfaceHandleByHostViewHandle[hostViewHandle] = surfaceHandle
        hostViewBySurfaceHandle[surfaceHandle] = WeakTerminalHostViewBox(hostView)
    }

    func removeHostViewAssociationForTesting(_ hostView: TerminalHostView, surfaceHandle: UInt) {
        let hostViewHandle = UInt(bitPattern: Unmanaged.passUnretained(hostView).toOpaque())
        surfaceHandleByHostViewHandle.removeValue(forKey: hostViewHandle)
        hostViewBySurfaceHandle.removeValue(forKey: surfaceHandle)
    }

    @discardableResult
    func dispatchScrollbarDirectHostViewActionForTesting(
        surfaceHandle: UInt,
        totalRows: Int,
        offsetRows: Int,
        visibleRows: Int
    ) -> Bool {
        handleDirectHostViewAction(
            .scrollbar(
                surfaceHandle: surfaceHandle,
                totalRows: totalRows,
                offsetRows: offsetRows,
                visibleRows: visibleRows
            )
        )
    }
    #endif

    @discardableResult
    func reloadConfiguration() -> Bool {
        guard let app else {
            ToasttyLog.warning("Reload config requested before Ghostty app init", category: .ghostty)
            return false
        }
        guard let newConfig = ghostty_config_new() else {
            ToasttyLog.error("Ghostty config allocation failed during reload", category: .ghostty)
            return false
        }

        let configSource = Self.loadGhosttyConfig(newConfig)
        Self.logGhosttyConfigDiagnostics(newConfig, source: configSource)
        configuredTerminalFontPoints = Self.resolveConfiguredTerminalFontPoints(newConfig)
        Self.applyHostStyle(newConfig)
        Self.withDebugLoginShellOverrideIfNeeded {
            ghostty_config_finalize(newConfig)
        }

        // Ghostty's App.updateConfig docs state the caller retains ownership and
        // may free its config buffers immediately after this call returns.
        ghostty_app_update_config(app, newConfig)

        if let previousConfig = config {
            ghostty_config_free(previousConfig)
        }
        config = newConfig
        displayLinkVsyncFallbackAttempted = false
        displayLinkVsyncFallbackActive = false
        scheduleImmediateTick()

        ToasttyLog.info(
            "Reloaded Ghostty configuration",
            category: .ghostty,
            metadata: [
                "source": configSource.rawValue,
                "configured_font_points": configuredTerminalFontPoints.map { String(format: "%.2f", $0) } ?? "unset",
            ]
        )
        return true
    }

    private static func initializeGhosttyRuntime() -> Bool {
        configureGhosttyResourcesDirectoryEnvironmentIfNeeded()
        return ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS
    }

    private static func withDebugLoginShellOverrideIfNeeded<T>(_ body: () -> T) -> T {
        let environment = ProcessInfo.processInfo.environment
        guard let plan = GhosttyDebugLoginShellOverride.plan(environment: environment) else {
            return body()
        }

        let originalShell = currentEnvironmentValue(forKey: "SHELL")
        let originalTermProgram = currentEnvironmentValue(forKey: GhosttyDebugLoginShellOverride.termProgramKey)

        let didSetShell = setEnvironmentValue(key: "SHELL", value: plan.shellPath, overwrite: true)
        if plan.requiresTermProgramShim,
           setEnvironmentValue(
               key: GhosttyDebugLoginShellOverride.termProgramKey,
               value: GhosttyDebugLoginShellOverride.shimmedTermProgramValue,
               overwrite: true
           ) == false {
            ToasttyLog.warning(
                "Failed to apply TERM_PROGRAM shim for Ghostty debug shell override",
                category: .ghostty,
                metadata: [
                    "env_key": GhosttyDebugLoginShellOverride.environmentKey,
                    "term_program_key": GhosttyDebugLoginShellOverride.termProgramKey,
                    "term_program_value": GhosttyDebugLoginShellOverride.shimmedTermProgramValue,
                ]
            )
        }

        if didSetShell {
            var metadata: [String: String] = [
                "env_key": GhosttyDebugLoginShellOverride.environmentKey,
                "shell_path": plan.shellPath,
                "shimmed_term_program": plan.requiresTermProgramShim ? "true" : "false",
            ]
            if let currentTermProgram = currentEnvironmentValue(forKey: GhosttyDebugLoginShellOverride.termProgramKey) {
                metadata["term_program"] = currentTermProgram
            }
            ToasttyLog.info(
                "Temporarily overriding Ghostty default shell for this app launch",
                category: .ghostty,
                metadata: metadata
            )
        } else {
            ToasttyLog.warning(
                "Failed to apply Ghostty debug shell override; continuing with default shell detection",
                category: .ghostty,
                metadata: [
                    "env_key": GhosttyDebugLoginShellOverride.environmentKey,
                    "shell_path": plan.shellPath,
                ]
            )
        }

        defer {
            restoreEnvironmentValue(key: "SHELL", value: originalShell)
            if plan.requiresTermProgramShim {
                restoreEnvironmentValue(
                    key: GhosttyDebugLoginShellOverride.termProgramKey,
                    value: originalTermProgram
                )
            }
        }

        return body()
    }

    private static func loadGhosttyConfig(_ config: ghostty_config_t) -> GhosttyConfigSource {
        let environment = ProcessInfo.processInfo.environment
        if truthy(environment[ghosttyParseCLIArgsEnvironmentKey]) {
            ghostty_config_load_cli_args(config)
            ToasttyLog.info(
                "Ghostty CLI arg parsing enabled",
                category: .ghostty,
                metadata: [
                    "env_key": ghosttyParseCLIArgsEnvironmentKey,
                ]
            )
        }

        if let rawEnvPath = environment[ghosttyConfigPathEnvironmentKey] {
            guard let envPath = normalizedConfigPath(from: rawEnvPath) else {
                ToasttyLog.warning(
                    "Configured Ghostty config path is invalid; falling back",
                    category: .ghostty,
                    metadata: [
                        "path": rawEnvPath,
                        "reason": "must be absolute or use ~/ prefix",
                    ]
                )
                return loadFallbackGhosttyConfig(config, environment: environment)
            }

            if isRegularFile(at: envPath) {
                envPath.withCString { pathPointer in
                    ghostty_config_load_file(config, pathPointer)
                }
                ghostty_config_load_recursive_files(config)
                ToasttyLog.info(
                    "Loaded Ghostty config from TOASTTY_GHOSTTY_CONFIG_PATH",
                    category: .ghostty,
                    metadata: [
                        "path": envPath,
                    ]
                )
                return .envPath
            }

            ToasttyLog.warning(
                "Configured Ghostty config path does not exist; falling back",
                category: .ghostty,
                metadata: [
                    "path": envPath,
                ]
            )
            return loadFallbackGhosttyConfig(config, environment: environment)
        }

        return loadFallbackGhosttyConfig(config, environment: environment)
    }

    private static func loadFallbackGhosttyConfig(
        _ config: ghostty_config_t,
        environment: [String: String]
    ) -> GhosttyConfigSource {
        if let userConfigPath = userGhosttyConfigPath(environment: environment) {
            userConfigPath.withCString { pathPointer in
                ghostty_config_load_file(config, pathPointer)
            }
            ghostty_config_load_recursive_files(config)
            ToasttyLog.info(
                "Loaded Ghostty config from user path",
                category: .ghostty,
                metadata: [
                    "path": userConfigPath,
                ]
            )
            return .userPath
        }

        ghostty_config_load_default_files(config)
        ToasttyLog.info(
            "Loaded Ghostty config from default search paths",
            category: .ghostty
        )
        return .defaultFiles
    }

    private static func userGhosttyConfigPath(environment: [String: String]) -> String? {
        var candidatePaths: [String] = []
        if let xdgConfigHomePath = normalizedConfigPath(from: environment["XDG_CONFIG_HOME"]) {
            candidatePaths.append(
                URL(fileURLWithPath: xdgConfigHomePath, isDirectory: true)
                    .appendingPathComponent("ghostty/config")
                    .standardizedFileURL
                    .path
            )
        }
        candidatePaths.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/ghostty/config")
                .standardizedFileURL
                .path
        )

        var visited = Set<String>()
        for candidatePath in candidatePaths where visited.insert(candidatePath).inserted {
            if isRegularFile(at: candidatePath) {
                return candidatePath
            }
        }
        return nil
    }

    private static func configureGhosttyResourcesDirectoryEnvironmentIfNeeded() {
        let environment = ProcessInfo.processInfo.environment
        let key = ghosttyResourcesDirectoryEnvironmentKey
        let existingRawValue = environment[key]
        let existingPath = normalizedConfigPath(from: existingRawValue)

        if let existingPath {
            if hasGhosttyShellIntegrationResources(at: existingPath) {
                ToasttyLog.debug(
                    "Using configured Ghostty resources directory",
                    category: .ghostty,
                    metadata: ["path": existingPath]
                )
                return
            }
            ToasttyLog.warning(
                "Configured Ghostty resources directory is missing shell integration assets; attempting auto-detection",
                category: .ghostty,
                metadata: [
                    "path": existingPath,
                    "env_key": key,
                ]
            )
        }
        if existingRawValue != nil, existingPath == nil {
            ToasttyLog.warning(
                "Configured Ghostty resources directory is invalid; attempting auto-detection",
                category: .ghostty,
                metadata: [
                    "env_key": key,
                    "reason": "must be absolute or use ~/ prefix",
                ]
            )
        }

        guard let detectedResourcesDirectory = detectGhosttyResourcesDirectory() else {
            ToasttyLog.warning(
                "Unable to find Ghostty resources directory; cwd/title shell integration callbacks may be unavailable",
                category: .ghostty,
                metadata: ["env_key": key]
            )
            return
        }

        let overwrite = existingRawValue == nil ? 0 : 1
        let didSet = detectedResourcesDirectory.withCString { pathPointer in
            setenv(key, pathPointer, Int32(overwrite)) == 0
        }
        guard didSet else {
            ToasttyLog.warning(
                "Failed to configure Ghostty resources directory environment variable",
                category: .ghostty,
                metadata: [
                    "env_key": key,
                    "path": detectedResourcesDirectory,
                ]
            )
            return
        }

        ToasttyLog.info(
            "Configured Ghostty resources directory for embedded runtime",
            category: .ghostty,
            metadata: [
                "path": detectedResourcesDirectory,
                "source": "auto_detect",
            ]
        )
    }

    private static func currentEnvironmentValue(forKey key: String) -> String? {
        guard let pointer = getenv(key) else {
            return nil
        }

        let value = String(cString: pointer)
        return value.isEmpty ? nil : value
    }

    private static func setEnvironmentValue(key: String, value: String, overwrite: Bool) -> Bool {
        value.withCString { valuePointer in
            setenv(key, valuePointer, overwrite ? 1 : 0) == 0
        }
    }

    private static func restoreEnvironmentValue(key: String, value: String?) {
        if let value {
            _ = setEnvironmentValue(key: key, value: value, overwrite: true)
        } else {
            _ = unsetenv(key)
        }
    }

    private static func detectGhosttyResourcesDirectory() -> String? {
        var candidates: [String] = []

        if let bundledResourcesPath = Bundle.main.resourceURL?
            .appendingPathComponent("ghostty", isDirectory: true)
            .standardizedFileURL.path {
            candidates.append(bundledResourcesPath)
        }

        candidates.append("/Applications/Ghostty.app/Contents/Resources/ghostty")
        candidates.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Ghostty.app/Contents/Resources/ghostty")
                .standardizedFileURL.path
        )
        candidates.append("/opt/homebrew/share/ghostty")
        candidates.append("/usr/local/share/ghostty")
        candidates.append("/usr/share/ghostty")

        var visited = Set<String>()
        for candidate in candidates where visited.insert(candidate).inserted {
            if hasGhosttyShellIntegrationResources(at: candidate) {
                return candidate
            }
        }

        return nil
    }

    private static func hasGhosttyShellIntegrationResources(at resourcesDirectory: String) -> Bool {
        let integrationRoot = URL(fileURLWithPath: resourcesDirectory, isDirectory: true)
            .appendingPathComponent("shell-integration", isDirectory: true)
            .standardizedFileURL.path
        guard isDirectory(at: integrationRoot) else {
            return false
        }

        let requiredFiles = [
            "zsh/ghostty-integration",
            "bash/ghostty.bash",
            "fish/vendor_conf.d/ghostty-shell-integration.fish",
        ]
        for requiredFile in requiredFiles {
            let candidate = URL(fileURLWithPath: integrationRoot, isDirectory: true)
                .appendingPathComponent(requiredFile, isDirectory: false)
                .standardizedFileURL.path
            if isRegularFile(at: candidate) == false {
                return false
            }
        }
        return true
    }

    private static func isDirectory(at path: String) -> Bool {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }

    private static func isRegularFile(at path: String) -> Bool {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return false
        }
        return !isDirectory.boolValue
    }

    private static func normalizedConfigPath(from rawPath: String?) -> String? {
        guard let trimmedPath = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmedPath.isEmpty == false else {
            return nil
        }
        let expandedPath = (trimmedPath as NSString).expandingTildeInPath
        guard expandedPath.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: expandedPath).standardizedFileURL.path
    }

    private static func truthy(_ value: String?) -> Bool {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return normalized == "1" || normalized == "true" || normalized == "yes" || normalized == "on"
    }

    private static func logGhosttyConfigDiagnostics(_ config: ghostty_config_t, source: GhosttyConfigSource) {
        let diagnosticsCount = ghostty_config_diagnostics_count(config)
        ToasttyLog.info(
            "Ghostty config load complete",
            category: .ghostty,
            metadata: [
                "source": source.rawValue,
                "diagnostic_count": String(diagnosticsCount),
            ]
        )
        guard diagnosticsCount > 0 else { return }

        for index in 0..<diagnosticsCount {
            let diagnostic = ghostty_config_get_diagnostic(config, index)
            let message: String
            if let diagnosticMessage = diagnostic.message {
                message = String(cString: diagnosticMessage)
            } else {
                message = "unknown diagnostic"
            }
            ToasttyLog.warning(
                "Ghostty config diagnostic",
                category: .ghostty,
                metadata: [
                    "source": source.rawValue,
                    "index": String(index),
                    "message": message,
                ]
            )
        }
    }

    private static func applyHostStyle(_ config: ghostty_config_t) {
        let unfocusedSplitStyle = resolveUnfocusedSplitStyle(config)
        GhosttyHostStyleStore.shared.setUnfocusedSplitStyle(unfocusedSplitStyle)
        ToasttyLog.info(
            "Applied Ghostty unfocused split style",
            category: .ghostty,
            metadata: [
                "overlay_opacity": String(format: "%.3f", unfocusedSplitStyle.fillOverlayOpacity),
                "fill_rgb": String(
                    format: "%.3f,%.3f,%.3f",
                    unfocusedSplitStyle.fillColor.red,
                    unfocusedSplitStyle.fillColor.green,
                    unfocusedSplitStyle.fillColor.blue
                ),
            ]
        )
    }

    private static func resolveUnfocusedSplitStyle(_ config: ghostty_config_t) -> GhosttyUnfocusedSplitStyle {
        var configuredUnfocusedSplitOpacity = 0.7
        let opacityKey = "unfocused-split-opacity"
        if !ghostty_config_get(config, &configuredUnfocusedSplitOpacity, opacityKey, UInt(opacityKey.lengthOfBytes(using: .utf8))) {
            ToasttyLog.warning(
                "Ghostty config missing unfocused split opacity; using fallback",
                category: .ghostty,
                metadata: [
                    "key": opacityKey,
                    "fallback": "0.7",
                ]
            )
        }

        var fillColor = ghostty_config_color_s()
        let fillKey = "unfocused-split-fill"
        if !ghostty_config_get(config, &fillColor, fillKey, UInt(fillKey.lengthOfBytes(using: .utf8))) {
            let backgroundKey = "background"
            if !ghostty_config_get(config, &fillColor, backgroundKey, UInt(backgroundKey.lengthOfBytes(using: .utf8))) {
                ToasttyLog.warning(
                    "Ghostty config missing unfocused split fill and background; using black fallback",
                    category: .ghostty,
                    metadata: [
                        "fill_key": fillKey,
                        "background_key": backgroundKey,
                    ]
                )
            }
        }

        let rawOverlayOpacity = 1 - configuredUnfocusedSplitOpacity
        let overlayOpacity = min(max(rawOverlayOpacity, 0), 1)
        if abs(overlayOpacity - rawOverlayOpacity) > AppState.terminalFontComparisonEpsilon {
            ToasttyLog.warning(
                "Clamped Ghostty unfocused split overlay opacity",
                category: .ghostty,
                metadata: [
                    "raw_value": String(rawOverlayOpacity),
                    "clamped_value": String(overlayOpacity),
                ]
            )
        }

        return GhosttyUnfocusedSplitStyle(
            fillOverlayOpacity: overlayOpacity,
            fillColor: GhosttyHostColor(
                red: Double(fillColor.r) / 255,
                green: Double(fillColor.g) / 255,
                blue: Double(fillColor.b) / 255
            )
        )
    }

    private static func resolveConfiguredTerminalFontPoints(_ config: ghostty_config_t) -> Double? {
        // ghostty_config_get writes C float values for font-size.
        var configuredFontPoints = Float(AppState.defaultTerminalFontPoints)
        let fontSizeKey = "font-size"
        guard ghostty_config_get(
            config,
            &configuredFontPoints,
            fontSizeKey,
            UInt(fontSizeKey.lengthOfBytes(using: .utf8))
        ) else {
            ToasttyLog.info(
                "Ghostty config missing font size; using Toastty fallback",
                category: .ghostty,
                metadata: [
                    "key": fontSizeKey,
                    "fallback": String(format: "%.2f", AppState.defaultTerminalFontPoints),
                ]
            )
            return nil
        }

        let rawConfiguredFontPoints = Double(configuredFontPoints)
        let clampedFontPoints = AppState.clampedTerminalFontPoints(rawConfiguredFontPoints)
        if abs(clampedFontPoints - rawConfiguredFontPoints) > AppState.terminalFontComparisonEpsilon {
            ToasttyLog.warning(
                "Clamped Ghostty configured font size to Toastty bounds",
                category: .ghostty,
                metadata: [
                    "raw_value": String(format: "%.2f", rawConfiguredFontPoints),
                    "clamped_value": String(format: "%.2f", clampedFontPoints),
                    "min": String(format: "%.2f", AppState.minTerminalFontPoints),
                    "max": String(format: "%.2f", AppState.maxTerminalFontPoints),
                ]
            )
        }

        ToasttyLog.info(
            "Resolved Ghostty configured terminal font size",
            category: .ghostty,
            metadata: [
                "points": String(format: "%.2f", clampedFontPoints),
            ]
        )
        return clampedFontPoints
    }

    private static func normalizedWorkingDirectoryValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        if trimmed.hasPrefix("file://"),
           let url = URL(string: trimmed),
           url.isFileURL {
            let path = url.path
            return path.isEmpty ? nil : path
        }
        return trimmed
    }

    fileprivate func scheduleImmediateTick() {
        guard isTickScheduled == false else { return }
        isTickScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isTickScheduled = false
            self.tick()
        }
    }

    func requestImmediateTick() {
        scheduleImmediateTick()
    }

    fileprivate func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    fileprivate func routeRuntimeAction(_ action: GhosttyRuntimeAction) -> Bool {
        actionHandler?.handleGhosttyRuntimeAction(action) ?? false
    }

    fileprivate func routeCloseSurfaceRequest(surfaceHandle: UInt?, confirmed: Bool) -> Bool {
        actionHandler?.handleGhosttyCloseSurfaceRequest(surfaceHandle: surfaceHandle, confirmed: confirmed) ?? false
    }
}

private extension NSView {
    var ghosttyLogHasHiddenAncestor: Bool {
        var ancestor = superview
        while let current = ancestor {
            if current.isHidden {
                return true
            }
            ancestor = current.superview
        }
        return false
    }
}
#endif
