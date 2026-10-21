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
    /// Types a message and reports whether it was submitted, so a caller
    /// never types it twice after a Return that may not have gone through.
    private let deliverText: @MainActor (_ text: String, _ panelID: UUID) -> TerminalInputDeliveryResult
    private let replyReader = TaskAgentReplyReader()

    init(
        sessionRuntimeStore: SessionRuntimeStore,
        closeController: SessionCloseController,
        exitController: SessionExitController?,
        sendText: @escaping @MainActor (String, UUID) -> Bool,
        deliverText: (@MainActor (String, UUID) -> TerminalInputDeliveryResult)? = nil
    ) {
        self.sessionRuntimeStore = sessionRuntimeStore
        self.closeController = closeController
        self.exitController = exitController
        self.sendText = sendText
        self.deliverText = deliverText ?? { text, panelID in sendText(text, panelID) ? .delivered : .unavailable }
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
            title: record.displayTitleOverride ?? record.providerSessionName,
            status: record.status,
            statusUpdatedAt: record.statusUpdatedAt,
            lastTurnEndedAt: record.lastTurnEndedAt,
            transcriptPath: binding.flatMap { $0.sessionFilePath.isEmpty ? nil : $0.sessionFilePath }
        )
    }

    func activeSession(panelID: UUID) -> TaskSessionInfo? {
        guard let sessionID = sessionRuntimeStore?.sessionRegistry.activeSession(for: panelID)?.sessionID else { return nil }
        return session(sessionID)
    }

    func activeSessions(workspaceID: UUID) -> [TaskSessionInfo] {
        guard let registry = sessionRuntimeStore?.sessionRegistry else { return [] }
        return registry.sessionsByID.values
            .filter { $0.workspaceID == workspaceID && $0.agent != .processWatch && registry.activeSession(sessionID: $0.sessionID) != nil }
            .compactMap { session($0.sessionID) }
    }

    func deliver(_ text: String, panelID: UUID) -> TerminalInputDeliveryResult {
        deliverText(text, panelID)
    }

    func lastReply(sessionID: String) -> TaskAgentReply? {
        guard let info = session(sessionID) else { return nil }
        if let path = info.transcriptPath {
            return replyReader.lastReply(agent: info.agent, transcriptPath: path)
        }
        // Agents without a transcript file publish their history through
        // Toastty's extension instead.
        guard let feed = sessionRuntimeStore?.providerConversationFeed(managedSessionID: sessionID) else { return nil }
        return TaskAgentReplyReader.lastReply(in: feed.observations)
    }

    /// The effective scope: an empty explicit scope still allows the
    /// session's own workspace.
    func scope(sessionID: String) -> Set<UUID>? {
        guard let sessionRuntimeStore, sessionRuntimeStore.sessionRegistry.activeSession(sessionID: sessionID) != nil else { return nil }
        return sessionRuntimeStore.effectiveWorkspaceScope(sessionID: sessionID)
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
