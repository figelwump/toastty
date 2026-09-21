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
        let appState = store.state

        if case .desktopNotification(let title, let body) = action.intent {
            return registry.handleDesktopNotificationAction(
                action: action,
                title: title,
                body: body,
                state: appState,
                store: store
            )
        }

        guard let resolution = registry.resolveActionTarget(for: action, state: appState) else {
            return false
        }

        switch action.intent {
        case .startSearch, .endSearch, .searchTotal, .searchSelected:
            return registry.handleSearchRuntimeAction(
                action.intent,
                panelID: resolution.panelID
            )

        case .setTerminalTitle, .setTerminalCWD, .showChildExited, .commandFinished:
            return registry.handleRuntimeMetadataAction(
                action.intent,
                workspaceID: resolution.workspaceID,
                panelID: resolution.panelID,
                state: appState,
                store: store
            )

        default:
            break
        }

        // Focus the command source and apply its navigation as one visit. Search
        // and background metadata returned above never enter this transaction.
        return store.performNavigation {
            handleNavigationAction(action, workspaceID: resolution.workspaceID, panelID: resolution.panelID)
        }
    }

    private func handleNavigationAction(_ action: GhosttyRuntimeAction, workspaceID: UUID, panelID: UUID) -> Bool {
        guard store.focusPanel(containing: panelID) else {
            ToasttyLog.warning(
                "Ghostty action failed to focus resolved panel",
                category: .terminal,
                metadata: [
                    "intent": action.logIntentName,
                    "workspace_id": workspaceID.uuidString,
                    "panel_id": panelID.uuidString,
                ]
            )
            return false
        }

        let handled: Bool
        switch action.intent {
        case .split(let direction):
            handled = registry.splitFocusedSlotInDirection(
                workspaceID: workspaceID,
                direction: direction
            )

        case .focus(let direction):
            handled = store.send(
                .focusSlot(workspaceID: workspaceID, direction: direction)
            )

        case .resizeSplit(let direction, let amount):
            handled = store.send(
                .resizeFocusedSlotSplit(
                    workspaceID: workspaceID,
                    direction: direction,
                    amount: amount
                )
            )

        case .equalizeSplits:
            handled = store.send(.equalizeLayoutSplits(workspaceID: workspaceID))

        case .toggleFocusedPanelMode:
            handled = registry.toggleFocusedPanelMode(workspaceID: workspaceID)

        case .startSearch, .endSearch, .searchTotal, .searchSelected:
            handled = false

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
                    "workspace_id": workspaceID.uuidString,
                    "panel_id": panelID.uuidString,
                ]
            )
        } else {
            ToasttyLog.debug(
                "Reducer rejected Ghostty runtime action",
                category: .terminal,
                metadata: [
                    "intent": action.logIntentName,
                    "workspace_id": workspaceID.uuidString,
                    "panel_id": panelID.uuidString,
                ]
            )
        }

        return handled
    }
}
#endif
