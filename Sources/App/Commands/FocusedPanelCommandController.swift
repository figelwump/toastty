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
    typealias NativeWindowCloseHandler = @MainActor (UUID) -> Bool

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
    private let sceneCoordinator: AppWindowSceneCoordinator?
    private let slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator
    private let closeNativeWindow: NativeWindowCloseHandler
    private let shouldConfirmClose: Bool

    init(
        store: AppStore,
        runtimeRegistry: TerminalRuntimeRegistry,
        slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator,
        sceneCoordinator: AppWindowSceneCoordinator? = nil,
        closeNativeWindow: @escaping NativeWindowCloseHandler = FocusedPanelCommandController
            .closeNativeWindowInAppKit
    ) {
        self.store = store
        self.runtimeRegistry = runtimeRegistry
        self.sceneCoordinator = sceneCoordinator
        self.slotFocusRestoreCoordinator = slotFocusRestoreCoordinator
        self.closeNativeWindow = closeNativeWindow
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
        guard let selection = resolvedSelection(containing: panelID, preferredWorkspaceID: preferredWorkspaceID) else {
            return .notHandled
        }

        let resolvedWorkspaceID = selection.workspace.id
        let resolvedWindowID = selection.windowID
        let workspace = selection.workspace
        let closedPanelWasFocused = workspace.focusedPanelID == panelID
        let panelState = workspace.panelState(for: panelID)
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

        let willCloseWholeWindow = workspace.panels.count == 1 && selection.window.workspaceIDs == [resolvedWorkspaceID]
        if willCloseWholeWindow {
            if sceneCoordinator?.dismissScene(windowID: resolvedWindowID) == true {
                return .closed
            }
            sceneCoordinator?.requestSceneDismissalAfterBindingLoss(windowID: resolvedWindowID)
            if closeNativeWindow(resolvedWindowID) {
                return .closed
            }
            // Fall back to reducer-driven teardown only if no native window is
            // currently available for this last-panel close.
        }

        let didClosePanel = store.send(.closePanel(panelID: panelID))
        let windowStillExists = store.window(id: resolvedWindowID) != nil
        if willCloseWholeWindow && (didClosePanel == false || windowStillExists) {
            sceneCoordinator?.cancelSceneDismissalAfterBindingLoss(windowID: resolvedWindowID)
        }
        guard didClosePanel else {
            return didPromptForConfirmation ? .canceled : .notHandled
        }

        // Only restore AppKit focus when the close removed the currently
        // focused panel from the visible workspace.
        let shouldRestoreFocus = closedPanelWasFocused && selectedWorkspaceIDBeforeClose == resolvedWorkspaceID
        let nextFocusedPanelID = store.state.workspacesByID[resolvedWorkspaceID]?.focusedPanelID
        guard shouldRestoreFocus,
              let runtimeRegistry,
              let nextFocusedPanelID else {
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

    private func resolvedSelection(
        containing panelID: UUID,
        preferredWorkspaceID: UUID?
    ) -> WindowCommandSelection? {
        guard let store else { return nil }

        if let preferredWorkspaceID,
           let window = store.state.windows.first(where: { $0.workspaceIDs.contains(preferredWorkspaceID) }),
           let workspace = store.state.workspacesByID[preferredWorkspaceID],
           workspace.panelState(for: panelID) != nil,
           workspace.slotID(containingPanelID: panelID) != nil {
            return WindowCommandSelection(
                windowID: window.id,
                window: window,
                workspace: workspace
            )
        }

        for window in store.state.windows {
            for workspaceID in window.workspaceIDs {
                guard let workspace = store.state.workspacesByID[workspaceID],
                      workspace.panelState(for: panelID) != nil,
                      workspace.slotID(containingPanelID: panelID) != nil else {
                    continue
                }
                return WindowCommandSelection(
                    windowID: window.id,
                    window: window,
                    workspace: workspace
                )
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

    private static func closeNativeWindowInAppKit(windowID: UUID) -> Bool {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == windowID.uuidString }) else {
            ToasttyLog.debug(
                "Skipping native window close for last-panel teardown because no matching NSWindow was found",
                category: .app,
                metadata: ["window_id": windowID.uuidString]
            )
            return false
        }
        ToasttyLog.debug(
            "Closing native window before last-panel teardown",
            category: .app,
            metadata: [
                "window_id": windowID.uuidString,
                "window_title": window.title,
            ]
        )
        window.close()
        return true
    }
}
