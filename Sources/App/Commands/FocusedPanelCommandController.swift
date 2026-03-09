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
    }

    @discardableResult
    func closeFocusedPanel(in workspaceID: UUID? = nil) -> CloseResult {
        guard let store else { return .notHandled }
        let selectedWorkspaceIDBeforeClose = store.selectedWorkspace?.id
        let resolvedWorkspaceID = workspaceID ?? store.selectedWorkspace?.id
        guard let resolvedWorkspaceID,
              let workspace = store.state.workspacesByID[resolvedWorkspaceID],
              let focusedPanelID = workspace.focusedPanelID else {
            return .notHandled
        }

        let focusedPanelState = workspace.panels[focusedPanelID]
        var didPromptForConfirmation = false
        if shouldConfirmClose,
           focusedPanelState?.kind == .terminal {
            if let closeAssessment = runtimeRegistry?.terminalCloseConfirmationAssessment(panelID: focusedPanelID) {
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
                        "panel_id": focusedPanelID.uuidString,
                        "runtime_registry_available": runtimeRegistry == nil ? "false" : "true",
                    ]
                )
            }
        }

        let didClosePanel = store.send(.closePanel(panelID: focusedPanelID))
        guard didClosePanel else {
            return didPromptForConfirmation ? .canceled : .notHandled
        }

        // Only restore focus when the close originated from the visible workspace.
        let shouldRestoreFocus = workspaceID == nil || selectedWorkspaceIDBeforeClose == resolvedWorkspaceID
        guard shouldRestoreFocus,
              let runtimeRegistry,
              let nextFocusedPanelID = store.selectedWorkspace?.focusedPanelID else {
            return .closed
        }

        slotFocusRestoreCoordinator.schedule(
            store: store,
            runtimeRegistry: runtimeRegistry,
            expectedFocusedPanelID: nextFocusedPanelID
        )
        return .closed
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
