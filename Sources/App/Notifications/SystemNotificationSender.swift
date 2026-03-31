import AppKit
import CoreState
import Foundation
import UserNotifications

/// Delivers macOS user notifications via UNUserNotificationCenter.
///
/// Permission is requested lazily on the first send attempt. When notifications
/// are unavailable or denied, Toastty surfaces one in-app guidance path instead
/// of routing notification delivery through another application.
@MainActor
enum SystemNotificationSender {
    enum NotificationAccessIssue: Equatable {
        case denied
        case unavailable
    }

    private enum AuthorizationState: Equatable {
        case notDetermined
        case authorized
        case denied
        case unavailable
    }

    struct Dependencies {
        var notificationAuthorizationStatus: @MainActor () async -> UNAuthorizationStatus
        var requestAuthorization: @MainActor () async throws -> Bool
        var addRequest: @MainActor (UNNotificationRequest) async throws -> Void
        var scheduleAccessGuidance: @MainActor (NotificationAccessIssue) -> Void

        static let live = Self(
            notificationAuthorizationStatus: {
                await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            },
            requestAuthorization: {
                try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            },
            addRequest: { request in
                try await UNUserNotificationCenter.current().add(request)
            },
            scheduleAccessGuidance: { issue in
                NotificationAccessGuidancePresenter.shared.schedule(issue: issue)
            }
        )
    }

    static var dependencies = Dependencies.live
    private static var authorizationResolutionTask: Task<AuthorizationState, Never>?

    static func send(
        title: String,
        body: String,
        workspaceID: UUID?,
        panelID: UUID?,
        context: DesktopNotificationContext = DesktopNotificationContext()
    ) async {
        let resolvedContent = DesktopNotificationContentResolver.resolve(
            title: title,
            body: body,
            context: context
        )
        let finalTitle = resolvedContent.title
        let finalBody = resolvedContent.body

        let authorizationState = await resolveAuthorizationState()
        guard authorizationState == .authorized else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = finalTitle
        content.body = finalBody
        content.sound = .default

        // Attach workspace/panel identifiers so the notification response
        // delegate can route click-to-focus actions.
        var userInfo: [String: String] = [:]
        if let workspaceID {
            userInfo[DesktopNotificationUserInfoKey.workspaceID] = workspaceID.uuidString
        }
        if let panelID {
            userInfo[DesktopNotificationUserInfoKey.panelID] = panelID.uuidString
        }
        if userInfo.isEmpty == false {
            content.userInfo = userInfo
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // deliver immediately
        )

        do {
            try await dependencies.addRequest(request)
            var metadata: [String: String] = ["title": finalTitle]
            if let workspaceID {
                metadata["workspace_id"] = workspaceID.uuidString
            }
            ToasttyLog.debug(
                "Delivered system notification",
                category: .notifications,
                metadata: metadata
            )
        } catch {
            ToasttyLog.warning(
                "Failed to deliver system notification",
                category: .notifications,
                metadata: ["error": error.localizedDescription]
            )
            if let issue = await notificationAccessIssue(for: error) {
                dependencies.scheduleAccessGuidance(issue)
            }
        }
    }

    private static func resolveAuthorizationState() async -> AuthorizationState {
        let currentStatus = await dependencies.notificationAuthorizationStatus()
        switch authorizationState(for: currentStatus) {
        case .authorized:
            return .authorized
        case .denied:
            dependencies.scheduleAccessGuidance(.denied)
            return .denied
        case .notDetermined:
            if let authorizationResolutionTask {
                return await authorizationResolutionTask.value
            }
            let requestAuthorization = dependencies.requestAuthorization
            let scheduleAccessGuidance = dependencies.scheduleAccessGuidance
            let authorizationResolutionTask = Task { @MainActor in
                do {
                    let granted = try await requestAuthorization()
                    ToasttyLog.info(
                        "Notification permission result",
                        category: .notifications,
                        metadata: ["granted": granted ? "true" : "false"]
                    )
                    if granted {
                        return AuthorizationState.authorized
                    }
                    scheduleAccessGuidance(.denied)
                    return .denied
                } catch {
                    ToasttyLog.warning(
                        "Notification permission request failed",
                        category: .notifications,
                        metadata: ["error": error.localizedDescription]
                    )
                    if let issue = await notificationAccessIssue(for: error) {
                        scheduleAccessGuidance(issue)
                    }
                    return .unavailable
                }
            }
            self.authorizationResolutionTask = authorizationResolutionTask
            let resolvedState = await authorizationResolutionTask.value
            self.authorizationResolutionTask = nil
            return resolvedState
        case .unavailable:
            dependencies.scheduleAccessGuidance(.unavailable)
            return .unavailable
        }
    }

    private static func authorizationState(for status: UNAuthorizationStatus) -> AuthorizationState {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized, .provisional, .ephemeral:
            return .authorized
        @unknown default:
            return .authorized
        }
    }

    private static func notificationAccessIssue(for error: Error) async -> NotificationAccessIssue? {
        guard notificationErrorCode(for: error) == .notificationsNotAllowed else {
            return nil
        }
        let currentStatus = await dependencies.notificationAuthorizationStatus()
        if authorizationState(for: currentStatus) == .denied {
            return .denied
        }
        return .unavailable
    }

    private static func notificationErrorCode(for error: Error) -> UNError.Code? {
        let nsError = error as NSError
        guard nsError.domain == UNErrorDomain else {
            return nil
        }
        return UNError.Code(rawValue: nsError.code)
    }

    static func resetForTesting(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
        authorizationResolutionTask = nil
    }
}

@MainActor
final class NotificationAccessGuidancePresenter {
    typealias ObserverRegistrar = (@escaping @MainActor () -> Void) -> NSObjectProtocol
    typealias ObserverRemover = (NSObjectProtocol) -> Void
    typealias AlertPresenter = @MainActor (SystemNotificationSender.NotificationAccessIssue) -> Bool

    static let shared = NotificationAccessGuidancePresenter()

    private let isAppActive: @MainActor () -> Bool
    private let registerDidBecomeActiveObserver: ObserverRegistrar
    private let removeObserver: ObserverRemover
    private let presentAlert: AlertPresenter
    private let openSystemSettings: @MainActor () -> Void

    private var hasPresentedGuidance = false
    private var pendingIssue: SystemNotificationSender.NotificationAccessIssue?
    private var didBecomeActiveObserver: NSObjectProtocol?

    init(
        isAppActive: @escaping @MainActor () -> Bool = { NSApp.isActive },
        registerDidBecomeActiveObserver: @escaping ObserverRegistrar = { handler in
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    handler()
                }
            }
        },
        removeObserver: @escaping ObserverRemover = { observer in
            NotificationCenter.default.removeObserver(observer)
        },
        presentAlert: @escaping AlertPresenter = { issue in
            let alert = NSAlert()
            switch issue {
            case .denied:
                alert.messageText = "Desktop Notifications Are Disabled"
                alert.informativeText = """
                Toastty cannot show desktop notifications right now.

                To enable them, open System Settings, go to Notifications, and allow alerts for Toastty.
                """
            case .unavailable:
                alert.messageText = "Desktop Notifications Are Unavailable"
                alert.informativeText = """
                Toastty could not deliver a desktop notification through macOS.

                If Toastty appears in System Settings > Notifications, allow alerts there. Otherwise use a signed Toastty build that macOS can register for notifications.
                """
            }
            alert.alertStyle = .informational
            alert.addConfiguredButton(
                withTitle: "Open System Settings",
                behavior: .defaultAction
            )
            alert.addConfiguredButton(withTitle: "Not Now", behavior: .cancelAction)
            return alert.runModal() == .alertFirstButtonReturn
        },
        openSystemSettings: @escaping @MainActor () -> Void = {
            let systemSettingsURL = URL(fileURLWithPath: "/System/Applications/System Settings.app")
            _ = NSWorkspace.shared.open(systemSettingsURL)
        }
    ) {
        self.isAppActive = isAppActive
        self.registerDidBecomeActiveObserver = registerDidBecomeActiveObserver
        self.removeObserver = removeObserver
        self.presentAlert = presentAlert
        self.openSystemSettings = openSystemSettings
    }

    func schedule(issue: SystemNotificationSender.NotificationAccessIssue) {
        guard hasPresentedGuidance == false else { return }
        pendingIssue = issue

        if isAppActive() {
            presentPendingGuidanceIfNeeded()
            return
        }

        guard didBecomeActiveObserver == nil else { return }
        didBecomeActiveObserver = registerDidBecomeActiveObserver { [weak self] in
            self?.presentPendingGuidanceIfNeeded()
        }
    }

    func resetForTesting() {
        hasPresentedGuidance = false
        pendingIssue = nil
        tearDownObserver()
    }

    private func presentPendingGuidanceIfNeeded() {
        guard hasPresentedGuidance == false,
              let issue = pendingIssue else {
            tearDownObserver()
            return
        }

        hasPresentedGuidance = true
        pendingIssue = nil
        tearDownObserver()

        if presentAlert(issue) {
            openSystemSettings()
        }
    }

    private func tearDownObserver() {
        guard let didBecomeActiveObserver else { return }
        removeObserver(didBecomeActiveObserver)
        self.didBecomeActiveObserver = nil
    }
}
