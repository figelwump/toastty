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

    private func handleResponse(hint: DesktopNotificationSelectionHint) {
        guard let store else { return }

        if let route = DesktopNotificationRouteResolver.resolve(hint: hint, state: store.state) {
            _ = store.send(.selectWindow(windowID: route.windowID))
            _ = store.send(.selectWorkspace(windowID: route.windowID, workspaceID: route.workspaceID))
            if let panelID = route.panelID {
                _ = store.send(.focusPanel(workspaceID: route.workspaceID, panelID: panelID))
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
        terminalRuntimeRegistry?.scheduleSelectedWorkspaceSlotFocusRestore()
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
