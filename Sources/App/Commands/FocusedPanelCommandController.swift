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
    enum CloseConfirmationPolicy: Equatable {
        case interactive
        case nonInteractive(terminateRunningProcess: Bool)
    }

    enum CloseRejectionReason: Equatable {
        case runningTerminal(command: String?)
        case terminalAssessmentUnavailable
        case dirtyLocalDocument(displayName: String)
        case localDocumentSaveInProgress(displayName: String)
    }

    enum CloseResult: Equatable {
        case notHandled
        case canceled
        case confirmationRequired(CloseRejectionReason)
        case blocked(CloseRejectionReason)
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
    private let terminalCloseAssessmentProvider: @MainActor (UUID) -> TerminalCloseConfirmationAssessment?
    private let localDocumentCloseConfirmationStateProvider: @MainActor (UUID) -> LocalDocumentCloseConfirmationState?
    private let runningTerminalCloseConfirmationPresenter: @MainActor (TerminalCloseConfirmationAssessment) -> Bool
    private let discardLocalDocumentDraftConfirmationPresenter: @MainActor (String) -> Bool
    private let localDocumentSaveInProgressPresenter: @MainActor (String) -> Void

    init(
        store: AppStore,
        runtimeRegistry: TerminalRuntimeRegistry,
        slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator,
        webPanelRuntimeRegistry: WebPanelRuntimeRegistry? = nil,
        shouldConfirmClose: Bool? = nil,
        terminalCloseAssessmentProvider: (@MainActor (UUID) -> TerminalCloseConfirmationAssessment?)? = nil,
        localDocumentCloseConfirmationStateProvider: (@MainActor (UUID) -> LocalDocumentCloseConfirmationState?)? = nil,
        runningTerminalCloseConfirmationPresenter: (@MainActor (TerminalCloseConfirmationAssessment) -> Bool)? = nil,
        discardLocalDocumentDraftConfirmationPresenter: (@MainActor (String) -> Bool)? = nil,
        localDocumentSaveInProgressPresenter: (@MainActor (String) -> Void)? = nil
    ) {
        self.store = store
        self.runtimeRegistry = runtimeRegistry
        self.slotFocusRestoreCoordinator = slotFocusRestoreCoordinator
        let processInfo = ProcessInfo.processInfo
        self.shouldConfirmClose = shouldConfirmClose ?? !AutomationConfig.shouldBypassInteractiveConfirmation(
            arguments: processInfo.arguments,
            environment: processInfo.environment
        )
        self.terminalCloseAssessmentProvider = terminalCloseAssessmentProvider ?? { [weak runtimeRegistry] panelID in
            runtimeRegistry?.terminalCloseConfirmationAssessment(panelID: panelID)
        }
        self.localDocumentCloseConfirmationStateProvider = localDocumentCloseConfirmationStateProvider ?? { [weak webPanelRuntimeRegistry] panelID in
            webPanelRuntimeRegistry?.localDocumentCloseConfirmationState(panelID: panelID)
        }
        self.runningTerminalCloseConfirmationPresenter = runningTerminalCloseConfirmationPresenter
            ?? Self.presentRunningTerminalCloseConfirmation
        self.discardLocalDocumentDraftConfirmationPresenter = discardLocalDocumentDraftConfirmationPresenter
            ?? Self.presentDiscardLocalDocumentDraftConfirmation
        self.localDocumentSaveInProgressPresenter = localDocumentSaveInProgressPresenter
            ?? Self.presentLocalDocumentSaveInProgressAlert
        runtimeRegistry.setGhosttyCloseSurfaceHandler { [weak self] panelID, _ in
            guard let self else { return false }
            // Route Ghostty close requests through the same close path as Cmd+W
            // so exited panes skip confirmation while live panes keep prompts.
            // Ghostty's callback boolean does not override Toastty's own
            // per-panel close confirmation assessment.
            // The callback identifies a specific surface, so close that panel
            // directly rather than whichever panel is focused after the async
            // main-actor hop completes.
            return self.closePanel(
                panelID: panelID,
                source: .ui("ghostty_close_surface"),
                confirmationPolicy: .interactive
            ).consumesShortcut
        }
    }

    func canCloseFocusedPanel(in workspaceID: UUID? = nil) -> Bool {
        guard let workspace = resolvedWorkspace(preferredWorkspaceID: workspaceID) else {
            return false
        }
        return focusedPanelID(in: workspace) != nil
    }

    @discardableResult
    func closeFocusedPanel(
        in workspaceID: UUID? = nil,
        source: AppActionSource = .command("close_focused_panel"),
        confirmationPolicy: CloseConfirmationPolicy
    ) -> CloseResult {
        guard let workspace = resolvedWorkspace(preferredWorkspaceID: workspaceID),
              let focusedPanelID = focusedPanelID(in: workspace) else {
            return .notHandled
        }
        return closePanel(
            panelID: focusedPanelID,
            preferredWorkspaceID: workspace.id,
            source: source,
            confirmationPolicy: confirmationPolicy
        )
    }

    @discardableResult
    func closePanel(
        panelID: UUID,
        source: AppActionSource = .command("close_panel"),
        confirmationPolicy: CloseConfirmationPolicy
    ) -> CloseResult {
        closePanel(
            panelID: panelID,
            preferredWorkspaceID: nil,
            source: source,
            confirmationPolicy: confirmationPolicy
        )
    }

    @discardableResult
    private func closePanel(
        panelID: UUID,
        preferredWorkspaceID: UUID?,
        source: AppActionSource,
        confirmationPolicy: CloseConfirmationPolicy
    ) -> CloseResult {
        guard let store else { return .notHandled }
        let selectedWorkspaceIDBeforeClose = store.selectedWorkspace?.id
        guard let workspace = resolvedWorkspace(containing: panelID, preferredWorkspaceID: preferredWorkspaceID) else {
            return .notHandled
        }

        let resolvedWorkspaceID = workspace.id
        let closedPanelWasFocused = workspace.focusedPanelID == panelID
        let panelState = workspace.panelState(for: panelID)
        var didPromptForConfirmation = false
        switch panelState {
        case .some(.terminal):
            if shouldConfirmClose {
                if let closeAssessment = terminalCloseAssessmentProvider(panelID) {
                    if closeAssessment.requiresConfirmation {
                        switch confirmationPolicy {
                        case .interactive:
                            didPromptForConfirmation = true
                            guard runningTerminalCloseConfirmationPresenter(closeAssessment) else {
                                return .canceled
                            }

                        case .nonInteractive(let terminateRunningProcess):
                            guard terminateRunningProcess else {
                                return .confirmationRequired(
                                    .runningTerminal(command: closeAssessment.runningCommand)
                                )
                            }
                        }
                    }
                } else {
                    if case .nonInteractive(let terminateRunningProcess) = confirmationPolicy,
                       terminateRunningProcess == false {
                        return .blocked(.terminalAssessmentUnavailable)
                    }
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

        case .some(.web(let webState)) where webState.definition == .localDocument:
            switch confirmationPolicy {
            case .interactive where shouldConfirmClose == false:
                break

            case .interactive:
                if let closeConfirmationState = localDocumentCloseConfirmationStateProvider(panelID) {
                    didPromptForConfirmation = true
                    switch closeConfirmationState.kind {
                    case .dirtyDraft:
                        guard discardLocalDocumentDraftConfirmationPresenter(closeConfirmationState.displayName) else {
                            return .canceled
                        }

                    case .saveInProgress:
                        localDocumentSaveInProgressPresenter(closeConfirmationState.displayName)
                        return .canceled
                    }
                }

            case .nonInteractive:
                if let closeConfirmationState = localDocumentCloseConfirmationStateProvider(panelID) {
                    switch closeConfirmationState.kind {
                    case .dirtyDraft:
                        return .confirmationRequired(
                            .dirtyLocalDocument(displayName: closeConfirmationState.displayName)
                        )
                    case .saveInProgress:
                        return .blocked(
                            .localDocumentSaveInProgress(displayName: closeConfirmationState.displayName)
                        )
                    }
                }
            }

        default:
            break
        }

        let didClosePanel = store.send(.closePanel(panelID: panelID), source: source)
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

    private func resolvedWorkspace(containing panelID: UUID, preferredWorkspaceID: UUID?) -> WorkspaceState? {
        guard let store else { return nil }

        if let preferredWorkspaceID,
           let workspace = store.state.workspacesByID[preferredWorkspaceID],
           workspace.panelState(for: panelID) != nil {
            return workspace
        }

        for window in store.state.windows {
            for workspaceID in window.workspaceIDs {
                guard let workspace = store.state.workspacesByID[workspaceID],
                      workspace.panelState(for: panelID) != nil else {
                    continue
                }
                return workspace
            }
        }

        return nil
    }

    private func focusedPanelID(in workspace: WorkspaceState) -> UUID? {
        workspace.rightAuxPanel.focusedPanelID ?? workspace.focusedPanelID
    }

    private static func presentRunningTerminalCloseConfirmation(_ assessment: TerminalCloseConfirmationAssessment) -> Bool {
        let confirmationAlert = NSAlert()
        confirmationAlert.messageText = "Close this terminal?"

        var informativeText = "A process is still running in this terminal. Closing the panel will terminate it."
        if let runningCommand = assessment.runningCommand {
            informativeText += "\n\nDetected command: \(runningCommand)"
        }
        confirmationAlert.informativeText = informativeText
        confirmationAlert.alertStyle = .warning
        confirmationAlert.addConfiguredButton(withTitle: "Cancel", behavior: .cancelAction)
        confirmationAlert.addConfiguredButton(
            withTitle: "Close",
            behavior: .defaultAction
        )

        let response = confirmationAlert.runModal()
        return response == .alertSecondButtonReturn
    }

    private static func presentDiscardLocalDocumentDraftConfirmation(displayName: String) -> Bool {
        let confirmationAlert = NSAlert()
        confirmationAlert.messageText = "Discard document draft?"
        confirmationAlert.informativeText = "\"\(displayName)\" has unsaved changes. Closing the panel will discard them."
        confirmationAlert.alertStyle = .warning
        confirmationAlert.addConfiguredButton(withTitle: "Cancel", behavior: .cancelAction)
        confirmationAlert.addConfiguredButton(
            withTitle: "Discard",
            behavior: .defaultAction
        )

        let response = confirmationAlert.runModal()
        return response == .alertSecondButtonReturn
    }

    private static func presentLocalDocumentSaveInProgressAlert(displayName: String) {
        let confirmationAlert = NSAlert()
        confirmationAlert.messageText = "Document save in progress"
        confirmationAlert.informativeText =
            "\"\(displayName)\" is still saving. Wait for the save to finish before closing this panel."
        confirmationAlert.alertStyle = .warning
        confirmationAlert.addConfiguredButton(withTitle: "OK", behavior: .defaultAction)
        _ = confirmationAlert.runModal()
    }
}
