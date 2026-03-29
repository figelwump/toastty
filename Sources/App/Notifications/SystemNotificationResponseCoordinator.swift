import AppKit
import CoreState
import Foundation
import UserNotifications

@MainActor
final class SystemNotificationResponseCoordinator: NSObject {
    private weak var store: AppStore?
    private weak var terminalRuntimeRegistry: TerminalRuntimeRegistry?

    init(store: AppStore, terminalRuntimeRegistry: TerminalRuntimeRegistry) {
        self.store = store
        self.terminalRuntimeRegistry = terminalRuntimeRegistry
        super.init()
    }

    func installDelegate() {
        let center = UNUserNotificationCenter.current()
        if (center.delegate as AnyObject?) === self {
            return
        }
        center.delegate = self
    }

    func handleResponse(hint: DesktopNotificationSelectionHint) {
        guard let store else { return }
        var resolvedWorkspaceID: UUID?
        var resolvedPanelID: UUID?

        if let route = DesktopNotificationRouteResolver.resolve(hint: hint, state: store.state) {
            resolvedWorkspaceID = route.workspaceID
            if let panelID = route.panelID {
                guard store.focusExplicitlyNavigatedPanel(
                    windowID: route.windowID,
                    workspaceID: route.workspaceID,
                    panelID: panelID
                ) else {
                    return
                }
                resolvedPanelID = panelID
            } else {
                // Workspace-only notification routes intentionally skip the
                // panel flash because there is no concrete panel destination.
                guard store.send(.selectWorkspace(windowID: route.windowID, workspaceID: route.workspaceID)) else {
                    return
                }
            }
            ToasttyLog.info(
                "Routed notification response to workspace",
                category: .notifications,
                metadata: [
                    "window_id": route.windowID.uuidString,
                    "workspace_id": route.workspaceID.uuidString,
                    "panel_id": route.panelID?.uuidString ?? "<none>",
                ]
            )
        } else {
            ToasttyLog.info(
                "Notification response had no resolvable route",
                category: .notifications,
                metadata: [
                    "workspace_id": hint.workspaceID?.uuidString ?? "<none>",
                    "panel_id": hint.panelID?.uuidString ?? "<none>",
                ]
            )
        }

        NSApp.activate(ignoringOtherApps: true)
        if let panelID = resolvedPanelID {
            terminalRuntimeRegistry?.schedulePanelFocusRestore(panelID: panelID)
        } else if let workspaceID = resolvedWorkspaceID {
            // Restore focus to the notification's routed workspace rather than
            // whichever workspace happens to be selected after routing side effects.
            terminalRuntimeRegistry?.scheduleWorkspaceFocusRestore(workspaceID: workspaceID)
        }
    }
}

extension SystemNotificationResponseCoordinator: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        _ = center
        let hint = DesktopNotificationSelectionHint(
            userInfo: response.notification.request.content.userInfo
        )
        await MainActor.run { [weak self] in
            self?.handleResponse(hint: hint)
        }
    }
}
