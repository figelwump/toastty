import Foundation

@MainActor
final class PaneFocusRestoreCoordinator {
    // Keep retries short and bounded to cover SwiftUI/AppKit layout handoff after pane close.
    private static let maxAttempts = 12
    private static let retryDelayNanoseconds: UInt64 = 16_000_000
    private var restoreTask: Task<Void, Never>?

    deinit {
        restoreTask?.cancel()
    }

    func schedule(
        store: AppStore,
        runtimeRegistry: TerminalRuntimeRegistry,
        expectedFocusedPanelID: UUID
    ) {
        restoreTask?.cancel()
        restoreTask = Task { @MainActor [weak store, weak runtimeRegistry] in
            for attempt in 0..<Self.maxAttempts {
                guard Task.isCancelled == false else { return }
                guard let store, let runtimeRegistry else { return }
                // Stop retrying if focus moved elsewhere after close.
                guard store.selectedWorkspace?.focusedPanelID == expectedFocusedPanelID else { return }
                if runtimeRegistry.focusSelectedWorkspacePaneIfPossible() {
                    return
                }
                guard attempt < Self.maxAttempts - 1 else { return }
                try? await Task.sleep(nanoseconds: Self.retryDelayNanoseconds)
            }
        }
    }
}

@MainActor
final class FocusedPanelCommandController {
    private weak var store: AppStore?
    private weak var runtimeRegistry: TerminalRuntimeRegistry?
    private let paneFocusRestoreCoordinator: PaneFocusRestoreCoordinator

    init(
        store: AppStore,
        runtimeRegistry: TerminalRuntimeRegistry,
        paneFocusRestoreCoordinator: PaneFocusRestoreCoordinator
    ) {
        self.store = store
        self.runtimeRegistry = runtimeRegistry
        self.paneFocusRestoreCoordinator = paneFocusRestoreCoordinator
    }

    @discardableResult
    func closeFocusedPanel(in workspaceID: UUID? = nil) -> Bool {
        guard let store else { return false }
        let selectedWorkspaceIDBeforeClose = store.selectedWorkspace?.id
        let resolvedWorkspaceID = workspaceID ?? store.selectedWorkspace?.id
        guard let resolvedWorkspaceID,
              let workspace = store.state.workspacesByID[resolvedWorkspaceID],
              let focusedPanelID = workspace.focusedPanelID else {
            return false
        }

        let didClosePanel = store.send(.closePanel(panelID: focusedPanelID))
        guard didClosePanel else { return false }

        // Only restore focus when the close originated from the visible workspace.
        let shouldRestoreFocus = workspaceID == nil || selectedWorkspaceIDBeforeClose == resolvedWorkspaceID
        guard shouldRestoreFocus,
              let runtimeRegistry,
              let nextFocusedPanelID = store.selectedWorkspace?.focusedPanelID else {
            return true
        }

        paneFocusRestoreCoordinator.schedule(
            store: store,
            runtimeRegistry: runtimeRegistry,
            expectedFocusedPanelID: nextFocusedPanelID
        )
        return true
    }
}
