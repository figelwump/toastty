import CoreState
import Foundation

@MainActor
final class ProcessWatchCommandController {
    private let store: AppStore
    private let sessionRuntimeStore: SessionRuntimeStore
    private let preferredWindowIDProvider: () -> UUID?
    private let promptStateResolver: (UUID) -> TerminalPromptState

    init(
        store: AppStore,
        terminalRuntimeRegistry: TerminalRuntimeRegistry,
        sessionRuntimeStore: SessionRuntimeStore,
        preferredWindowIDProvider: @escaping () -> UUID? = { nil },
        promptStateResolver: ((UUID) -> TerminalPromptState)? = nil
    ) {
        self.store = store
        self.sessionRuntimeStore = sessionRuntimeStore
        self.preferredWindowIDProvider = preferredWindowIDProvider
        self.promptStateResolver = promptStateResolver ?? { terminalRuntimeRegistry.promptState(panelID: $0) }
    }

    func canWatchFocusedProcess() -> Bool {
        canWatchFocusedProcess(preferredWindowID: preferredWindowIDProvider())
    }

    func canWatchFocusedProcess(preferredWindowID: UUID?) -> Bool {
        commandContext(preferredWindowID: preferredWindowID) != nil
    }

    @discardableResult
    func watchFocusedProcess() -> Bool {
        watchFocusedProcess(preferredWindowID: preferredWindowIDProvider())
    }

    @discardableResult
    func watchFocusedProcess(preferredWindowID: UUID?) -> Bool {
        guard let context = commandContext(preferredWindowID: preferredWindowID) else {
            return false
        }

        sessionRuntimeStore.startProcessWatch(
            panelID: context.panelID,
            windowID: context.windowID,
            workspaceID: context.workspaceID,
            displayTitleOverride: context.terminalState.processWatchDisplayTitle,
            cwd: context.terminalState.expectedProcessWorkingDirectory,
            repoRoot: nil,
            at: Date()
        )
        return true
    }

    private func commandContext(preferredWindowID: UUID?) -> CommandContext? {
        guard let selection = store.commandSelection(preferredWindowID: preferredWindowID),
              let panelID = selection.workspace.focusedPanelID,
              selection.workspace.layoutTree.slotContaining(panelID: panelID) != nil,
              case .terminal(let terminalState)? = selection.workspace.panelState(for: panelID),
              promptStateResolver(panelID) == .busy,
              sessionRuntimeStore.sessionRegistry.activeSession(for: panelID) == nil else {
            return nil
        }

        return CommandContext(
            windowID: selection.windowID,
            workspaceID: selection.workspace.id,
            panelID: panelID,
            terminalState: terminalState
        )
    }
}

private extension ProcessWatchCommandController {
    struct CommandContext {
        let windowID: UUID
        let workspaceID: UUID
        let panelID: UUID
        let terminalState: TerminalPanelState
    }
}
