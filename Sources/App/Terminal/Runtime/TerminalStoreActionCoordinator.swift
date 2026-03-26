#if TOASTTY_HAS_GHOSTTY_KIT
import CoreState
import Foundation

@MainActor
final class TerminalStoreActionCoordinator {
    private weak var store: AppStore?
    private var storeActionObserverToken: UUID?
    private let metadataService: TerminalMetadataService
    private let registerPendingSplitSourceIfNeeded: (UUID, AppState, AppState) -> Void
    private let armCloseTransitionViewportDeferral: (UUID, Set<UUID>) -> Void
    private let requestWorkspaceFocusRestore: (UUID) -> Void

    init(
        metadataService: TerminalMetadataService,
        registerPendingSplitSourceIfNeeded: @escaping (UUID, AppState, AppState) -> Void,
        armCloseTransitionViewportDeferral: @escaping (UUID, Set<UUID>) -> Void,
        requestWorkspaceFocusRestore: @escaping (UUID) -> Void
    ) {
        self.metadataService = metadataService
        self.registerPendingSplitSourceIfNeeded = registerPendingSplitSourceIfNeeded
        self.armCloseTransitionViewportDeferral = armCloseTransitionViewportDeferral
        self.requestWorkspaceFocusRestore = requestWorkspaceFocusRestore
    }

    func bind(store: AppStore) {
        if let existingStore = self.store {
            precondition(existingStore === store, "TerminalStoreActionCoordinator cannot be rebound to a different AppStore.")
        }
        unbind()
        self.store = store
        storeActionObserverToken = store.addActionAppliedObserver { [weak self] action, previousState, nextState in
            self?.handleAppliedStoreAction(
                action,
                previousState: previousState,
                nextState: nextState
            )
        }
    }

    func unbind() {
        if let storeActionObserverToken,
           let existingStore = store {
            existingStore.removeActionAppliedObserver(storeActionObserverToken)
        }
        storeActionObserverToken = nil
        store = nil
    }

    @discardableResult
    func sendSplitAction(workspaceID: UUID, action: AppAction) -> Bool {
        guard let store else { return false }
        refreshSplitSourcePanelCWDBeforeSplit(
            workspaceID: workspaceID,
            state: store.state
        )
        return store.send(action)
    }

    private func handleAppliedStoreAction(
        _ action: AppAction,
        previousState: AppState,
        nextState: AppState
    ) {
        switch action {
        case .splitFocusedSlot(workspaceID: let workspaceID, orientation: _):
            registerPendingSplitSourceIfNeeded(workspaceID, previousState, nextState)
        case .splitFocusedSlotInDirection(workspaceID: let workspaceID, direction: _):
            registerPendingSplitSourceIfNeeded(workspaceID, previousState, nextState)
        case .closePanel(panelID: let panelID):
            armCloseTransitionViewportDeferralIfNeeded(
                closedPanelID: panelID,
                previousState: previousState,
                nextState: nextState
            )
        case .toggleFocusedPanelMode(workspaceID: let workspaceID):
            // Let Ghostty's normal relayout handle focus-mode resizes. An
            // explicit scroll-to-bottom correction makes TUIs like Claude Code
            // redraw their entire scrollback on both enter and exit, so do
            // not reintroduce it without validating against that flow.
            scheduleFocusedPanelFocusRestoreIfNeeded(
                workspaceID: workspaceID,
                previousState: previousState,
                nextState: nextState
            )
        default:
            break
        }
    }

    /// Refreshes the split source panel CWD from its tracked process PID so the
    /// reducer reads a fresh value when creating the new split panel.
    private func refreshSplitSourcePanelCWDBeforeSplit(workspaceID: UUID, state: AppState) {
        guard let workspace = state.workspacesByID[workspaceID],
              let sourcePanelID = Self.resolvedActionPanelID(in: workspace),
              let panelState = workspace.panels[sourcePanelID],
              case .terminal = panelState else {
            return
        }

        let now = Date()
        guard metadataService.shouldRunProcessCWDFallbackPoll(panelID: sourcePanelID, now: now) else {
            return
        }
        metadataService.recordProcessCWDFallbackPoll(panelID: sourcePanelID, now: now)
        _ = metadataService.refreshWorkingDirectoryFromProcessIfNeeded(
            panelID: sourcePanelID,
            source: "pre_split_refresh"
        )
    }

    private func armCloseTransitionViewportDeferralIfNeeded(
        closedPanelID: UUID,
        previousState: AppState,
        nextState: AppState
    ) {
        guard let workspaceID = Self.workspaceID(containing: closedPanelID, state: previousState) else {
            ToasttyLog.info(
                "Skipping close-transition viewport deferral because the closed panel was not found in the previous workspace state",
                category: .terminal,
                metadata: [
                    "closed_panel_id": closedPanelID.uuidString,
                ]
            )
            return
        }
        guard let nextWorkspace = nextState.workspacesByID[workspaceID] else {
            ToasttyLog.info(
                "Skipping close-transition viewport deferral because the workspace no longer exists after closing the panel",
                category: .terminal,
                metadata: [
                    "closed_panel_id": closedPanelID.uuidString,
                    "workspace_id": workspaceID.uuidString,
                ]
            )
            return
        }
        let liveTerminalPanelIDs = Self.liveTerminalPanelIDs(in: nextWorkspace)
        guard liveTerminalPanelIDs.isEmpty == false else {
            ToasttyLog.info(
                "Skipping close-transition viewport deferral because no live terminal panels remain after closing the panel",
                category: .terminal,
                metadata: [
                    "closed_panel_id": closedPanelID.uuidString,
                    "workspace_id": workspaceID.uuidString,
                ]
            )
            return
        }
        ToasttyLog.info(
            "Arming close-transition viewport deferral after panel close",
            category: .terminal,
            metadata: [
                "closed_panel_id": closedPanelID.uuidString,
                "workspace_id": workspaceID.uuidString,
                "live_terminal_panel_count": String(liveTerminalPanelIDs.count),
                "live_terminal_panel_ids": Self.serializedPanelIDs(liveTerminalPanelIDs),
            ]
        )
        armCloseTransitionViewportDeferral(workspaceID, liveTerminalPanelIDs)
    }

    private func scheduleFocusedPanelFocusRestoreIfNeeded(
        workspaceID: UUID,
        previousState: AppState,
        nextState: AppState
    ) {
        guard nextState.selectedWorkspaceSelection()?.workspaceID == workspaceID,
              let previousWorkspace = previousState.workspacesByID[workspaceID],
              let nextWorkspace = nextState.workspacesByID[workspaceID],
              previousWorkspace.focusedPanelModeActive != nextWorkspace.focusedPanelModeActive else {
            return
        }

        requestWorkspaceFocusRestore(workspaceID)
    }

    private static func resolvedActionPanelID(in workspace: WorkspaceState) -> UUID? {
        if let focusedPanelID = workspace.focusedPanelID,
           workspace.panels[focusedPanelID] != nil,
           workspace.layoutTree.slotContaining(panelID: focusedPanelID) != nil {
            return focusedPanelID
        }

        for leaf in workspace.layoutTree.allSlotInfos {
            let panelID = leaf.panelID
            if workspace.panels[panelID] != nil {
                return panelID
            }
        }

        return nil
    }

    private static func workspaceID(containing panelID: UUID, state: AppState) -> UUID? {
        for (workspaceID, workspace) in state.workspacesByID {
            guard workspace.panels[panelID] != nil,
                  workspace.layoutTree.slotContaining(panelID: panelID) != nil else {
                continue
            }
            return workspaceID
        }
        return nil
    }

    private static func liveTerminalPanelIDs(in workspace: WorkspaceState) -> Set<UUID> {
        workspace.layoutTree.allSlotInfos.reduce(into: Set<UUID>()) { panelIDs, slot in
            let panelID = slot.panelID
            guard let panelState = workspace.panels[panelID],
                  case .terminal = panelState else {
                return
            }
            panelIDs.insert(panelID)
        }
    }

    private static func serializedPanelIDs(_ panelIDs: Set<UUID>) -> String {
        panelIDs.map(\.uuidString).sorted().joined(separator: ",")
    }

}
#endif
