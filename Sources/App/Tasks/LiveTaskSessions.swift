import CoreState
import RemoteProtocol
import Foundation

/// The live sessions behind `TaskSessionProviding`: the session registry,
/// local and phone input, and the pane close that a moved session uses.
@MainActor
final class LiveTaskSessions: TaskSessionProviding {
    private weak var sessionRuntimeStore: SessionRuntimeStore?
    private let closeController: SessionCloseController
    private weak var exitController: SessionExitController?
    private let sendText: @MainActor (_ text: String, _ panelID: UUID) -> Bool

    init(
        sessionRuntimeStore: SessionRuntimeStore,
        closeController: SessionCloseController,
        exitController: SessionExitController?,
        sendText: @escaping @MainActor (String, UUID) -> Bool
    ) {
        self.sessionRuntimeStore = sessionRuntimeStore
        self.closeController = closeController
        self.exitController = exitController
        self.sendText = sendText
    }

    func session(_ sessionID: String) -> TaskSessionInfo? {
        guard let sessionRuntimeStore,
              let record = sessionRuntimeStore.sessionRegistry.sessionsByID[sessionID] else { return nil }
        // Only a binding confirmed for this session in this panel names its
        // conversation.
        let binding = sessionRuntimeStore.nativeSessionBindingConfirmation(for: sessionID)
            .flatMap { $0.agent == record.agent && $0.panelID == record.panelID ? $0 : nil }
        return TaskSessionInfo(
            sessionID: record.sessionID,
            agent: record.agent,
            panelID: record.panelID,
            workspaceID: record.workspaceID,
            cwd: record.cwd,
            isActive: sessionRuntimeStore.sessionRegistry.activeSession(sessionID: sessionID) != nil,
            isInTurn: [.working, .needsApproval].contains(record.status?.kind),
            nativeConversationID: binding?.nativeSessionID,
            title: record.displayTitleOverride ?? record.providerSessionName
        )
    }

    func activeSession(panelID: UUID) -> TaskSessionInfo? {
        guard let sessionID = sessionRuntimeStore?.sessionRegistry.activeSession(for: panelID)?.sessionID else { return nil }
        return session(sessionID)
    }

    func hasInput(panelID: UUID, since date: Date) -> Bool {
        if let typedAt = sessionRuntimeStore?.lastLocalInputAt(panelID: panelID), typedAt > date {
            return true
        }
        return exitController?.remoteInputProbe?.hasRemoteInput(panelID: panelID, since: date) == true
    }

    func closeMovedSessionPane(panelID: UUID, agent: AgentKind) -> TaskOperation.SourceOutcome {
        switch closeController.closeMovedSessionPane(panelID: panelID) {
        case .closed:
            return .closed
        case .workspaceCloseConfirmationRequired:
            // The pane is its workspace's last: end the agent and keep the
            // shell, so the workspace stays as it was before the agent ran.
            guard let exitCommand = SessionExitController.nativeExitCommand(for: agent),
                  sendText(exitCommand, panelID) else {
                return .kept(reason: "This was its workspace's last pane, so it stays open.")
            }
            return .exited
        case .unsavedDocument(let name):
            return .kept(reason: "Its tab has unsaved changes in \(name ?? "a document").")
        case .confirmationRequired, .notFound, .failed:
            return .kept(reason: "Toastty could not close it.")
        }
    }
}
