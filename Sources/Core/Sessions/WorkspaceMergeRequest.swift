import Foundation
import RemoteProtocol

/// A merge the user asked for with a workspace's Merge button, tracked from
/// the click until the agent finishes it or drops it. Runtime-only: after a
/// relaunch the button offers Merge again.
public struct WorkspaceMergeRequest: Equatable, Sendable {
    /// How long the session may stay at rest after the prompt before the
    /// request counts as never picked up. Covers a freshly launched agent
    /// that is still starting.
    public static let turnStartTimeout: TimeInterval = 90

    /// The managed session the merge prompt went to, or `nil` while the
    /// agent that will receive it is still launching.
    public let sessionID: String?
    public let requestedAt: Date
    /// Whether that session has been seen busy since the request. Until it
    /// has, a session at rest has not picked the prompt up yet, rather than
    /// finished with it.
    public var turnStarted: Bool

    public init(sessionID: String?, requestedAt: Date, turnStarted: Bool = false) {
        self.sessionID = sessionID
        self.requestedAt = requestedAt
        self.turnStarted = turnStarted
    }

    public enum End: String, Equatable, Sendable {
        /// The workspace's done mark was set, which is how the merge
        /// workflow reports success.
        case workspaceDone = "workspace_done"
        /// The agent's turn ended without the done mark, for example because
        /// it stopped to ask about a prerequisite.
        case turnEnded = "turn_ended"
        case sessionStopped = "session_stopped"
        case turnNeverStarted = "turn_never_started"
    }

    public enum Step: Equatable, Sendable {
        case pending(WorkspaceMergeRequest)
        case ended(End)
    }

    /// Where the request stands given the workspace's done mark and what the
    /// target session is doing. Pass `nil` for `sessionActivity` while the
    /// agent is still launching and has no session yet.
    public func advanced(
        isWorkspaceDone: Bool,
        sessionActivity: WorkspaceMergeSessionActivity?,
        now: Date
    ) -> Step {
        if isWorkspaceDone {
            return .ended(.workspaceDone)
        }
        switch sessionActivity {
        case .stopped:
            return .ended(.sessionStopped)
        case .busy:
            var next = self
            next.turnStarted = true
            return .pending(next)
        case .notReady, .resting, nil:
            if turnStarted {
                return .ended(.turnEnded)
            }
            if now.timeIntervalSince(requestedAt) >= Self.turnStartTimeout {
                return .ended(.turnNeverStarted)
            }
            return .pending(self)
        }
    }
}

/// What a managed agent session is doing, as far as a merge request cares.
public enum WorkspaceMergeSessionActivity: Equatable, Sendable {
    /// The session ended, or the registry no longer knows it.
    case stopped
    /// The session has not reported a status yet, as right after launch.
    case notReady
    /// Waiting for input: idle, an unread finished turn, or a failed turn.
    case resting
    /// Mid-turn: working, paused on an approval, waiting on child work, or
    /// resuming after it.
    case busy
}

/// Where a workspace's merge prompt can go.
public enum WorkspaceMergeTarget: Equatable, Sendable {
    /// An agent session waiting for input, which can take the prompt as its
    /// next turn.
    case session(SessionRecord)
    /// Agent sessions are running, and none is waiting for input.
    case busy
    /// No agent session is running. `lastAgent` is the agent that most
    /// recently ran here, when the registry still remembers one.
    case noSession(lastAgent: AgentKind?)
}

public extension SessionStatusKind {
    /// Mid-turn: working, or paused on an approval inside the turn.
    static func isBusy(_ kind: SessionStatusKind?) -> Bool {
        kind == .working || kind == .needsApproval
    }
}

public extension SessionRegistry {
    /// Uses the status a session's row shows, not only the one it reported:
    /// a session whose own turn ended while its sub-agents still run is busy.
    func mergeSessionActivity(sessionID: String, at now: Date = Date()) -> WorkspaceMergeSessionActivity {
        guard let record = sessionsByID[sessionID], record.isActive else {
            return .stopped
        }
        return mergeSessionActivity(of: record, at: now)
    }

    private func mergeSessionActivity(of record: SessionRecord, at now: Date) -> WorkspaceMergeSessionActivity {
        guard let kind = effectiveStatusKind(of: record, at: now) else {
            return .notReady
        }
        return SessionStatusKind.isBusy(kind) ? .busy : .resting
    }

    /// Picks the session that should receive a workspace's merge prompt: the
    /// most recently updated agent session that is waiting for input.
    func mergeTarget(workspaceID: UUID, at now: Date = Date()) -> WorkspaceMergeTarget {
        let agentSessions = sessionsByID.values.filter {
            $0.workspaceID == workspaceID && $0.agent != .processWatch
        }
        let activeSessions = agentSessions.filter(\.isActive)
        let restingSession = activeSessions
            .filter { mergeSessionActivity(of: $0, at: now) == .resting }
            .max { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt < rhs.updatedAt
                }
                return lhs.sessionID > rhs.sessionID
            }
        if let restingSession {
            return .session(restingSession)
        }
        if activeSessions.isEmpty == false {
            return .busy
        }
        let lastStopped = agentSessions.max { lhs, rhs in
            (lhs.stoppedAt ?? lhs.updatedAt) < (rhs.stoppedAt ?? rhs.updatedAt)
        }
        return .noSession(lastAgent: lastStopped?.agent)
    }
}
