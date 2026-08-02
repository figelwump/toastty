import Combine
import CoreState
import Foundation
import Testing
@testable import ToasttyApp

extension SessionRuntimeStoreTests {
    @Test
    func staleBackgroundActivityPruningRestoresBaseStatus() {
        let store = SessionRuntimeStore(maximumBackgroundActivityAge: 60)
        defer { store.reset() }
        let workspaceID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_001_000)

        store.startSession(
            sessionID: "sess-background-prune",
            agent: .claude,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: now
        )
        store.updateStatus(
            sessionID: "sess-background-prune",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Root turn completed"),
            at: now
        )
        #expect(store.updateBackgroundActivity(
            sessionID: "sess-background-prune",
            activity: SessionBackgroundActivity(
                id: "child-1",
                kind: .childAgent,
                displayName: "Codex",
                processID: Int32(ProcessInfo.processInfo.processIdentifier),
                startedAt: now,
                lastUpdatedAt: now
            ),
            at: now
        ))

        #expect(store.workspaceStatuses(for: workspaceID).first?.status.kind == .working)
        #expect(store.pruneStaleBackgroundActivities(at: now.addingTimeInterval(30)) == false)
        #expect(store.workspaceStatuses(for: workspaceID).first?.status.kind == .working)
        #expect(store.pruneStaleBackgroundActivities(at: now.addingTimeInterval(61)))
        #expect(store.workspaceStatuses(for: workspaceID).first?.status.kind == .ready)
    }

    @Test
    func pidlessSubagentBackgroundActivityUsesThirtyMinuteReapCap() {
        let store = SessionRuntimeStore(maximumBackgroundActivityAge: 8 * 60 * 60)
        defer { store.reset() }
        let workspaceID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_001_100)

        store.startSession(
            sessionID: "sess-subagent-prune",
            agent: .claude,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: now
        )
        store.updateStatus(
            sessionID: "sess-subagent-prune",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Root turn completed"),
            at: now
        )
        #expect(store.updateBackgroundActivity(
            sessionID: "sess-subagent-prune",
            activity: SessionBackgroundActivity(
                id: "subagent-1",
                kind: .subagent,
                displayName: "general-purpose",
                startedAt: now,
                lastUpdatedAt: now
            ),
            at: now
        ))

        #expect(store.pruneStaleBackgroundActivities(at: now.addingTimeInterval(29 * 60)) == false)
        #expect(store.workspaceStatuses(for: workspaceID).first?.status.kind == .working)
        #expect(store.pruneStaleBackgroundActivities(at: now.addingTimeInterval(31 * 60)))
        #expect(store.workspaceStatuses(for: workspaceID).first?.status.kind == .ready)
    }

    @Test
    func codexHookSubagentIsNotAgePrunedWhileSessionIsActive() throws {
        let store = SessionRuntimeStore(maximumBackgroundActivityAge: 8 * 60 * 60)
        defer { store.reset() }
        let workspaceID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_001_150)
        let sessionID = "sess-codex-hook-long-running-subagent"

        store.startSession(
            sessionID: sessionID,
            agent: .codex,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: workspaceID,
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: now
        )

        #expect(store.handleCodexHookEvent(
            sessionID: sessionID,
            event: CodexHookEvent(
                hookEventName: "SubagentStart",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: nil,
                status: nil,
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil,
                subagentID: "agent-child",
                subagentType: "reviewer"
            ),
            at: now
        ))

        #expect(store.pruneStaleBackgroundActivities(at: now.addingTimeInterval(9 * 60 * 60)) == false)
        #expect(store.sessionRegistry.sessionsByID[sessionID]?
            .backgroundActivitiesByID["agent-child"] != nil)
    }

    @Test
    func duplicateCodexSubagentStartsUpsertSingleBackgroundActivity() throws {
        let store = SessionRuntimeStore()
        defer { store.reset() }
        let workspaceID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_001_125)

        store.startSession(
            sessionID: "sess-codex-subagent-upsert",
            agent: .codex,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: now
        )
        store.updateStatus(
            sessionID: "sess-codex-subagent-upsert",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Root turn ended"),
            at: now.addingTimeInterval(1)
        )

        #expect(store.updateBackgroundActivity(
            sessionID: "sess-codex-subagent-upsert",
            activity: SessionBackgroundActivity(
                id: "agent-1",
                kind: .subagent,
                displayName: "Herschel",
                command: "Inspect the diff",
                startedAt: now.addingTimeInterval(2),
                lastUpdatedAt: now.addingTimeInterval(2)
            ),
            at: now.addingTimeInterval(2)
        ))
        #expect(store.updateBackgroundActivity(
            sessionID: "sess-codex-subagent-upsert",
            activity: SessionBackgroundActivity(
                id: "agent-1",
                kind: .subagent,
                displayName: "Herschel",
                command: "Inspect the diff",
                startedAt: now.addingTimeInterval(3),
                lastUpdatedAt: now.addingTimeInterval(3)
            ),
            at: now.addingTimeInterval(3)
        ))

        let activities = try #require(
            store.sessionRegistry.sessionsByID["sess-codex-subagent-upsert"]?.backgroundActivitiesByID
        )
        #expect(activities.count == 1)
        let activity = try #require(activities["agent-1"])
        #expect(activity.startedAt == now.addingTimeInterval(2))
        #expect(activity.lastUpdatedAt == now.addingTimeInterval(3))
        #expect(store.workspaceStatuses(for: workspaceID).first?.projection == .waitingOnChildren(
            childCount: 1,
            pendingBackgroundTaskCount: 0
        ))
    }

    @Test
    func workspaceStatusChildrenCombineCrossWorkspaceSessionAndActivityRowsUntilChildStops() throws {
        let store = SessionRuntimeStore()
        defer { store.reset() }
        let parentWorkspaceID = UUID()
        let childWorkspaceID = UUID()
        let childPanelID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_001_150)

        store.startSession(
            sessionID: "parent",
            agent: .claude,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: parentWorkspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: now
        )
        store.updateStatus(
            sessionID: "parent",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Root turn complete"),
            at: now.addingTimeInterval(1)
        )
        store.updateBackgroundActivity(
            sessionID: "parent",
            activity: SessionBackgroundActivity(
                id: "activity",
                kind: .subagent,
                displayName: "Explore",
                command: "find status callers",
                startedAt: now.addingTimeInterval(2),
                lastUpdatedAt: now.addingTimeInterval(2)
            ),
            at: now.addingTimeInterval(2)
        )
        store.startSession(
            sessionID: "child",
            agent: .codex,
            panelID: childPanelID,
            windowID: UUID(),
            workspaceID: childWorkspaceID,
            parentSessionID: "parent",
            cwd: "/repo",
            repoRoot: "/repo",
            at: now.addingTimeInterval(3)
        )
        store.updateStatus(
            sessionID: "child",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Running tests"),
            at: now.addingTimeInterval(4)
        )

        let parentStatus = try #require(store.workspaceStatuses(for: parentWorkspaceID).first)
        #expect(parentStatus.children.map(\.id) == ["activity", "child"])
        #expect(parentStatus.children.map(\.source) == [.activity, .session])
        #expect(parentStatus.children[1].panelID == childPanelID)
        #expect(parentStatus.children[1].workspaceID == childWorkspaceID)
        #expect(parentStatus.children[1].statusKind == .working)

        store.stopSession(sessionID: "child", at: now.addingTimeInterval(5))

        let updatedParentStatus = try #require(store.workspaceStatuses(for: parentWorkspaceID).first)
        #expect(updatedParentStatus.children.map(\.id) == ["activity"])
    }

    @Test
    func finishTombstoneBlocksLateSubagentStart() {
        let store = SessionRuntimeStore()
        defer { store.reset() }
        let workspaceID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_001_200)

        store.startSession(
            sessionID: "sess-tombstone-start",
            agent: .claude,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: now
        )

        #expect(store.finishBackgroundActivity(
            sessionID: "sess-tombstone-start",
            activityID: "subagent-1",
            at: now
        ) == false)
        #expect(store.updateBackgroundActivity(
            sessionID: "sess-tombstone-start",
            activity: SessionBackgroundActivity(
                id: "subagent-1",
                kind: .subagent,
                displayName: "general-purpose",
                startedAt: now.addingTimeInterval(1),
                lastUpdatedAt: now.addingTimeInterval(1)
            ),
            at: now.addingTimeInterval(1)
        ) == false)
        #expect(store.sessionRegistry.sessionsByID["sess-tombstone-start"]?.backgroundActivitiesByID.isEmpty == true)
    }

    @Test
    func codexSubagentHooksFinishAndAuthoritativelyReopenActivity() throws {
        let store = SessionRuntimeStore()
        defer { store.reset() }
        let workspaceID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_001_250)
        let sessionID = "sess-codex-hook-subagent"

        store.startSession(
            sessionID: sessionID,
            agent: .codex,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: workspaceID,
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: now
        )

        let startEvent = CodexHookEvent(
            hookEventName: "SubagentStart",
            threadID: "thread-root",
            turnID: "turn-root",
            promptFingerprint: nil,
            status: nil,
            nativeSessionID: "thread-root",
            sessionFilePath: nil,
            cwd: nil,
            subagentID: "agent-child",
            subagentType: "reviewer"
        )
        #expect(store.handleCodexHookEvent(
            sessionID: sessionID,
            event: startEvent,
            at: now.addingTimeInterval(1)
        ))
        #expect(store.sessionRegistry.sessionsByID[sessionID]?
            .backgroundActivitiesByID["agent-child"]?.displayName == "reviewer")

        let stopEvent = CodexHookEvent(
            hookEventName: "SubagentStop",
            threadID: "thread-root",
            turnID: "turn-root",
            promptFingerprint: nil,
            status: nil,
            nativeSessionID: "thread-root",
            sessionFilePath: nil,
            cwd: nil,
            subagentID: "agent-child",
            subagentType: "reviewer"
        )
        #expect(store.handleCodexHookEvent(
            sessionID: sessionID,
            event: stopEvent,
            at: now.addingTimeInterval(2)
        ))
        #expect(store.sessionRegistry.sessionsByID[sessionID]?
            .backgroundActivitiesByID["agent-child"] == nil)

        #expect(store.handleCodexHookEvent(
            sessionID: sessionID,
            event: startEvent,
            at: now.addingTimeInterval(3)
        ))
        #expect(store.sessionRegistry.sessionsByID[sessionID]?
            .backgroundActivitiesByID["agent-child"] != nil)
        #expect(store.workspaceStatuses(for: workspaceID).first?.projection == .waitingOnChildren(
            childCount: 1,
            pendingBackgroundTaskCount: 0
        ))
    }

    @Test
    func codexSessionLogFallbackFinishTombstoneBlocksInferredFollowUpStart() {
        let store = SessionRuntimeStore()
        defer { store.reset() }
        let now = Date(timeIntervalSince1970: 1_700_001_275)
        let sessionID = "sess-codex-fallback-follow-up"
        let activityID = "/root/plan_review"

        store.startSession(
            sessionID: sessionID,
            agent: .codex,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .sessionLogFallback(reason: "characterization"),
            cwd: "/repo",
            repoRoot: "/repo",
            at: now
        )

        #expect(store.updateBackgroundActivity(
            sessionID: sessionID,
            activity: SessionBackgroundActivity(
                id: activityID,
                kind: .subagent,
                displayName: "plan_review",
                startedAt: now,
                lastUpdatedAt: now
            ),
            at: now
        ))
        #expect(store.finishBackgroundActivity(
            sessionID: sessionID,
            activityID: activityID,
            at: now.addingTimeInterval(1)
        ))

        #expect(store.updateBackgroundActivity(
            sessionID: sessionID,
            activity: SessionBackgroundActivity(
                id: activityID,
                kind: .subagent,
                displayName: "plan_review",
                startedAt: now.addingTimeInterval(2),
                lastUpdatedAt: now.addingTimeInterval(2)
            ),
            at: now.addingTimeInterval(2)
        ) == false)
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?
            .backgroundActivitiesByID[activityID] == nil)
    }

    @Test
    func finishTombstoneBlocksStaleSyncUntilTTLExpires() {
        let store = SessionRuntimeStore()
        defer { store.reset() }
        let workspaceID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_001_300)

        store.startSession(
            sessionID: "sess-tombstone-sync",
            agent: .claude,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: now
        )

        #expect(store.finishBackgroundActivity(
            sessionID: "sess-tombstone-sync",
            activityID: "subagent-1",
            at: now
        ) == false)
        #expect(store.syncBackgroundActivities(
            sessionID: "sess-tombstone-sync",
            kind: .subagent,
            entries: [
                SessionBackgroundActivity(
                    id: "subagent-1",
                    kind: .subagent,
                    displayName: "general-purpose",
                    startedAt: now.addingTimeInterval(1),
                    lastUpdatedAt: now.addingTimeInterval(1)
                ),
            ],
            pendingBackgroundTaskCount: 0,
            at: now.addingTimeInterval(1)
        ) == false)
        #expect(store.sessionRegistry.sessionsByID["sess-tombstone-sync"]?.backgroundActivitiesByID.isEmpty == true)

        #expect(store.syncBackgroundActivities(
            sessionID: "sess-tombstone-sync",
            kind: .subagent,
            entries: [
                SessionBackgroundActivity(
                    id: "subagent-1",
                    kind: .subagent,
                    displayName: "general-purpose",
                    startedAt: now.addingTimeInterval(121),
                    lastUpdatedAt: now.addingTimeInterval(121)
                ),
            ],
            pendingBackgroundTaskCount: 0,
            at: now.addingTimeInterval(121)
        ))
        #expect(store.sessionRegistry.sessionsByID["sess-tombstone-sync"]?.backgroundActivitiesByID["subagent-1"] != nil)
    }

}
