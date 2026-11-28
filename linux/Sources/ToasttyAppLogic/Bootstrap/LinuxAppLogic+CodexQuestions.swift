import CoreState
import Foundation

/// Codex's async questions (`CodexPendingQuestionMonitor`): the sidebar shows
/// them on the session row, and a question the user is not looking at marks
/// the panel unread and posts a desktop notification, like a terminal
/// notification would. Hooks keep the session "working" meanwhile, and the
/// shared notification path suppresses notifications for managed sessions,
/// so neither would surface the question.
extension LinuxAppLogic {
    /// The oldest unanswered question of a Codex session, if any.
    public func codexPendingQuestion(sessionID: String) -> String? {
        codexQuestionMonitor?.pendingQuestion(sessionID: sessionID)?.title
    }

    func startCodexQuestionMonitor() {
        let monitor = CodexPendingQuestionMonitor(
            targets: { [weak self] in self?.codexQuestionTargets() ?? [] },
            onChange: { [weak self] in self?.codexQuestionChanges.send(()) },
            onQuestionAsked: { [weak self] target, question in
                self?.surfaceCodexQuestion(question, target: target)
            }
        )
        codexQuestionMonitor = monitor
        monitor.start()
    }

    /// Active Codex sessions whose rollout this session captured (the same
    /// rule as `ManagedAgentLaunchPlanner.synchronizeCodexRolloutWatcher`).
    func codexQuestionTargets() -> [CodexPendingQuestionMonitor.Target] {
        let state = store.state
        let registry = sessionRuntimeStore.sessionRegistry
        return registry.sessionsByID.values.compactMap { record in
            guard record.agent == .codex,
                  registry.activeSession(sessionID: record.sessionID) != nil,
                  case .terminal(let terminal)? = state.workspaceSelection(containingPanelID: record.panelID)?
                    .workspace.panelState(for: record.panelID),
                  let resume = terminal.resumeRecord,
                  resume.agent == .codex,
                  resume.capturedAt >= record.startedAt,
                  resume.sessionFilePath.isEmpty == false else { return nil }
            return CodexPendingQuestionMonitor.Target(
                sessionID: record.sessionID,
                panelID: record.panelID,
                workspaceID: record.workspaceID,
                rolloutURL: URL(fileURLWithPath: resume.sessionFilePath)
            )
        }
    }

    private func surfaceCodexQuestion(_ question: CodexPendingQuestionMonitor.Question, target: CodexPendingQuestionMonitor.Target) {
        let state = store.state
        let workspaceID = state.workspaceSelection(containingPanelID: target.panelID)?.workspaceID ?? target.workspaceID
        let isLookingAtPanel = NSApplication.shared.isActive
            && state.selectedWorkspaceSelection()?.workspaceID == workspaceID
            && state.workspacesByID[workspaceID]?.focusedPanelID == target.panelID
        ToasttyLog.info(
            "Codex asked a question",
            category: .notifications,
            metadata: [
                "session_id": target.sessionID,
                "panel_id": target.panelID.uuidString,
                "workspace_id": workspaceID.uuidString,
                "call_id": question.callID,
                "notified": isLookingAtPanel ? "false" : "true",
            ]
        )
        guard isLookingAtPanel == false else { return }
        _ = store.send(.recordDesktopNotification(workspaceID: workspaceID, panelID: target.panelID))
        Task {
            await SystemNotificationSender.send(
                title: "Codex has a question",
                body: question.title,
                workspaceID: workspaceID,
                panelID: target.panelID
            )
        }
    }
}
