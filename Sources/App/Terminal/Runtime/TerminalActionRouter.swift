#if TOASTTY_HAS_GHOSTTY_KIT
import CoreState
import Foundation

@MainActor
final class TerminalActionRouter {
    private unowned let store: AppStore
    private unowned let registry: TerminalRuntimeRegistry

    init(store: AppStore, registry: TerminalRuntimeRegistry) {
        self.store = store
        self.registry = registry
    }

    func handle(_ action: GhosttyRuntimeAction) -> Bool {
        let state = store.state

        if case .desktopNotification(let title, let body) = action.intent {
            return registry.handleDesktopNotificationAction(
                action: action,
                title: title,
                body: body,
                state: state,
                store: store
            )
        }

        guard let resolution = registry.resolveActionTarget(for: action, state: state) else {
            return false
        }

        switch action.intent {
        case .setTerminalTitle, .setTerminalCWD, .showChildExited, .commandFinished:
            return registry.handleRuntimeMetadataAction(
                action.intent,
                workspaceID: resolution.workspaceID,
                panelID: resolution.panelID,
                state: state,
                store: store
            )

        default:
            break
        }

        guard store.send(.focusPanel(workspaceID: resolution.workspaceID, panelID: resolution.panelID)) else {
            ToasttyLog.warning(
                "Ghostty action failed to focus resolved panel",
                category: .terminal,
                metadata: [
                    "intent": action.logIntentName,
                    "workspace_id": resolution.workspaceID.uuidString,
                    "panel_id": resolution.panelID.uuidString,
                ]
            )
            return false
        }

        let handled: Bool
        switch action.intent {
        case .split(let direction):
            handled = registry.splitFocusedSlotInDirection(
                workspaceID: resolution.workspaceID,
                direction: direction
            )

        case .focus(let direction):
            handled = store.send(
                .focusSlot(workspaceID: resolution.workspaceID, direction: direction)
            )

        case .resizeSplit(let direction, let amount):
            handled = store.send(
                .resizeFocusedSlotSplit(
                    workspaceID: resolution.workspaceID,
                    direction: direction,
                    amount: amount
                )
            )

        case .equalizeSplits:
            handled = store.send(.equalizeLayoutSplits(workspaceID: resolution.workspaceID))

        case .toggleFocusedPanelMode:
            handled = store.send(.toggleFocusedPanelMode(workspaceID: resolution.workspaceID))

        case .setTerminalTitle, .setTerminalCWD, .showChildExited, .commandFinished:
            handled = false

        case .desktopNotification:
            handled = false
        }

        if handled {
            ToasttyLog.debug(
                "Handled Ghostty runtime action in registry",
                category: .terminal,
                metadata: [
                    "intent": action.logIntentName,
                    "workspace_id": resolution.workspaceID.uuidString,
                    "panel_id": resolution.panelID.uuidString,
                ]
            )
        } else {
            ToasttyLog.debug(
                "Reducer rejected Ghostty runtime action",
                category: .terminal,
                metadata: [
                    "intent": action.logIntentName,
                    "workspace_id": resolution.workspaceID.uuidString,
                    "panel_id": resolution.panelID.uuidString,
                ]
            )
        }

        return handled
    }
}
#endif
