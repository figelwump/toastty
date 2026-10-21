import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// The desktop integration seam for the UI-free App layer on Linux.
///
/// Shared App code calls AppKit/UserNotifications APIs (`NSWorkspace.open`,
/// `NSAlert.runModal`, `NSPasteboard`, `NSApp.activate`, dock badges,
/// `UNUserNotificationCenter`). On Linux those shim types forward here. The
/// GTK frontend installs its own implementation with
/// `LinuxPlatform.install(_:)` (AdwAlertDialog, `gtk_show_uri`, GdkClipboard,
/// `gtk_window_present`, GNotification, the Unity LauncherEntry count);
/// `HeadlessLinuxPlatformServices` is the default and needs no display.
///
/// All requirements are main-actor bound, like the AppKit calls they replace.
@MainActor
public protocol LinuxPlatformServices: AnyObject {
    /// `NSApplication.shared.isActive`: whether a Toastty window has focus.
    var isApplicationActive: Bool { get }

    /// `NSApp.activate(ignoringOtherApps:)`: raise the most recent window.
    func activateApplication()

    /// `NSWorkspace.shared.open(_:)`: open a URL or file with the desktop's
    /// default handler. Returns whether the launch was started.
    func openURL(_ url: URL) -> Bool

    /// `NSAlert.runModal()`: show a blocking alert and return the index of
    /// the chosen button (0-based, in `alert.buttons` order).
    func runModalAlert(_ alert: LinuxAlertRequest) -> Int

    /// `NSAlert.beginSheetModal(for:)`: window-attached alert. `completion`
    /// receives the chosen button index.
    func presentAlert(
        _ alert: LinuxAlertRequest,
        windowID: UUID?,
        completion: @escaping @MainActor (Int) -> Void
    )

    /// `NSPasteboard.general` string read/write.
    func writeClipboardString(_ string: String) -> Bool
    func readClipboardString() -> String?

    /// Dock/launcher unread badge; `nil` clears it.
    func setApplicationBadgeCount(_ count: Int?)

    /// Windows Toastty owns, front to back (`NSApp.windows`).
    func windowSnapshots() -> [LinuxWindowSnapshot]

    /// `NSWindow.makeKeyAndOrderFront(_:)` / `orderFront(_:)`.
    func presentWindow(id: UUID, makeKey: Bool)

    /// `NSScreen.screens`; the first entry is the main screen.
    func screenSnapshots() -> [LinuxScreenSnapshot]

    /// PNG of a window's content (`cacheDisplay(in:to:)` for automation
    /// screenshots). `nil` when unavailable.
    func captureWindowPNG(id: UUID) -> Data?

    /// Seconds since the last user input in the session, or `nil` when unknown.
    func userIdleSeconds() -> TimeInterval?

    /// Whether the session's screen is locked, or `nil` when unknown.
    func isScreenLocked() -> Bool?

    /// Desktop notification delivery (`UNUserNotificationCenter.add`).
    func notificationAuthorization() -> LinuxNotificationAuthorization
    func requestNotificationAuthorization() -> Bool
    func deliverNotification(_ notification: LinuxDesktopNotification) throws
    func removeNotifications(identifiers: [String])
}

public struct LinuxAlertRequest: Equatable, Sendable {
    public enum Style: String, Sendable {
        case informational
        case warning
        case critical
    }

    public struct Button: Equatable, Sendable {
        public var title: String
        /// "\r" for the default action, "\u{1B}" for cancel, or empty.
        public var keyEquivalent: String

        public var isDefaultAction: Bool { keyEquivalent == "\r" }
        public var isCancelAction: Bool { keyEquivalent == "\u{1B}" }
    }

    public var style: Style
    public var messageText: String
    public var informativeText: String
    public var buttons: [Button]
    public var showsSuppressionButton: Bool
    public var suppressionButtonTitle: String?

    /// The button a non-interactive presenter should pick: the explicit
    /// cancel button, a button titled like a cancel action, the only button,
    /// or the last one (AppKit alerts put Cancel after the call to action).
    public var safeDefaultButtonIndex: Int {
        guard buttons.isEmpty == false else { return 0 }
        if let index = buttons.firstIndex(where: \.isCancelAction) { return index }
        let cancelTitles: Set<String> = ["cancel", "not now"]
        if let index = buttons.firstIndex(where: { cancelTitles.contains($0.title.lowercased()) }) {
            return index
        }
        return buttons.count - 1
    }
}

public struct LinuxWindowSnapshot: Equatable, Sendable {
    public var id: UUID
    public var frame: CGRect
    public var isVisible: Bool
    public var isMiniaturized: Bool
    public var isKey: Bool
    public var isMain: Bool
    /// The focused widget is a text entry (rename field, search, location
    /// bar), so delayed terminal focus restoration must not steal it.
    public var hasTextInputFocus: Bool

    public init(
        id: UUID,
        frame: CGRect,
        isVisible: Bool = true,
        isMiniaturized: Bool = false,
        isKey: Bool = false,
        isMain: Bool = false,
        hasTextInputFocus: Bool = false
    ) {
        self.id = id
        self.frame = frame
        self.isVisible = isVisible
        self.isMiniaturized = isMiniaturized
        self.isKey = isKey
        self.isMain = isMain
        self.hasTextInputFocus = hasTextInputFocus
    }
}

public struct LinuxScreenSnapshot: Equatable, Sendable {
    public var frame: CGRect
    public var visibleFrame: CGRect
    public var scale: CGFloat
    public var name: String

    public init(frame: CGRect, visibleFrame: CGRect? = nil, scale: CGFloat = 1, name: String = "") {
        self.frame = frame
        self.visibleFrame = visibleFrame ?? frame
        self.scale = scale
        self.name = name
    }
}

public enum LinuxNotificationAuthorization: Sendable {
    case notDetermined
    case authorized
    case denied
}

public struct LinuxDesktopNotification: Equatable, Sendable {
    public var identifier: String
    public var title: String
    public var body: String
    public var playsSound: Bool
    /// String-valued routing keys (workspace/panel IDs); hand them back
    /// unchanged to `LinuxPlatform.handleNotificationActivation(userInfo:)`.
    public var userInfo: [String: String]
}

public enum LinuxPlatformError: Error, Equatable {
    case notificationsUnavailable
}

/// The installed services. Defaults to `HeadlessLinuxPlatformServices`.
@MainActor
public enum LinuxPlatform {
    public private(set) static var services: any LinuxPlatformServices = HeadlessLinuxPlatformServices()

    public static func install(_ services: any LinuxPlatformServices) {
        self.services = services
    }

    /// Call when the user activates a desktop notification. Routes through
    /// the `UNUserNotificationCenter` delegate exactly like macOS.
    public static func handleNotificationActivation(identifier: String, userInfo: [String: String]) {
        UNUserNotificationCenter.current().deliverActivation(identifier: identifier, userInfo: userInfo)
    }

    /// Post when Toastty gains or loses application focus, so observers of
    /// `NSApplication.didBecomeActiveNotification` run.
    public static func postApplicationActivationChange(isActive: Bool) {
        NotificationCenter.default.post(
            name: isActive ? NSApplication.didBecomeActiveNotification : NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    public static func postScreenParametersChanged() {
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    public static func postApplicationWillTerminate() {
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
    }
}

/// Display-free defaults: URLs open with `xdg-open`, alerts are logged to
/// stderr and answered with their safe (cancel) button, notifications are
/// logged, the clipboard is process-local.
@MainActor
public final class HeadlessLinuxPlatformServices: LinuxPlatformServices {
    public var isApplicationActive: Bool = false
    public private(set) var clipboard: String?
    public private(set) var badgeCount: Int?
    public private(set) var deliveredNotifications: [LinuxDesktopNotification] = []
    public private(set) var presentedAlerts: [LinuxAlertRequest] = []
    /// Overrides the answer for every alert (tests).
    public var alertResponder: (@MainActor (LinuxAlertRequest) -> Int)?
    /// Replaces `xdg-open` (tests).
    public var urlOpener: (@MainActor (URL) -> Bool)?
    public var notificationAuthorizationState: LinuxNotificationAuthorization = .authorized
    public var windows: [LinuxWindowSnapshot] = []
    public var screens: [LinuxScreenSnapshot] = [
        LinuxScreenSnapshot(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), name: "headless"),
    ]

    public init() {}

    public func activateApplication() {
        isApplicationActive = true
    }

    public func openURL(_ url: URL) -> Bool {
        if let urlOpener { return urlOpener(url) }
        return Self.xdgOpen(url)
    }

    public func runModalAlert(_ alert: LinuxAlertRequest) -> Int {
        presentedAlerts.append(alert)
        let index = alertResponder?(alert) ?? alert.safeDefaultButtonIndex
        let chosen = alert.buttons.indices.contains(index) ? alert.buttons[index].title : "-"
        Self.log("alert \"\(alert.messageText)\" answered with \"\(chosen)\" (no display)")
        return index
    }

    public func presentAlert(
        _ alert: LinuxAlertRequest,
        windowID: UUID?,
        completion: @escaping @MainActor (Int) -> Void
    ) {
        _ = windowID
        let response = runModalAlert(alert)
        Task { @MainActor in completion(response) }
    }

    public func writeClipboardString(_ string: String) -> Bool {
        clipboard = string
        return true
    }

    public func readClipboardString() -> String? { clipboard }

    public func setApplicationBadgeCount(_ count: Int?) { badgeCount = count }

    public func windowSnapshots() -> [LinuxWindowSnapshot] { windows }

    public func presentWindow(id: UUID, makeKey: Bool) {
        windows = windows.map { snapshot in
            var snapshot = snapshot
            if snapshot.id == id {
                snapshot.isVisible = true
                snapshot.isMiniaturized = false
                if makeKey { snapshot.isKey = true; snapshot.isMain = true }
            } else if makeKey {
                snapshot.isKey = false
                snapshot.isMain = false
            }
            return snapshot
        }
    }

    public func screenSnapshots() -> [LinuxScreenSnapshot] { screens }

    public func captureWindowPNG(id: UUID) -> Data? { nil }

    public func userIdleSeconds() -> TimeInterval? { LinuxSessionPresence.idleSeconds() }

    public func isScreenLocked() -> Bool? { LinuxSessionPresence.isScreenLocked() }

    public func notificationAuthorization() -> LinuxNotificationAuthorization { notificationAuthorizationState }

    public func requestNotificationAuthorization() -> Bool {
        if notificationAuthorizationState == .notDetermined {
            notificationAuthorizationState = .authorized
        }
        return notificationAuthorizationState == .authorized
    }

    public func deliverNotification(_ notification: LinuxDesktopNotification) throws {
        guard notificationAuthorizationState == .authorized else {
            throw LinuxPlatformError.notificationsUnavailable
        }
        deliveredNotifications.append(notification)
        Self.log("notification \"\(notification.title)\": \(notification.body)")
    }

    public func removeNotifications(identifiers: [String]) {
        deliveredNotifications.removeAll { identifiers.contains($0.identifier) }
    }

    /// Starts `xdg-open` detached. Returns false when it cannot be launched.
    public nonisolated static func xdgOpen(_ url: URL) -> Bool {
        let target = url.isFileURL ? url.path : url.absoluteString
        guard let executable = LinuxExecutableLookup.find("xdg-open") else {
            log("cannot open \(target): xdg-open not found")
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [target]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            log("cannot open \(target): \(error)")
            return false
        }
    }

    nonisolated static func log(_ message: String) {
        FileHandle.standardError.write(Data("toastty-linux: \(message)\n".utf8))
    }
}

public enum LinuxExecutableLookup {
    /// First executable named `name` on `PATH` (or the default system path).
    public static func find(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let path = environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        for directory in path.split(separator: ":") where directory.isEmpty == false {
            let candidate = "\(directory)/\(name)"
            if access(candidate, X_OK) == 0 {
                return candidate
            }
        }
        return nil
    }
}

/// Session idle time and lock state without a toolkit: GNOME's Mutter idle
/// monitor and logind's `LockedHint`, each queried once per call.
public enum LinuxSessionPresence {
    public static func idleSeconds() -> TimeInterval? {
        // gdbus prints "(uint64 12345,)" with the idle time in milliseconds.
        guard let output = run("gdbus", [
            "call", "--session",
            "--dest", "org.gnome.Mutter.IdleMonitor",
            "--object-path", "/org/gnome/Mutter/IdleMonitor/Core",
            "--method", "org.gnome.Mutter.IdleMonitor.GetIdletime",
        ]) else {
            return nil
        }
        let digits = output.split(whereSeparator: { $0.isNumber == false }).compactMap { UInt64($0) }
        guard let milliseconds = digits.last else { return nil }
        return TimeInterval(milliseconds) / 1000
    }

    public static func isScreenLocked() -> Bool? {
        let environment = ProcessInfo.processInfo.environment
        var arguments = ["show-session"]
        if let sessionID = environment["XDG_SESSION_ID"], sessionID.isEmpty == false {
            arguments.append(sessionID)
        }
        arguments += ["-p", "LockedHint", "--value"]
        guard let output = run("loginctl", arguments) else { return nil }
        switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "yes": return true
        case "no": return false
        default: return nil
        }
    }

    static func run(_ name: String, _ arguments: [String], timeout: TimeInterval = 1) -> String? {
        guard let executable = LinuxExecutableLookup.find(name) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(10_000)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Whether the caller runs on the main queue (and so on the main actor).
/// `Thread.isMainThread` is not enough: after `dispatchMain()` (Swift
/// Testing, async `main`), libdispatch drains the main queue on a worker
/// thread.
public enum LinuxMainQueue {
    private static let key = DispatchSpecificKey<UInt8>()
    private static let marked: Void = {
        DispatchQueue.main.setSpecific(key: key, value: 1)
    }()

    public static var isCurrent: Bool {
        _ = marked
        return Thread.isMainThread || DispatchQueue.getSpecific(key: key) != nil
    }
}
