#if TOASTTY_HAS_GHOSTTY_KIT
import CoreState
import Foundation

@MainActor
final class TerminalStoreActionCoordinator {
    private weak var store: AppStore?
    private var storeActionObserverToken: UUID?
    private let metadataService: TerminalMetadataService
    private let registerPendingSplitSourceIfNeeded: (UUID, AppState, AppState) -> Void
    private let requestSelectedWorkspaceSlotFocusRestore: () -> Void

    init(
        metadataService: TerminalMetadataService,
        registerPendingSplitSourceIfNeeded: @escaping (UUID, AppState, AppState) -> Void,
        requestSelectedWorkspaceSlotFocusRestore: @escaping () -> Void
    ) {
        self.metadataService = metadataService
        self.registerPendingSplitSourceIfNeeded = registerPendingSplitSourceIfNeeded
        self.requestSelectedWorkspaceSlotFocusRestore = requestSelectedWorkspaceSlotFocusRestore
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
        case .toggleFocusedPanelMode(workspaceID: let workspaceID):
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

    private func scheduleFocusedPanelFocusRestoreIfNeeded(
        workspaceID: UUID,
        previousState: AppState,
        nextState: AppState
    ) {
        guard Self.selectedWorkspaceID(state: nextState) == workspaceID,
              let previousWorkspace = previousState.workspacesByID[workspaceID],
              let nextWorkspace = nextState.workspacesByID[workspaceID],
              previousWorkspace.focusedPanelModeActive != nextWorkspace.focusedPanelModeActive else {
            return
        }

        requestSelectedWorkspaceSlotFocusRestore()
    }

    private static func selectedWorkspaceID(state: AppState) -> UUID? {
        guard let selectedWindowID = state.selectedWindowID,
              let selectedWindow = state.windows.first(where: { $0.id == selectedWindowID }) else {
            return nil
        }
        return selectedWindow.selectedWorkspaceID ?? selectedWindow.workspaceIDs.first
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
}
#endif
