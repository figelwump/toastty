import CoreState

/// The setup state shared by task actions and the recovery card.
enum TaskSetupPresentation {
    /// What a move into a worktree is doing now, from the steps it saved.
    static func startWorkStep(_ record: TaskRecord) -> String {
        let operation = record.operation
        if record.worktree == nil {
            return "making the worktree"
        }
        if operation.hookFinishedAt == nil {
            return "running create_hook"
        }
        guard let session = operation.worktreeSession, session.sessionID != nil else {
            return "waiting for the agent's turn to end"
        }
        if session.forked, session.nativeConversationID == nil {
            return "waiting for the forked agent"
        }
        return "closing the old session"
    }

    static func isSettingUp(_ record: TaskRecord) -> Bool {
        guard record.archivedAt == nil, record.doneAt == nil, record.mergedAt == nil, record.shippedAt == nil else { return false }
        guard record.setup.isStarted else { return true }
        switch record.startWork?.state {
        case .running?, .failed?: return true
        case .finished?, nil: return false
        }
    }

    /// Whether Retry applies: setup or a move into a worktree failed.
    static func canRetry(_ record: TaskRecord) -> Bool {
        if case .setupFailed = record.setup { return true }
        if record.setup.isStarted, case .failed? = record.startWork?.state { return true }
        return false
    }

    /// Why setup or the move failed, for the popover.
    static func failureReason(_ record: TaskRecord) -> String? {
        if case .setupFailed(let reason) = record.setup { return reason }
        if record.setup.isStarted, case .failed(let reason)? = record.startWork?.state { return reason }
        return nil
    }
}
