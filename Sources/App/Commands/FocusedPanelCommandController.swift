import AppKit
import CoreState
import Foundation

@MainActor
final class SlotFocusRestoreCoordinator {
    // Keep retries short and bounded to cover SwiftUI/AppKit layout handoff after slot close.
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
                if runtimeRegistry.focusPanelIfPossible(panelID: expectedFocusedPanelID) {
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
    enum CloseResult: Equatable {
        case notHandled
        case canceled
        case closed

        var consumesShortcut: Bool {
            self != .notHandled
        }

        var didMutateState: Bool {
            self == .closed
        }
    }

    private weak var store: AppStore?
    private weak var runtimeRegistry: TerminalRuntimeRegistry?
    private let slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator
    private let shouldConfirmClose: Bool

    init(
        store: AppStore,
        runtimeRegistry: TerminalRuntimeRegistry,
        slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator
    ) {
        self.store = store
        self.runtimeRegistry = runtimeRegistry
        self.slotFocusRestoreCoordinator = slotFocusRestoreCoordinator
        let processInfo = ProcessInfo.processInfo
        shouldConfirmClose = !AutomationConfig.shouldBypassInteractiveConfirmation(
            arguments: processInfo.arguments,
            environment: processInfo.environment
        )
        runtimeRegistry.setGhosttyCloseSurfaceHandler { [weak self] panelID, _ in
            guard let self else { return false }
            // Route Ghostty close requests through the same close path as Cmd+W
            // so exited panes skip confirmation while live panes keep prompts.
            // Ghostty's callback boolean does not override Toastty's own
            // per-panel close confirmation assessment.
            // The callback identifies a specific surface, so close that panel
            // directly rather than whichever panel is focused after the async
            // main-actor hop completes.
            return self.closePanel(panelID: panelID).consumesShortcut
        }
    }

    func canCloseFocusedPanel(in workspaceID: UUID? = nil) -> Bool {
        guard let workspace = resolvedWorkspace(preferredWorkspaceID: workspaceID) else {
            return false
        }
        return workspace.focusedPanelID != nil
    }

    @discardableResult
    func closeFocusedPanel(in workspaceID: UUID? = nil) -> CloseResult {
        guard let workspace = resolvedWorkspace(preferredWorkspaceID: workspaceID),
              let focusedPanelID = workspace.focusedPanelID else {
            return .notHandled
        }
        return closePanel(panelID: focusedPanelID, preferredWorkspaceID: workspace.id)
    }

    @discardableResult
    func closePanel(panelID: UUID) -> CloseResult {
        closePanel(panelID: panelID, preferredWorkspaceID: nil)
    }

    @discardableResult
    private func closePanel(panelID: UUID, preferredWorkspaceID: UUID?) -> CloseResult {
        guard let store else { return .notHandled }
        let selectedWorkspaceIDBeforeClose = store.selectedWorkspace?.id
        guard let workspace = resolvedWorkspace(containing: panelID, preferredWorkspaceID: preferredWorkspaceID) else {
            return .notHandled
        }

        let resolvedWorkspaceID = workspace.id
        let closedPanelWasFocused = workspace.focusedPanelID == panelID
        let panelState = workspace.panels[panelID]
        var didPromptForConfirmation = false
        if shouldConfirmClose,
           panelState?.kind == .terminal {
            if let closeAssessment = runtimeRegistry?.terminalCloseConfirmationAssessment(panelID: panelID) {
                if closeAssessment.requiresConfirmation {
                    didPromptForConfirmation = true
                    guard confirmRunningTerminalClose(closeAssessment) else {
                        return .canceled
                    }
                }
            } else {
                ToasttyLog.warning(
                    "Skipping terminal close confirmation because runtime assessment is unavailable",
                    category: .terminal,
                    metadata: [
                        "workspace_id": resolvedWorkspaceID.uuidString,
                        "panel_id": panelID.uuidString,
                        "runtime_registry_available": runtimeRegistry == nil ? "false" : "true",
                    ]
                )
            }
        }

        let didClosePanel = store.send(.closePanel(panelID: panelID))
        guard didClosePanel else {
            return didPromptForConfirmation ? .canceled : .notHandled
        }

        // Only restore AppKit focus when the close removed the currently
        // focused panel from the visible workspace.
        let shouldRestoreFocus = closedPanelWasFocused && selectedWorkspaceIDBeforeClose == resolvedWorkspaceID
        guard shouldRestoreFocus,
              let runtimeRegistry,
              let nextFocusedPanelID = store.state.workspacesByID[resolvedWorkspaceID]?.focusedPanelID else {
            return .closed
        }

        slotFocusRestoreCoordinator.schedule(
            store: store,
            runtimeRegistry: runtimeRegistry,
            expectedFocusedPanelID: nextFocusedPanelID
        )
        return .closed
    }

    private func resolvedWorkspace(preferredWorkspaceID workspaceID: UUID?) -> WorkspaceState? {
        guard let store else { return nil }
        let resolvedWorkspaceID = workspaceID ?? store.selectedWorkspace?.id
        guard let resolvedWorkspaceID else { return nil }
        return store.state.workspacesByID[resolvedWorkspaceID]
    }

    private func resolvedWorkspace(containing panelID: UUID, preferredWorkspaceID: UUID?) -> WorkspaceState? {
        guard let store else { return nil }

        if let preferredWorkspaceID,
           let workspace = store.state.workspacesByID[preferredWorkspaceID],
           workspace.panels[panelID] != nil,
           workspace.layoutTree.slotContaining(panelID: panelID) != nil {
            return workspace
        }

        for window in store.state.windows {
            for workspaceID in window.workspaceIDs {
                guard let workspace = store.state.workspacesByID[workspaceID],
                      workspace.panels[panelID] != nil,
                      workspace.layoutTree.slotContaining(panelID: panelID) != nil else {
                    continue
                }
                return workspace
            }
        }

        return nil
    }

    private func confirmRunningTerminalClose(_ assessment: TerminalCloseConfirmationAssessment) -> Bool {
        let confirmationAlert = NSAlert()
        confirmationAlert.messageText = "Close this terminal?"

        var informativeText = "A process is still running in this terminal. Closing the panel will terminate it."
        if let runningCommand = assessment.runningCommand {
            informativeText += "\n\nDetected command: \(runningCommand)"
        }
        confirmationAlert.informativeText = informativeText
        confirmationAlert.alertStyle = .warning
        confirmationAlert.addButton(withTitle: "Cancel")
        confirmationAlert.addButton(withTitle: "Close")

        let response = confirmationAlert.runModal()
        return response == .alertSecondButtonReturn
    }
}
