import CoreState
import Foundation
import RemoteProtocol
import Testing

struct WorkspaceMergeRequestTests {
    private let requestedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func session(
        _ sessionID: String = "agent",
        agent: AgentKind = .claude,
        workspaceID: UUID = UUID(),
        kind: SessionStatusKind?,
        updatedAt: TimeInterval = 0,
        stoppedAt: TimeInterval? = nil
    ) -> SessionRecord {
        SessionRecord(
            sessionID: sessionID,
            agent: agent,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: workspaceID,
            status: kind.map { SessionStatus(kind: $0, summary: "\($0)") },
            startedAt: requestedAt,
            updatedAt: requestedAt.addingTimeInterval(updatedAt),
            stoppedAt: stoppedAt.map { requestedAt.addingTimeInterval($0) }
        )
    }

    private func registry(_ records: [SessionRecord]) -> SessionRegistry {
        SessionRegistry(
            sessionsByID: Dictionary(uniqueKeysWithValues: records.map { ($0.sessionID, $0) }),
            activeSessionIDByPanelID: Dictionary(
                uniqueKeysWithValues: records.filter(\.isActive).map { ($0.panelID, $0.sessionID) }
            ),
            sessionOrder: records.map(\.sessionID)
        )
    }

    // MARK: - Request lifecycle

    @Test
    func sessionWaitingForInputBeforeItsTurnStartsKeepsTheRequestPending() {
        let request = WorkspaceMergeRequest(sessionID: "agent", requestedAt: requestedAt)

        // The prompt was just typed, or the agent is still launching; the
        // agent has not reported working yet.
        for activity in [WorkspaceMergeSessionActivity.resting, .notReady, nil] {
            let step = request.advanced(
                isWorkspaceDone: false,
                sessionActivity: activity,
                now: requestedAt.addingTimeInterval(5)
            )
            #expect(step == .pending(request))
        }
    }

    @Test
    func turnThatEndsWithoutTheDoneMarkEndsTheRequest() {
        let request = WorkspaceMergeRequest(sessionID: "agent", requestedAt: requestedAt)

        guard case .pending(let started) = request.advanced(
            isWorkspaceDone: false,
            sessionActivity: .busy,
            now: requestedAt.addingTimeInterval(2)
        ) else {
            Issue.record("a busy session keeps the request pending")
            return
        }
        #expect(started.turnStarted)

        // The agent stopped, for example to ask about a prerequisite.
        #expect(
            started.advanced(
                isWorkspaceDone: false,
                sessionActivity: .resting,
                now: requestedAt.addingTimeInterval(30)
            ) == .ended(.turnEnded)
        )
    }

    @Test
    func doneMarkEndsTheRequestEvenMidTurn() {
        let request = WorkspaceMergeRequest(sessionID: "agent", requestedAt: requestedAt, turnStarted: true)

        #expect(
            request.advanced(
                isWorkspaceDone: true,
                sessionActivity: .busy,
                now: requestedAt.addingTimeInterval(20)
            ) == .ended(.workspaceDone)
        )
    }

    @Test
    func stoppedSessionEndsTheRequest() {
        let request = WorkspaceMergeRequest(sessionID: "agent", requestedAt: requestedAt)

        #expect(
            request.advanced(isWorkspaceDone: false, sessionActivity: .stopped, now: requestedAt)
                == .ended(.sessionStopped)
        )
    }

    @Test
    func promptThatNeverStartsATurnTimesOut() {
        // Covers both a typed prompt the agent ignored and a launch that
        // never produced a working session.
        for sessionID: String? in ["agent", nil] {
            let request = WorkspaceMergeRequest(sessionID: sessionID, requestedAt: requestedAt)
            let activity: WorkspaceMergeSessionActivity? = sessionID == nil ? nil : .resting

            #expect(
                request.advanced(
                    isWorkspaceDone: false,
                    sessionActivity: activity,
                    now: requestedAt.addingTimeInterval(WorkspaceMergeRequest.turnStartTimeout - 1)
                ) == .pending(request)
            )
            #expect(
                request.advanced(
                    isWorkspaceDone: false,
                    sessionActivity: activity,
                    now: requestedAt.addingTimeInterval(WorkspaceMergeRequest.turnStartTimeout)
                ) == .ended(.turnNeverStarted)
            )
        }
    }

    // MARK: - Session activity

    @Test
    func sessionActivityFollowsTheStatusItsRowShows() {
        var registry = registry([
            session("idle", kind: .idle),
            session("unreported", kind: nil),
            session("approving", kind: .needsApproval),
            session("stopped", kind: .working, stoppedAt: 3),
        ])
        #expect(registry.mergeSessionActivity(sessionID: "idle", at: requestedAt) == .resting)
        #expect(registry.mergeSessionActivity(sessionID: "unreported", at: requestedAt) == .notReady)
        #expect(registry.mergeSessionActivity(sessionID: "approving", at: requestedAt) == .busy)
        #expect(registry.mergeSessionActivity(sessionID: "stopped", at: requestedAt) == .stopped)
        #expect(registry.mergeSessionActivity(sessionID: "unknown", at: requestedAt) == .stopped)

        // The agent's own turn ended, but a sub-agent it started still runs.
        _ = registry.updateBackgroundActivity(
            sessionID: "idle",
            activity: SessionBackgroundActivity(
                id: "review",
                kind: .subagent,
                displayName: "Review",
                startedAt: requestedAt,
                lastUpdatedAt: requestedAt
            ),
            at: requestedAt
        )
        #expect(registry.mergeSessionActivity(sessionID: "idle", at: requestedAt) == .busy)
    }

    // MARK: - Target session

    @Test
    func targetIsTheMostRecentlyUpdatedSessionAtRest() {
        let workspaceID = UUID()
        let older = session("older", workspaceID: workspaceID, kind: .idle, updatedAt: 10)
        let newer = session("newer", workspaceID: workspaceID, kind: .ready, updatedAt: 20)
        let busy = session("busy", workspaceID: workspaceID, kind: .working, updatedAt: 30)
        let elsewhere = session("elsewhere", workspaceID: UUID(), kind: .idle, updatedAt: 40)
        let watch = session("watch", agent: .processWatch, workspaceID: workspaceID, kind: .idle, updatedAt: 50)

        let target = registry([older, newer, busy, elsewhere, watch]).mergeTarget(workspaceID: workspaceID)

        #expect(target == .session(newer))
    }

    @Test
    func targetIsBusyWhenEveryAgentSessionIsMidTurn() {
        let workspaceID = UUID()
        let working = session("working", workspaceID: workspaceID, kind: .working)
        let approving = session("approving", workspaceID: workspaceID, kind: .needsApproval)

        // A session that has not reported yet may still be starting up.
        let unreported = session("unreported", workspaceID: workspaceID, kind: nil)

        #expect(registry([working, approving, unreported]).mergeTarget(workspaceID: workspaceID) == .busy)
    }

    @Test
    func targetNamesTheLastAgentWhenNoSessionIsRunning() {
        let workspaceID = UUID()
        let codex = session("codex", agent: .codex, workspaceID: workspaceID, kind: .idle, stoppedAt: 10)
        let claude = session("claude", agent: .claude, workspaceID: workspaceID, kind: .idle, stoppedAt: 20)
        // A process watch is not an agent that can take a prompt.
        let watch = session("watch", agent: .processWatch, workspaceID: workspaceID, kind: .working)

        #expect(
            registry([codex, claude, watch]).mergeTarget(workspaceID: workspaceID) == .noSession(lastAgent: .claude)
        )
        #expect(SessionRegistry().mergeTarget(workspaceID: workspaceID) == .noSession(lastAgent: nil))
    }
}
