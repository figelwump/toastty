import Combine
import CoreState
import Foundation
import Testing
@testable import ToasttyApp

@MainActor
struct SessionRuntimeStoreTests {
    @Test
    func scopeMutationUpdatesWorkspaceStatusProjection() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let workspaceID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-scope",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.updateStatus(
            sessionID: "sess-scope",
            status: SessionStatus(kind: .idle, summary: "Waiting"),
            at: startedAt
        )

        #expect(store.workspaceStatuses(for: workspaceID).first?.isWorkspaceScoped == false)

        #expect(store.setScope(sessionID: "sess-scope", workspaceIDs: []))
        #expect(store.workspaceStatuses(for: workspaceID).first?.isWorkspaceScoped == true)

        #expect(store.clearScope(sessionID: "sess-scope"))
        #expect(store.workspaceStatuses(for: workspaceID).first?.isWorkspaceScoped == false)
    }

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

    @Test
    func scopeMutationUpdatesPersistedResumeRecordScope() throws {
        let appStore = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let panelID = try #require(selection.workspace.focusedPanelID)
        let scopedWorkspaceID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let resumeRecord = ManagedAgentResumeRecord(
            agent: .codex,
            nativeSessionID: "019e2823-f520-7690-91b6-cd84eb52dd8a",
            sessionFilePath: "/tmp/codex-session.jsonl",
            cwd: "/repo",
            capturedAt: startedAt
        )

        #expect(appStore.send(.updateTerminalPanelResumeRecord(panelID: panelID, resumeRecord: resumeRecord)))

        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)
        sessionStore.startSession(
            sessionID: "sess-scope-record",
            agent: .codex,
            panelID: panelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )

        #expect(sessionStore.setScope(sessionID: "sess-scope-record", workspaceIDs: []))
        #expect(persistedResumeRecord(panelID: panelID, in: appStore.state)?.scopedWorkspaceIDs == Set<UUID>())

        #expect(sessionStore.addScope(sessionID: "sess-scope-record", workspaceIDs: [scopedWorkspaceID]))
        #expect(
            persistedResumeRecord(panelID: panelID, in: appStore.state)?.scopedWorkspaceIDs ==
                Set([scopedWorkspaceID])
        )

        #expect(sessionStore.clearScope(sessionID: "sess-scope-record"))
        #expect(persistedResumeRecord(panelID: panelID, in: appStore.state)?.scopedWorkspaceIDs == nil)
    }

    @Test
    func stoppingSessionClearsPersistedResumeRecordScope() throws {
        let appStore = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let panelID = try #require(selection.workspace.focusedPanelID)
        let scopedWorkspaceID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let resumeRecord = ManagedAgentResumeRecord(
            agent: .codex,
            nativeSessionID: "019e2823-f520-7690-91b6-cd84eb52dd8a",
            sessionFilePath: "/tmp/codex-session.jsonl",
            cwd: "/repo",
            capturedAt: startedAt,
            scopedWorkspaceIDs: [scopedWorkspaceID]
        )

        #expect(appStore.send(.updateTerminalPanelResumeRecord(panelID: panelID, resumeRecord: resumeRecord)))

        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)
        sessionStore.startSession(
            sessionID: "sess-stop-record",
            agent: .codex,
            panelID: panelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            scopedWorkspaceIDs: [scopedWorkspaceID],
            at: startedAt
        )

        sessionStore.stopSession(sessionID: "sess-stop-record", at: startedAt.addingTimeInterval(1))

        #expect(persistedResumeRecord(panelID: panelID, in: appStore.state) == nil)
    }

    @Test
    func stopSessionForPanelIfActiveStopsCurrentSession() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-active",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )

        let didStop = store.stopSessionForPanelIfActive(
            panelID: panelID,
            reason: .explicit,
            at: startedAt.addingTimeInterval(1)
        )

        #expect(didStop)
        #expect(store.sessionRegistry.activeSession(for: panelID) == nil)
    }

    @Test
    func stopSessionForPanelIfOlderThanStopsEligibleSession() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-older",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )

        let didStop = store.stopSessionForPanelIfOlderThan(
            panelID: panelID,
            minimumRuntime: 2,
            reason: .explicit,
            at: startedAt.addingTimeInterval(3)
        )

        #expect(didStop)
        #expect(store.sessionRegistry.activeSession(for: panelID) == nil)
    }

    @Test
    func stopSessionForPanelIfOlderThanKeepsRecentSessionAlive() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-recent",
            agent: .claude,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )

        let didStop = store.stopSessionForPanelIfOlderThan(
            panelID: panelID,
            minimumRuntime: 2,
            reason: .explicit,
            at: startedAt.addingTimeInterval(1)
        )

        #expect(didStop == false)
        #expect(store.sessionRegistry.activeSession(for: panelID)?.sessionID == "sess-recent")
    }

    @Test
    func codexNotifyCompletionIgnoresChildThreadBeforeRootCompletes() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let rootFingerprint = CodexInputFingerprint.fingerprint(for: "Fix the sidebar state")

        store.startSession(
            sessionID: "sess-codex-notify",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.updateStatus(
            sessionID: "sess-codex-notify",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Fix the sidebar state"),
            at: startedAt.addingTimeInterval(1)
        )
        store.recordCodexRootTurnInput(sessionID: "sess-codex-notify", fingerprint: rootFingerprint)

        let ignoredChild = store.handleCodexNotifyCompletion(
            sessionID: "sess-codex-notify",
            completion: CodexNotifyCompletion(
                notificationType: "agent-turn-complete",
                threadID: "thread-child",
                turnID: "turn-child",
                lastInputMessageFingerprint: CodexInputFingerprint.fingerprint(for: "Inspect parser wiring"),
                inputMessageCount: 1,
                detail: "Child finished"
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(ignoredChild == false)
        #expect(store.sessionRegistry.activeSession(sessionID: "sess-codex-notify")?.status?.kind == .working)

        let acceptedRoot = store.handleCodexNotifyCompletion(
            sessionID: "sess-codex-notify",
            completion: CodexNotifyCompletion(
                notificationType: "agent-turn-complete",
                threadID: "thread-root",
                turnID: "turn-root",
                lastInputMessageFingerprint: rootFingerprint,
                inputMessageCount: 1,
                detail: "Root finished"
            ),
            at: startedAt.addingTimeInterval(3)
        )

        #expect(acceptedRoot)
        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-notify")?.status
        #expect(status?.kind == .ready)
        #expect(status?.detail == "Root finished")
    }

    @Test
    func codexNotifyCompletionIgnoresDifferentThreadAfterRootThreadIsLatched() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let rootFingerprint = CodexInputFingerprint.fingerprint(for: "Fix the sidebar state")

        store.startSession(
            sessionID: "sess-codex-root-latched",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.recordCodexRootTurnInput(sessionID: "sess-codex-root-latched", fingerprint: rootFingerprint)
        _ = store.handleCodexNotifyCompletion(
            sessionID: "sess-codex-root-latched",
            completion: CodexNotifyCompletion(
                notificationType: "agent-turn-complete",
                threadID: "thread-root",
                turnID: "turn-root-1",
                lastInputMessageFingerprint: rootFingerprint,
                inputMessageCount: 1,
                detail: "Root finished"
            ),
            at: startedAt.addingTimeInterval(1)
        )
        store.updateStatus(
            sessionID: "sess-codex-root-latched",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Next turn"),
            at: startedAt.addingTimeInterval(2)
        )

        let ignoredChild = store.handleCodexNotifyCompletion(
            sessionID: "sess-codex-root-latched",
            completion: CodexNotifyCompletion(
                notificationType: "agent-turn-complete",
                threadID: "thread-child",
                turnID: "turn-child",
                lastInputMessageFingerprint: CodexInputFingerprint.fingerprint(for: "Child task"),
                inputMessageCount: 1,
                detail: "Child finished"
            ),
            at: startedAt.addingTimeInterval(3)
        )

        #expect(ignoredChild == false)
        #expect(store.sessionRegistry.activeSession(sessionID: "sess-codex-root-latched")?.status?.kind == .working)
    }

    @Test
    func codexRootTurnInputThreadIDCanReplaceLatchedThreadForLaterGoal() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let firstFingerprint = CodexInputFingerprint.fingerprint(for: "Fix the sidebar state")
        let goalFingerprint = CodexInputFingerprint.fingerprint(for: "Implement the saved goal")

        store.startSession(
            sessionID: "sess-codex-goal-thread",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-goal-thread",
            fingerprint: firstFingerprint,
            threadID: "thread-first"
        )
        store.updateStatus(
            sessionID: "sess-codex-goal-thread",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Implement the saved goal"),
            at: startedAt.addingTimeInterval(1)
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-goal-thread",
            fingerprint: goalFingerprint,
            threadID: "thread-goal"
        )

        let ignoredPreviousThread = store.handleCodexNotifyCompletion(
            sessionID: "sess-codex-goal-thread",
            completion: CodexNotifyCompletion(
                notificationType: "agent-turn-complete",
                threadID: "thread-first",
                turnID: "turn-first",
                lastInputMessageFingerprint: firstFingerprint,
                inputMessageCount: 1,
                detail: "Earlier thread finished"
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(ignoredPreviousThread == false)
        #expect(store.sessionRegistry.activeSession(sessionID: "sess-codex-goal-thread")?.status?.kind == .working)

        let acceptedGoalThread = store.handleCodexNotifyCompletion(
            sessionID: "sess-codex-goal-thread",
            completion: CodexNotifyCompletion(
                notificationType: "agent-turn-complete",
                threadID: "thread-goal",
                turnID: "turn-goal",
                lastInputMessageFingerprint: nil,
                inputMessageCount: 0,
                detail: "Goal finished"
            ),
            at: startedAt.addingTimeInterval(3)
        )

        #expect(acceptedGoalThread)
        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-goal-thread")?.status
        #expect(status?.kind == .ready)
        #expect(status?.detail == "Goal finished")
    }

    @Test
    func codexNotifyCompletionIgnoresThreadedInputWhenRootInputWasNotRecorded() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-missing-root-input",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.updateStatus(
            sessionID: "sess-codex-missing-root-input",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Root still running"),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexNotifyCompletion(
            sessionID: "sess-codex-missing-root-input",
            completion: CodexNotifyCompletion(
                notificationType: "agent-turn-complete",
                threadID: "thread-unknown",
                turnID: "turn-unknown",
                lastInputMessageFingerprint: CodexInputFingerprint.fingerprint(for: "Maybe a child task"),
                inputMessageCount: 1,
                detail: "Thread finished"
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted == false)
        #expect(store.sessionRegistry.activeSession(sessionID: "sess-codex-missing-root-input")?.status?.kind == .working)
    }

    @Test
    func codexNotifyCompletionIgnoresThreadedCompletionWithoutInputMetadata() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-threaded-no-input",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.updateStatus(
            sessionID: "sess-codex-threaded-no-input",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Root still running"),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexNotifyCompletion(
            sessionID: "sess-codex-threaded-no-input",
            completion: CodexNotifyCompletion(
                notificationType: "agent-turn-complete",
                threadID: "thread-unknown",
                turnID: "turn-unknown",
                lastInputMessageFingerprint: nil,
                inputMessageCount: 0,
                detail: "Thread finished"
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted == false)
        #expect(store.sessionRegistry.activeSession(sessionID: "sess-codex-threaded-no-input")?.status?.kind == .working)
    }

    @Test
    func codexNotifyCompletionAcceptsUnthreadedLegacyCompletionWithoutInputMetadata() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-legacy-notify",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )

        let accepted = store.handleCodexNotifyCompletion(
            sessionID: "sess-codex-legacy-notify",
            completion: CodexNotifyCompletion(
                notificationType: "task_complete",
                threadID: nil,
                turnID: nil,
                lastInputMessageFingerprint: nil,
                inputMessageCount: 0,
                detail: "Legacy finished"
            ),
            at: startedAt.addingTimeInterval(1)
        )

        #expect(accepted)
        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-legacy-notify")?.status
        #expect(status?.kind == .ready)
        #expect(status?.detail == "Legacy finished")
    }

    @Test
    func codexNotifyCompletionIgnoresFallbackEventWhenSessionUsesHooks() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-hooks-ignore-notify",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.updateStatus(
            sessionID: "sess-codex-hooks-ignore-notify",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Root still running"),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexNotifyCompletion(
            sessionID: "sess-codex-hooks-ignore-notify",
            completion: CodexNotifyCompletion(
                notificationType: "agent-turn-complete",
                threadID: nil,
                turnID: nil,
                lastInputMessageFingerprint: nil,
                inputMessageCount: 0,
                detail: "Notify finished"
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted == false)
        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-hooks-ignore-notify")?.status
        #expect(status?.kind == .working)
        #expect(status?.detail == "Root still running")
    }

    @Test
    func codexSessionLogCompletionIgnoresMismatchedTurnBeforeRootCompletes() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-session-log-turn",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.updateStatus(
            sessionID: "sess-codex-session-log-turn",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Root still running"),
            at: startedAt.addingTimeInterval(1)
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-session-log-turn",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Root still running"),
            threadID: "thread-root",
            turnID: "turn-root"
        )

        let ignoredChild = store.handleCodexSessionLogCompletion(
            sessionID: "sess-codex-session-log-turn",
            detail: "Child finished",
            threadID: "thread-root",
            turnID: "turn-child",
            at: startedAt.addingTimeInterval(2)
        )

        #expect(ignoredChild == false)
        #expect(store.sessionRegistry.activeSession(sessionID: "sess-codex-session-log-turn")?.status?.kind == .working)

        let acceptedRoot = store.handleCodexSessionLogCompletion(
            sessionID: "sess-codex-session-log-turn",
            detail: "Root finished",
            threadID: "thread-root",
            turnID: "turn-root",
            at: startedAt.addingTimeInterval(3)
        )

        #expect(acceptedRoot)
        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-session-log-turn")?.status
        #expect(status?.kind == .ready)
        #expect(status?.detail == "Root finished")
    }

    @Test
    func codexSessionLogCompletionIgnoresMismatchedThreadBeforeRootCompletes() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-session-log-thread",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.updateStatus(
            sessionID: "sess-codex-session-log-thread",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Root still running"),
            at: startedAt.addingTimeInterval(1)
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-session-log-thread",
            fingerprint: nil,
            threadID: "thread-root"
        )

        let ignoredChild = store.handleCodexSessionLogCompletion(
            sessionID: "sess-codex-session-log-thread",
            detail: "Child finished",
            threadID: "thread-child",
            turnID: nil,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(ignoredChild == false)
        #expect(store.sessionRegistry.activeSession(sessionID: "sess-codex-session-log-thread")?.status?.kind == .working)
    }

    @Test
    func codexSessionLogCompletionIgnoresIdentifiedTurnWhenRootTurnIsUnknown() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-session-log-missing-root-turn",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .sessionLogFallback(reason: "test"),
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.updateStatus(
            sessionID: "sess-codex-session-log-missing-root-turn",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Root still running"),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexSessionLogCompletion(
            sessionID: "sess-codex-session-log-missing-root-turn",
            detail: "Child finished",
            threadID: nil,
            turnID: "turn-child",
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted == false)
        #expect(
            store.sessionRegistry.activeSession(
                sessionID: "sess-codex-session-log-missing-root-turn"
            )?.status?.kind == .working
        )
    }

    @Test
    func codexSessionLogCompletionIgnoresFallbackEventWhenSessionUsesHooks() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-hooks-ignore-log",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )

        let accepted = store.handleCodexSessionLogCompletion(
            sessionID: "sess-codex-hooks-ignore-log",
            detail: "Session log finished",
            threadID: nil,
            turnID: nil,
            at: startedAt.addingTimeInterval(1)
        )

        #expect(accepted == false)
        #expect(store.sessionRegistry.activeSession(sessionID: "sess-codex-hooks-ignore-log")?.status?.kind == nil)
    }

    @Test
    func codexHookEventIgnoresHookWhenSessionUsesSessionLogFallback() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-fallback-ignore-hook",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .sessionLogFallback(reason: "hooks_needsUpdate"),
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.updateStatus(
            sessionID: "sess-codex-fallback-ignore-hook",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Root still running"),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-fallback-ignore-hook",
            event: CodexHookEvent(
                hookEventName: "Stop",
                threadID: nil,
                turnID: nil,
                promptFingerprint: nil,
                status: SessionStatus(kind: .ready, summary: "Ready", detail: "Hook finished"),
                nativeSessionID: nil,
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted == false)
        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-fallback-ignore-hook")?.status
        #expect(status?.kind == .working)
        #expect(status?.detail == "Root still running")
    }

    @Test
    func codexRootTurnInputKeepsTurnWhenThreadIsLatchedAfterTurn() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-thread-after-turn",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .sessionLogFallback(reason: "test"),
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-thread-after-turn",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Fix sidebar"),
            turnID: "turn-root"
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-thread-after-turn",
            fingerprint: nil,
            threadID: "thread-root"
        )

        let accepted = store.handleCodexSessionLogCompletion(
            sessionID: "sess-codex-thread-after-turn",
            detail: "Root finished",
            threadID: "thread-root",
            turnID: "turn-root",
            at: startedAt.addingTimeInterval(1)
        )

        #expect(accepted)
        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-thread-after-turn")?.status
        #expect(status?.kind == .ready)
        #expect(status?.detail == "Root finished")
    }

    @Test
    func codexSessionLogApprovalSuppressesNeverPolicyWithExplicitNullReviewer() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-session-log-never-approval",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .sessionLogFallback(reason: "test"),
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.updateStatus(
            sessionID: "sess-codex-session-log-never-approval",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Running"),
            at: startedAt.addingTimeInterval(1)
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-session-log-never-approval",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
            threadID: "thread-root",
            turnID: "turn-root",
            approvalPolicyField: .string("never"),
            approvalsReviewerField: .null
        )

        let accepted = store.handleCodexSessionLogApproval(
            sessionID: "sess-codex-session-log-never-approval",
            detail: "Needs approval",
            threadID: "thread-root",
            turnID: "turn-root",
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted == false)
        let status = store.sessionRegistry.activeSession(
            sessionID: "sess-codex-session-log-never-approval"
        )?.status
        #expect(status?.kind == .working)
        #expect(status?.detail == "Running")
    }

    @Test
    func codexHookEventUpdatesStatusAndLatchesRootThread() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-hook",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-1",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Set up hooks"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Set up hooks"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )

        #expect(accepted)
        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-hook")?.status
        #expect(status?.kind == .working)
        #expect(status?.detail == "Set up hooks")
    }

    @Test
    func codexHookPermissionRequestIsSuppressedForMatchingAutoReviewTurn() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let store = SessionRuntimeStore()
        store.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-auto-review",
            agent: .codex,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-auto-review",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
            turnID: "turn-root",
            approvalPolicy: "never",
            approvalsReviewer: "reviewer"
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-auto-review",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Run checks"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-auto-review",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted == false)
        #expect(store.sessionRegistry.activeSession(sessionID: "sess-codex-auto-review")?.status?.kind == .working)
        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs.isEmpty)
    }

    @Test
    func codexHookPermissionRequestReplayFromAutoReviewedPriorTurnIsIgnored() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let store = SessionRuntimeStore()
        store.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let oldFingerprint = CodexInputFingerprint.fingerprint(for: "Run checks")
        let newFingerprint = CodexInputFingerprint.fingerprint(for: "Continue")

        store.startSession(
            sessionID: "sess-codex-replayed-auto-review",
            agent: .codex,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.recordCodexPendingTurnContext(
            sessionID: "sess-codex-replayed-auto-review",
            approvalPolicy: "on-request",
            approvalsReviewer: "guardian_subagent"
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-replayed-auto-review",
            fingerprint: oldFingerprint,
            turnID: "turn-old",
            approvalPolicy: "on-request"
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-replayed-auto-review",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-old",
                promptFingerprint: oldFingerprint,
                status: SessionStatus(kind: .working, summary: "Working", detail: "Run checks"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )

        let initialApprovalAccepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-replayed-auto-review",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-old",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-replayed-auto-review",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-new",
                promptFingerprint: newFingerprint,
                status: SessionStatus(kind: .working, summary: "Working", detail: "Continue"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(3)
        )

        let replayAccepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-replayed-auto-review",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-old",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(4)
        )

        #expect(initialApprovalAccepted == false)
        #expect(replayAccepted == false)
        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-replayed-auto-review")?.status
        #expect(status?.kind == .working)
        #expect(status?.detail == "Continue")
        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs.isEmpty)
    }

    @Test
    func codexHookPermissionRequestFromPriorManualTurnIsIgnoredAfterRootAdvances() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-prior-manual-turn",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-prior-manual-turn",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
            turnID: "turn-old",
            approvalPolicyField: .string("on-request"),
            approvalsReviewerField: .null
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-prior-manual-turn",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-old",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Run checks"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-prior-manual-turn",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-new",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Continue"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Continue"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-prior-manual-turn",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-old",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(3)
        )

        #expect(accepted == false)
        #expect(
            store.sessionRegistry.activeSession(sessionID: "sess-codex-prior-manual-turn")?.status?.kind ==
                .working
        )
    }

    @Test
    func codexHookPermissionRequestForCurrentTurnWinsOverPreviouslyAutoReviewedTurnID() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-reused-auto-reviewed-turn",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.recordCodexPendingTurnContext(
            sessionID: "sess-codex-reused-auto-reviewed-turn",
            approvalPolicy: "on-request",
            approvalsReviewer: "guardian_subagent"
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-reused-auto-reviewed-turn",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
            turnID: "turn-reused",
            approvalPolicy: "on-request"
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-reused-auto-reviewed-turn",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-reused",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Run checks"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )
        let firstSuppressed = store.handleCodexHookEvent(
            sessionID: "sess-codex-reused-auto-reviewed-turn",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-reused",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        store.recordCodexPendingTurnContext(
            sessionID: "sess-codex-reused-auto-reviewed-turn",
            approvalPolicy: "on-request",
            approvalsReviewer: nil
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-reused-auto-reviewed-turn",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Other turn"),
            turnID: "turn-other",
            approvalPolicy: "on-request"
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-reused-auto-reviewed-turn",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Manual turn"),
            turnID: "turn-reused",
            approvalPolicy: "on-request"
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-reused-auto-reviewed-turn",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-reused",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Manual turn"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Manual turn"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(3)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-reused-auto-reviewed-turn",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-reused",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(4)
        )

        #expect(firstSuppressed == false)
        #expect(accepted)
        #expect(
            store.sessionRegistry.activeSession(sessionID: "sess-codex-reused-auto-reviewed-turn")?.status?.kind ==
                .needsApproval
        )
    }

    @Test
    func codexHookPermissionRequestSurfacesWhenReviewerIsExplicitlyNull() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-no-auto-review",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-no-auto-review",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
            turnID: "turn-root",
            approvalPolicyField: .string("on-request"),
            approvalsReviewerField: .null
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-no-auto-review",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Run checks"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-no-auto-review",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted)
        #expect(store.sessionRegistry.activeSession(sessionID: "sess-codex-no-auto-review")?.status?.kind == .needsApproval)
    }

    @Test
    func codexHookPermissionRequestWithOmittedReviewerIsAmbiguousAndStaysWorking() async {
        let store = SessionRuntimeStore(codexHookApprovalDeferralNanoseconds: 20_000_000)
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-unknown-reviewer",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-unknown-reviewer",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
            turnID: "turn-root",
            approvalPolicyField: .string("on-request"),
            approvalsReviewerField: .unspecified
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-unknown-reviewer",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Run checks"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-unknown-reviewer",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted == false)
        #expect(store.sessionRegistry.activeSession(sessionID: "sess-codex-unknown-reviewer")?.status?.kind == .working)

        try? await Task.sleep(nanoseconds: 80_000_000)

        #expect(store.sessionRegistry.activeSession(sessionID: "sess-codex-unknown-reviewer")?.status?.kind == .working)
    }

    @Test
    func codexHookPermissionRequestWithOmittedReviewerSurfacesAfterExplicitNullContextArrives() {
        let store = SessionRuntimeStore(codexHookApprovalDeferralNanoseconds: 1_000_000_000)
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-unknown-reviewer-later-null",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-unknown-reviewer-later-null",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
            turnID: "turn-root",
            approvalPolicyField: .string("on-request"),
            approvalsReviewerField: .unspecified
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-unknown-reviewer-later-null",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Run checks"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )
        let deferred = store.handleCodexHookEvent(
            sessionID: "sess-codex-unknown-reviewer-later-null",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(deferred == false)
        #expect(
            store.sessionRegistry.activeSession(
                sessionID: "sess-codex-unknown-reviewer-later-null"
            )?.status?.kind == .working
        )

        store.recordCodexOverrideTurnContext(
            sessionID: "sess-codex-unknown-reviewer-later-null",
            approvalPolicy: .unspecified,
            approvalsReviewer: .null
        )

        #expect(
            store.sessionRegistry.activeSession(
                sessionID: "sess-codex-unknown-reviewer-later-null"
            )?.status?.kind == .needsApproval
        )
    }

    @Test
    func codexHookPermissionRequestIsSuppressedWhenReviewerIsPresentForOnRequestPolicy() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-reviewer-non-auto-policy",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-reviewer-non-auto-policy",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
            turnID: "turn-root",
            approvalPolicy: "on-request",
            approvalsReviewer: "reviewer"
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-reviewer-non-auto-policy",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Run checks"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-reviewer-non-auto-policy",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted == false)
        #expect(
            store.sessionRegistry.activeSession(sessionID: "sess-codex-reviewer-non-auto-policy")?.status?.kind ==
                .working
        )
    }

    @Test
    func codexHookPermissionRequestUsesPendingOverrideContextForTurnlessUserTurn() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let promptFingerprint = CodexInputFingerprint.fingerprint(for: "continue")

        store.startSession(
            sessionID: "sess-codex-override-context",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.recordCodexPendingTurnContext(
            sessionID: "sess-codex-override-context",
            approvalPolicy: "on-request",
            approvalsReviewer: "guardian_subagent"
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-override-context",
            fingerprint: promptFingerprint,
            approvalPolicy: "on-request"
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-override-context",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: promptFingerprint,
                status: SessionStatus(kind: .working, summary: "Working", detail: "continue"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-override-context",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted == false)
        #expect(store.sessionRegistry.activeSession(sessionID: "sess-codex-override-context")?.status?.kind == .working)
    }

    @Test
    func codexHookPermissionRequestUsesPendingOverrideContextWhenHookArrivesBeforeTurnlessUserTurn() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let promptFingerprint = CodexInputFingerprint.fingerprint(for: "continue")

        store.startSession(
            sessionID: "sess-codex-hook-first-override-context",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.recordCodexPendingTurnContext(
            sessionID: "sess-codex-hook-first-override-context",
            approvalPolicy: "on-request",
            approvalsReviewer: "guardian_subagent"
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-first-override-context",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: promptFingerprint,
                status: SessionStatus(kind: .working, summary: "Working", detail: "continue"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )
        let deferred = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-first-override-context",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(deferred == false)
        #expect(
            store.sessionRegistry.activeSession(sessionID: "sess-codex-hook-first-override-context")?.status?.kind ==
                .working
        )

        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-hook-first-override-context",
            fingerprint: promptFingerprint,
            approvalPolicy: "on-request"
        )

        let suppressed = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-first-override-context",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(3)
        )

        #expect(suppressed == false)
        #expect(
            store.sessionRegistry.activeSession(sessionID: "sess-codex-hook-first-override-context")?.status?.kind ==
                .working
        )
    }

    @Test
    func codexHookPermissionRequestReusesOverrideContextAcrossRepeatedPrompts() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let promptFingerprint = CodexInputFingerprint.fingerprint(for: "continue")

        store.startSession(
            sessionID: "sess-codex-repeated-prompt",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.recordCodexPendingTurnContext(
            sessionID: "sess-codex-repeated-prompt",
            approvalPolicy: "on-request",
            approvalsReviewer: "guardian_subagent"
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-repeated-prompt",
            fingerprint: promptFingerprint,
            approvalPolicy: "on-request"
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-repeated-prompt",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-one",
                promptFingerprint: promptFingerprint,
                status: SessionStatus(kind: .working, summary: "Working", detail: "continue"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-repeated-prompt",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-one",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-repeated-prompt",
            fingerprint: promptFingerprint,
            approvalPolicy: "on-request"
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-repeated-prompt",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-two",
                promptFingerprint: promptFingerprint,
                status: SessionStatus(kind: .working, summary: "Working", detail: "continue again"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(3)
        )

        let suppressed = store.handleCodexHookEvent(
            sessionID: "sess-codex-repeated-prompt",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-two",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(4)
        )

        #expect(suppressed == false)
        #expect(store.sessionRegistry.activeSession(sessionID: "sess-codex-repeated-prompt")?.status?.kind == .working)
    }

    @Test
    func codexHookPermissionRequestDoesNotCarryOverrideContextAcrossClearSessionStart() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let firstPromptFingerprint = CodexInputFingerprint.fingerprint(for: "continue")
        let secondPromptFingerprint = CodexInputFingerprint.fingerprint(for: "manual")

        store.startSession(
            sessionID: "sess-codex-clear-session-start",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.recordCodexPendingTurnContext(
            sessionID: "sess-codex-clear-session-start",
            approvalPolicy: "on-request",
            approvalsReviewer: "guardian_subagent"
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-clear-session-start",
            fingerprint: firstPromptFingerprint,
            approvalPolicy: "on-request"
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-clear-session-start",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-one",
                turnID: "turn-one",
                promptFingerprint: firstPromptFingerprint,
                status: SessionStatus(kind: .working, summary: "Working", detail: "continue"),
                nativeSessionID: "thread-one",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )
        let firstSuppressed = store.handleCodexHookEvent(
            sessionID: "sess-codex-clear-session-start",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-one",
                turnID: "turn-one",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-one",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )
        #expect(firstSuppressed == false)

        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-clear-session-start",
            event: CodexHookEvent(
                hookEventName: "SessionStart",
                source: "clear",
                threadID: "thread-two",
                turnID: nil,
                promptFingerprint: nil,
                status: nil,
                nativeSessionID: "thread-two",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(3)
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-clear-session-start",
            fingerprint: secondPromptFingerprint,
            approvalPolicyField: .string("on-request"),
            approvalsReviewerField: .null
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-clear-session-start",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-two",
                turnID: "turn-two",
                promptFingerprint: secondPromptFingerprint,
                status: SessionStatus(kind: .working, summary: "Working", detail: "manual"),
                nativeSessionID: "thread-two",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(4)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-clear-session-start",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-two",
                turnID: "turn-two",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-two",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(5)
        )

        #expect(accepted)
        #expect(
            store.sessionRegistry.activeSession(sessionID: "sess-codex-clear-session-start")?.status?.kind ==
                .needsApproval
        )
    }

    @Test
    func codexHookPermissionRequestDoesNotPublishWhenPromptContextClearsReviewerWithoutPolicy() {
        let store = SessionRuntimeStore(codexHookApprovalDeferralNanoseconds: 1_000_000_000)
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let promptFingerprint = CodexInputFingerprint.fingerprint(for: "manual command")

        store.startSession(
            sessionID: "sess-codex-waits-for-current-prompt-context",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.recordCodexPendingTurnContext(
            sessionID: "sess-codex-waits-for-current-prompt-context",
            approvalPolicy: "on-request",
            approvalsReviewer: "guardian_subagent"
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-waits-for-current-prompt-context",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: promptFingerprint,
                status: SessionStatus(kind: .working, summary: "Working", detail: "manual command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )

        let deferred = store.handleCodexHookEvent(
            sessionID: "sess-codex-waits-for-current-prompt-context",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(deferred == false)
        #expect(
            store.sessionRegistry.activeSession(
                sessionID: "sess-codex-waits-for-current-prompt-context"
            )?.status?.kind == .working
        )

        store.recordCodexPendingTurnContext(
            sessionID: "sess-codex-waits-for-current-prompt-context",
            approvalPolicy: nil,
            approvalsReviewer: nil
        )

        #expect(
            store.sessionRegistry.activeSession(
                sessionID: "sess-codex-waits-for-current-prompt-context"
            )?.status?.kind == .working
        )
    }

    @Test
    func codexHookPermissionRequestUsesOverrideContextThatArrivesAfterUserTurnContext() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let promptFingerprint = CodexInputFingerprint.fingerprint(for: "continue")

        store.startSession(
            sessionID: "sess-codex-late-override-context",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-late-override-context",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: promptFingerprint,
                status: SessionStatus(kind: .working, summary: "Working", detail: "continue"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-late-override-context",
            fingerprint: promptFingerprint,
            approvalPolicy: "on-request"
        )
        store.recordCodexOverrideTurnContext(
            sessionID: "sess-codex-late-override-context",
            approvalPolicy: .unspecified,
            approvalsReviewer: .string("guardian_subagent")
        )

        let suppressed = store.handleCodexHookEvent(
            sessionID: "sess-codex-late-override-context",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(suppressed == false)
        #expect(
            store.sessionRegistry.activeSession(sessionID: "sess-codex-late-override-context")?.status?.kind ==
                .working
        )
    }

    @Test
    func codexHookPermissionRequestDoesNotUseOverrideContextAfterNullClear() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let promptFingerprint = CodexInputFingerprint.fingerprint(for: "continue")

        store.startSession(
            sessionID: "sess-codex-override-context-clear",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.recordCodexPendingTurnContext(
            sessionID: "sess-codex-override-context-clear",
            approvalPolicy: "on-request",
            approvalsReviewer: "guardian_subagent"
        )
        store.recordCodexPendingTurnContext(
            sessionID: "sess-codex-override-context-clear",
            approvalPolicy: nil,
            approvalsReviewer: nil
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-override-context-clear",
            fingerprint: promptFingerprint,
            approvalPolicy: "on-request"
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-override-context-clear",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: promptFingerprint,
                status: SessionStatus(kind: .working, summary: "Working", detail: "continue"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-override-context-clear",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted)
        #expect(
            store.sessionRegistry.activeSession(sessionID: "sess-codex-override-context-clear")?.status?.kind ==
                .needsApproval
        )
    }

    @Test
    func codexHookPermissionRequestSuppressesNullClearWithoutApprovalPolicy() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let promptFingerprint = CodexInputFingerprint.fingerprint(for: "continue")

        store.startSession(
            sessionID: "sess-codex-null-clear-without-fields",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.recordCodexPendingTurnContext(
            sessionID: "sess-codex-null-clear-without-fields",
            approvalPolicy: "on-request",
            approvalsReviewer: "guardian_subagent"
        )
        store.recordCodexPendingTurnContext(
            sessionID: "sess-codex-null-clear-without-fields",
            approvalPolicy: nil,
            approvalsReviewer: nil
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-null-clear-without-fields",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: promptFingerprint,
                status: SessionStatus(kind: .working, summary: "Working", detail: "continue"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-null-clear-without-fields",
            fingerprint: promptFingerprint
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-null-clear-without-fields",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted == false)
        #expect(
            store.sessionRegistry.activeSession(sessionID: "sess-codex-null-clear-without-fields")?.status?.kind ==
                .working
        )
    }

    @Test
    func codexHookPermissionRequestDoesNotUseStaleTurnForUnidentifiedAutoReviewContext() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-stale-auto-review-context",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-stale-auto-review-context",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
            turnID: "turn-root"
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-stale-auto-review-context",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Run checks"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-stale-auto-review-context",
            fingerprint: nil,
            approvalPolicy: "never",
            approvalsReviewer: "reviewer"
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-stale-auto-review-context",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted == false)
        #expect(
            store.sessionRegistry.activeSession(sessionID: "sess-codex-stale-auto-review-context")?.status?.kind ==
                .working
        )
    }

    @Test
    func codexHookPermissionRequestIsSuppressedWhenAutoReviewTurnMismatches() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-auto-review-known-turn-mismatch",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-auto-review-known-turn-mismatch",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
            turnID: "turn-root",
            approvalPolicy: "never",
            approvalsReviewer: "reviewer"
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-auto-review-known-turn-mismatch",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Run checks"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-auto-review-known-turn-mismatch",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                threadID: "thread-root",
                turnID: "turn-child",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted == false)
        #expect(
            store.sessionRegistry.activeSession(
                sessionID: "sess-codex-auto-review-known-turn-mismatch"
            )?.status?.kind == .working
        )
    }

    @Test
    func codexHookPermissionRequestIsSuppressedForAwaitingRootWhenActiveAutoReviewTurnMismatches() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let promptFingerprint = CodexInputFingerprint.fingerprint(for: "go ahead")

        store.startSession(
            sessionID: "sess-codex-auto-review-awaiting-turn-mismatch",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.recordCodexPendingTurnContext(
            sessionID: "sess-codex-auto-review-awaiting-turn-mismatch",
            approvalPolicy: "on-request",
            approvalsReviewer: "guardian_subagent"
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-auto-review-awaiting-turn-mismatch",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: promptFingerprint,
                status: SessionStatus(kind: .working, summary: "Working", detail: "go ahead"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-auto-review-awaiting-turn-mismatch",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                threadID: "thread-root",
                turnID: "turn-tool",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted == false)
        #expect(
            store.sessionRegistry.activeSession(
                sessionID: "sess-codex-auto-review-awaiting-turn-mismatch"
            )?.status?.kind == .working
        )
    }

    @Test
    func codexHookPermissionRequestFromDifferentThreadIsIgnoredByRootThreadFilter() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-auto-review-thread-mismatch",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-auto-review-thread-mismatch",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
            turnID: "turn-root",
            approvalPolicy: "never",
            approvalsReviewer: "reviewer"
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-auto-review-thread-mismatch",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Run checks"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-auto-review-thread-mismatch",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                threadID: "thread-child",
                turnID: "turn-root",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-child",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted == false)
        #expect(
            store.sessionRegistry.activeSession(sessionID: "sess-codex-auto-review-thread-mismatch")?.status?.kind ==
                .working
        )
    }

    @Test
    func codexHookPermissionRequestIsSuppressedWhenHookTurnIsMissing() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-auto-review-missing-hook-turn",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-auto-review-missing-hook-turn",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
            turnID: "turn-root",
            approvalPolicy: "never",
            approvalsReviewer: "reviewer"
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-auto-review-missing-hook-turn",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Run checks"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-auto-review-missing-hook-turn",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                threadID: "thread-root",
                turnID: nil,
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted == false)
        #expect(
            store.sessionRegistry.activeSession(sessionID: "sess-codex-auto-review-missing-hook-turn")?.status?.kind ==
                .working
        )
    }

    @Test
    func codexHookPermissionRequestDefersUntilAutoReviewContextArrives() async {
        let store = SessionRuntimeStore(codexHookApprovalDeferralNanoseconds: 1_000_000_000)
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-deferred-auto-review",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-deferred-auto-review",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Run checks"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-deferred-auto-review",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted == false)
        #expect(store.sessionRegistry.activeSession(sessionID: "sess-codex-deferred-auto-review")?.status?.kind == .working)

        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-deferred-auto-review",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
            turnID: "turn-root",
            approvalPolicy: "never",
            approvalsReviewer: "reviewer"
        )
        await settleNotificationTasks()

        #expect(store.sessionRegistry.activeSession(sessionID: "sess-codex-deferred-auto-review")?.status?.kind == .working)
    }

    @Test
    func codexHookPermissionRequestStaysWorkingWhenContextDoesNotArrive() async {
        let store = SessionRuntimeStore(codexHookApprovalDeferralNanoseconds: 20_000_000)
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-deferred-timeout",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-deferred-timeout",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Run checks"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-deferred-timeout",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        await waitUntil {
            store.sessionRegistry.activeSession(sessionID: "sess-codex-deferred-timeout")?.status?.kind ==
                .working
        }

        #expect(store.sessionRegistry.activeSession(sessionID: "sess-codex-deferred-timeout")?.status?.kind == .working)
    }

    @Test
    func codexHookPermissionRequestDoesNotBecomeStaleNeedsApprovalAfterWorkContinues() async {
        let store = SessionRuntimeStore(codexHookApprovalDeferralNanoseconds: 20_000_000)
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-deferred-superseded",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-deferred-superseded",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Run checks"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-deferred-superseded",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-deferred-superseded",
            event: CodexHookEvent(
                hookEventName: "PreToolUse",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: nil,
                status: SessionStatus(kind: .working, summary: "Working", detail: "Running command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(3)
        )
        try? await Task.sleep(nanoseconds: 80_000_000)

        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-deferred-superseded")?.status
        #expect(status?.kind == .working)
        #expect(status?.detail == "Running command")
    }

    @Test
    func codexHookPermissionRequestDoesNotBecomeStaleNeedsApprovalAfterRootTurnAdvances() async {
        let store = SessionRuntimeStore(codexHookApprovalDeferralNanoseconds: 20_000_000)
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-deferred-context-superseded",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-deferred-context-superseded",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-old",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Run checks"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-deferred-context-superseded",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-old",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-deferred-context-superseded",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Next task"),
            turnID: "turn-new",
            approvalPolicy: "never",
            approvalsReviewer: "reviewer"
        )
        try? await Task.sleep(nanoseconds: 80_000_000)

        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-deferred-context-superseded")?.status
        #expect(status?.kind == .working)
        #expect(status?.detail == "Run checks")
    }

    @Test
    func codexHookPermissionRequestIsSupersededByNewTurnHook() async {
        let store = SessionRuntimeStore(codexHookApprovalDeferralNanoseconds: 20_000_000)
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-deferred-new-turn-superseded",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-deferred-new-turn-superseded",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-old",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Run checks"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-deferred-new-turn-superseded",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-old",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-deferred-new-turn-superseded",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-new",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Next task"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Next task"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(3)
        )
        try? await Task.sleep(nanoseconds: 80_000_000)

        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-deferred-new-turn-superseded")?.status
        #expect(status?.kind == .working)
        #expect(status?.detail == "Next task")
    }

    @Test
    func codexHookEventIgnoresDifferentThreadAfterRootThreadIsLatched() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-hook-latched",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-latched",
            event: CodexHookEvent(
                hookEventName: "SessionStart",
                threadID: "thread-root",
                turnID: nil,
                promptFingerprint: nil,
                status: nil,
                nativeSessionID: "thread-root",
                sessionFilePath: "/tmp/session.jsonl",
                cwd: "/repo"
            ),
            at: startedAt.addingTimeInterval(1)
        )
        store.updateStatus(
            sessionID: "sess-codex-hook-latched",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Root still running"),
            at: startedAt.addingTimeInterval(2)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-latched",
            event: CodexHookEvent(
                hookEventName: "Stop",
                threadID: "thread-child",
                turnID: "turn-child",
                promptFingerprint: nil,
                status: SessionStatus(kind: .ready, summary: "Ready", detail: "Child finished"),
                nativeSessionID: "thread-child",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(3)
        )

        #expect(accepted == false)
        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-hook-latched")?.status
        #expect(status?.kind == .working)
        #expect(status?.detail == "Root still running")
    }

    @Test
    func codexHookStopDoesNotLatchThreadBeforeRootIdentityIsKnown() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-hook-missing-root",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.updateStatus(
            sessionID: "sess-codex-hook-missing-root",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Root still running"),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-missing-root",
            event: CodexHookEvent(
                hookEventName: "Stop",
                threadID: "thread-child",
                turnID: "turn-child",
                promptFingerprint: nil,
                status: SessionStatus(kind: .ready, summary: "Ready", detail: "Child finished"),
                nativeSessionID: "thread-child",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted == false)
        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-hook-missing-root")?.status
        #expect(status?.kind == .working)
        #expect(status?.detail == "Root still running")
    }

    @Test
    func codexHookStopCompletesWhenRootThreadMatches() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-hook-root-stop",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-root-stop",
            event: CodexHookEvent(
                hookEventName: "SessionStart",
                threadID: "thread-root",
                turnID: nil,
                promptFingerprint: nil,
                status: nil,
                nativeSessionID: "thread-root",
                sessionFilePath: "/tmp/session.jsonl",
                cwd: "/repo"
            ),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-root-stop",
            event: CodexHookEvent(
                hookEventName: "Stop",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: nil,
                status: SessionStatus(kind: .ready, summary: "Ready", detail: "Root finished"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted)
        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-hook-root-stop")?.status
        #expect(status?.kind == .ready)
        #expect(status?.detail == "Root finished")
    }

    @Test
    func codexHookStopCompletesWhenRootThreadMatchesEvenWithDifferentTurn() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-hook-root-stop-different-turn",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-root-stop-different-turn",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root-previous",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Fix the sidebar state"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Fix the sidebar state"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-root-stop-different-turn",
            event: CodexHookEvent(
                hookEventName: "Stop",
                threadID: "thread-root",
                turnID: "turn-root-next",
                promptFingerprint: nil,
                status: SessionStatus(kind: .ready, summary: "Ready", detail: "Root finished"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted)
        let status = store.sessionRegistry.activeSession(
            sessionID: "sess-codex-hook-root-stop-different-turn"
        )?.status
        #expect(status?.kind == .ready)
        #expect(status?.detail == "Root finished")
    }

    @Test
    func codexHookStopCanMatchRootTurnWhenThreadIsMissing() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-hook-turn-match",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-turn-match",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Fix the sidebar state"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Fix the sidebar state"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-turn-match",
            event: CodexHookEvent(
                hookEventName: "Stop",
                threadID: nil,
                turnID: "turn-root",
                promptFingerprint: nil,
                status: SessionStatus(kind: .ready, summary: "Ready", detail: "Root finished"),
                nativeSessionID: nil,
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted)
        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-hook-turn-match")?.status
        #expect(status?.kind == .ready)
        #expect(status?.detail == "Root finished")
    }

    @Test
    func codexHookStopIgnoresDifferentTurnWhenThreadIsMissing() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-hook-turn-mismatch",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-turn-mismatch",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Fix the sidebar state"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Fix the sidebar state"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-turn-mismatch",
            event: CodexHookEvent(
                hookEventName: "Stop",
                threadID: nil,
                turnID: "turn-child",
                promptFingerprint: nil,
                status: SessionStatus(kind: .ready, summary: "Ready", detail: "Child finished"),
                nativeSessionID: nil,
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted == false)
        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-hook-turn-mismatch")?.status
        #expect(status?.kind == .working)
        #expect(status?.detail == "Fix the sidebar state")
    }

    @Test
    func codexHookUnidentifiedStopBeforeRootIdentityIsAcceptedForCompatibility() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-hook-legacy-stop",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.updateStatus(
            sessionID: "sess-codex-hook-legacy-stop",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Root still running"),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-legacy-stop",
            event: CodexHookEvent(
                hookEventName: "Stop",
                threadID: nil,
                turnID: nil,
                promptFingerprint: nil,
                status: SessionStatus(kind: .ready, summary: "Ready", detail: "Turn complete"),
                nativeSessionID: nil,
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted)
        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-hook-legacy-stop")?.status
        #expect(status?.kind == .ready)
        #expect(status?.detail == "Turn complete")
    }

    @Test
    func codexHookClearSessionStartReplacesLatchedRootThread() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-hook-clear",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-clear",
            event: CodexHookEvent(
                hookEventName: "SessionStart",
                threadID: "thread-root",
                turnID: nil,
                promptFingerprint: nil,
                status: nil,
                nativeSessionID: "thread-root",
                sessionFilePath: "/tmp/root.jsonl",
                cwd: "/repo"
            ),
            at: startedAt.addingTimeInterval(1)
        )

        let acceptedClear = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-clear",
            event: CodexHookEvent(
                hookEventName: "SessionStart",
                source: "clear",
                threadID: "thread-clear",
                turnID: nil,
                promptFingerprint: nil,
                status: nil,
                nativeSessionID: "thread-clear",
                sessionFilePath: "/tmp/clear.jsonl",
                cwd: "/repo"
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(acceptedClear)

        let acceptedNewThread = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-clear",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-clear",
                turnID: "turn-clear",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Continue after clear"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Continue after clear"),
                nativeSessionID: "thread-clear",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(3)
        )

        #expect(acceptedNewThread)
        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-hook-clear")?.status
        #expect(status?.kind == .working)
        #expect(status?.detail == "Continue after clear")
    }

    @Test
    func bindStopsActiveSessionWhenPanelCloses() throws {
        let appStore = AppStore(persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)

        let workspace = try #require(appStore.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelID)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-panel-close",
            agent: .codex,
            panelID: panelID,
            windowID: try #require(appStore.state.windows.first?.id),
            workspaceID: workspace.id,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )

        _ = appStore.send(.closePanel(panelID: panelID))

        #expect(sessionStore.sessionRegistry.activeSession(for: panelID) == nil)
    }

    @Test
    func bindKeepsActiveSessionWhenOwningPanelMovesToBackgroundTab() throws {
        let appStore = AppStore(persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)

        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let workspaceID = selection.workspaceID
        let originalTabID = try #require(selection.workspace.resolvedSelectedTabID)
        let originalPanelID = try #require(selection.workspace.focusedPanelID)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-background-tab",
            agent: .codex,
            panelID: originalPanelID,
            windowID: selection.windowID,
            workspaceID: workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-background-tab",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Editing"),
            at: startedAt.addingTimeInterval(1)
        )

        #expect(appStore.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil)))
        let backgroundedWorkspace = try #require(appStore.state.workspacesByID[workspaceID])
        let backgroundTabID = try #require(backgroundedWorkspace.resolvedSelectedTabID)
        #expect(backgroundTabID != originalTabID)

        #expect(sessionStore.sessionRegistry.activeSession(for: originalPanelID)?.sessionID == "sess-background-tab")
        #expect(sessionStore.workspaceStatuses(for: workspaceID).map(\.panelID).contains(originalPanelID))

        #expect(appStore.send(.selectWorkspaceTab(workspaceID: workspaceID, tabID: originalTabID)))
        #expect(sessionStore.panelStatus(for: originalPanelID)?.status.kind == .working)
    }

    @Test
    func updateStatusMarksUnfocusedPanelUnreadWhenSessionNeedsAttention() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-unfocused",
            agent: .codex,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-unfocused",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Finished"),
            at: startedAt.addingTimeInterval(1)
        )

        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs == [backgroundPanelID])
    }

    @Test
    func updateStatusSendsNotificationForManagedUnfocusedPanel() async throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let recorder = SessionNotificationRecorder()
        let sessionStore = SessionRuntimeStore(
            sendSessionStatusNotification: { title, body, workspaceID, panelID, context in
                await recorder.record(
                    title: title,
                    body: body,
                    workspaceID: workspaceID,
                    panelID: panelID,
                    context: context
                )
            }
        )
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-managed",
            agent: .codex,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-managed",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Finished"),
            at: startedAt.addingTimeInterval(1)
        )

        await waitUntilNotificationCount(recorder, expectedCount: 1)

        let notifications = await recorder.notifications()
        let notification = try #require(notifications.first)
        #expect(notification.title == "Codex is ready")
        #expect(notification.body == "Finished")
        #expect(notification.workspaceID == selection.workspaceID)
        #expect(notification.panelID == backgroundPanelID)
        #expect(notification.context.workspaceTitle == "Workspace 1")

        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs == [backgroundPanelID])
    }

    @Test
    func readyStatusWithOutstandingSubagentActivitySuppressesNotificationAndUnread() async throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let recorder = SessionNotificationRecorder()
        let sessionStore = SessionRuntimeStore(
            sendSessionStatusNotification: { title, body, workspaceID, panelID, context in
                await recorder.record(
                    title: title,
                    body: body,
                    workspaceID: workspaceID,
                    panelID: panelID,
                    context: context
                )
            },
            isApplicationActive: { false }
        )
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_010)

        sessionStore.startSession(
            sessionID: "sess-subagent-waiting",
            agent: .claude,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        #expect(sessionStore.updateBackgroundActivity(
            sessionID: "sess-subagent-waiting",
            activity: SessionBackgroundActivity(
                id: "subagent-1",
                kind: .subagent,
                displayName: "general-purpose",
                startedAt: startedAt.addingTimeInterval(1),
                lastUpdatedAt: startedAt.addingTimeInterval(1)
            ),
            at: startedAt.addingTimeInterval(1)
        ))
        sessionStore.updateStatus(
            sessionID: "sess-subagent-waiting",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Turn complete"),
            at: startedAt.addingTimeInterval(2)
        )

        await settleNotificationTasks()

        let notifications = await recorder.notifications()
        #expect(notifications.isEmpty)
        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs.isEmpty)
        #expect(sessionStore.sessionRegistry.sessionsByID["sess-subagent-waiting"]?.status?.kind == .ready)
        #expect(sessionStore.panelStatus(for: backgroundPanelID)?.status.kind == .working)
    }

    @Test
    func resumeGraceTimerRepublishesRawReadyAfterExpiry() async throws {
        let sessionStore = SessionRuntimeStore()
        defer { sessionStore.reset() }
        var publishCount = 0
        let cancellable = sessionStore.$sessionRegistry.sink { _ in
            publishCount += 1
        }
        defer { cancellable.cancel() }

        let workspaceID = UUID()
        let panelID = UUID()
        let finishAt = Date().addingTimeInterval(
            -(SessionRegistry.resumeProjectionGraceInterval - 0.4)
        )
        let startedAt = finishAt.addingTimeInterval(-3)

        sessionStore.startSession(
            sessionID: "sess-resume-timer",
            agent: .claude,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-resume-timer",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Root complete"),
            at: finishAt.addingTimeInterval(-2)
        )
        #expect(sessionStore.updateBackgroundActivity(
            sessionID: "sess-resume-timer",
            activity: SessionBackgroundActivity(
                id: "subagent-1",
                kind: .subagent,
                startedAt: finishAt.addingTimeInterval(-1),
                lastUpdatedAt: finishAt.addingTimeInterval(-1)
            ),
            at: finishAt.addingTimeInterval(-1)
        ))

        #expect(sessionStore.finishBackgroundActivity(
            sessionID: "sess-resume-timer",
            activityID: "subagent-1",
            at: finishAt
        ))
        let publishCountAfterFinish = publishCount

        #expect(sessionStore.panelStatus(for: panelID)?.projection == .resuming)
        await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            publishCount > publishCountAfterFinish &&
                sessionStore.panelStatus(for: panelID)?.projection == SessionStatusProjection.none
        }

        let status = try #require(sessionStore.panelStatus(for: panelID))
        #expect(status.status.kind == .ready)
        #expect(status.status.detail == "Root complete")
        #expect(status.projection == .none)
    }

    @Test
    func readyStatusDuringResumeGraceClearsProjectionAndSendsNotification() async throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let recorder = SessionNotificationRecorder()
        let sessionStore = SessionRuntimeStore(
            sendSessionStatusNotification: { title, body, workspaceID, panelID, context in
                await recorder.record(
                    title: title,
                    body: body,
                    workspaceID: workspaceID,
                    panelID: panelID,
                    context: context
                )
            },
            isApplicationActive: { false }
        )
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let finishAt = Date().addingTimeInterval(-0.1)
        let startedAt = finishAt.addingTimeInterval(-3)

        sessionStore.startSession(
            sessionID: "sess-ready-during-grace",
            agent: .claude,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        #expect(sessionStore.updateBackgroundActivity(
            sessionID: "sess-ready-during-grace",
            activity: SessionBackgroundActivity(
                id: "subagent-1",
                kind: .subagent,
                displayName: "general-purpose",
                startedAt: finishAt.addingTimeInterval(-2),
                lastUpdatedAt: finishAt.addingTimeInterval(-2)
            ),
            at: finishAt.addingTimeInterval(-2)
        ))
        sessionStore.updateStatus(
            sessionID: "sess-ready-during-grace",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Stale complete"),
            at: finishAt.addingTimeInterval(-1)
        )
        await settleNotificationTasks()
        let staleNotifications = await recorder.notifications()
        #expect(staleNotifications.isEmpty)

        #expect(sessionStore.finishBackgroundActivity(
            sessionID: "sess-ready-during-grace",
            activityID: "subagent-1",
            at: finishAt
        ))
        #expect(sessionStore.panelStatus(for: backgroundPanelID)?.projection == .resuming)

        sessionStore.updateStatus(
            sessionID: "sess-ready-during-grace",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Fresh complete"),
            at: Date()
        )

        await waitUntilNotificationCount(recorder, expectedCount: 1)

        let notification = try #require(await recorder.notifications().first)
        #expect(notification.title == "Claude Code is ready")
        #expect(notification.body == "Fresh complete")
        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs == [backgroundPanelID])
        #expect(sessionStore.panelStatus(for: backgroundPanelID)?.status.kind == .ready)
        #expect(sessionStore.panelStatus(for: backgroundPanelID)?.projection == SessionStatusProjection.none)
    }

    @Test
    func updateStatusDoesNotMarkFocusedPanelUnreadWhenSessionNeedsAttention() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore(isApplicationActive: { true })
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let focusedPanelID = try #require(selection.workspace.focusedPanelID)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-focused",
            agent: .claude,
            panelID: focusedPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-focused",
            status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Confirm"),
            at: startedAt.addingTimeInterval(1)
        )

        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs.isEmpty)
    }

    @Test
    func updateStatusCollapsesReadyToIdleForFocusedPanelInActiveApp() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore(isApplicationActive: { true })
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let focusedPanelID = try #require(selection.workspace.focusedPanelID)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-focused-ready",
            agent: .codex,
            panelID: focusedPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-focused-ready",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Finished"),
            at: startedAt.addingTimeInterval(1)
        )

        #expect(sessionStore.panelStatus(for: focusedPanelID)?.status.kind == .idle)
        #expect(sessionStore.panelStatus(for: focusedPanelID)?.status.detail == "Finished")
        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs.isEmpty)
    }

    @Test
    func handleCommandFinishedMarksBackgroundProcessWatchReadyAndUnread() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_010)

        sessionStore.startProcessWatch(
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            displayTitleOverride: "bundle exec rspec",
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )

        #expect(
            sessionStore.handleCommandFinished(
                panelID: backgroundPanelID,
                exitCode: 0,
                at: startedAt.addingTimeInterval(1)
            )
        )

        let record = try #require(sessionStore.sessionRegistry.activeSession(for: backgroundPanelID))
        #expect(record.agent == .processWatch)
        #expect(record.displayTitleOverride == "bundle exec rspec")
        #expect(record.status?.kind == .ready)
        #expect(record.status?.detail == "Completed")
        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs == [backgroundPanelID])
    }

    @Test
    func handleCommandFinishedMarksBackgroundProcessWatchErrorAndUnread() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_020)

        sessionStore.startProcessWatch(
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            displayTitleOverride: "npm test",
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )

        #expect(
            sessionStore.handleCommandFinished(
                panelID: backgroundPanelID,
                exitCode: 1,
                at: startedAt.addingTimeInterval(1)
            )
        )

        let record = try #require(sessionStore.sessionRegistry.activeSession(for: backgroundPanelID))
        #expect(record.status?.kind == .error)
        #expect(record.status?.detail == "Exit 1")
        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs == [backgroundPanelID])
    }

    @Test
    func focusPanelCollapsesUnreadReadySessionToIdle() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-background-ready",
            agent: .codex,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-background-ready",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Finished"),
            at: startedAt.addingTimeInterval(1)
        )

        #expect(appStore.send(.focusPanel(workspaceID: selection.workspaceID, panelID: backgroundPanelID)))
        #expect(sessionStore.panelStatus(for: backgroundPanelID)?.status.kind == .idle)
        #expect(sessionStore.panelStatus(for: backgroundPanelID)?.status.detail == "Finished")
        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs.isEmpty)
    }

    @Test
    func focusPanelRemovesReadyProcessWatchAfterRead() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_030)

        sessionStore.startProcessWatch(
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            displayTitleOverride: "bundle exec rspec",
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        #expect(
            sessionStore.handleCommandFinished(
                panelID: backgroundPanelID,
                exitCode: 0,
                at: startedAt.addingTimeInterval(1)
            )
        )

        #expect(appStore.send(.focusPanel(workspaceID: selection.workspaceID, panelID: backgroundPanelID)))
        #expect(sessionStore.sessionRegistry.activeSession(for: backgroundPanelID) == nil)
        #expect(sessionStore.panelStatus(for: backgroundPanelID) == nil)
    }

    @Test
    func focusPanelKeepsNeedsApprovalStatusAfterRead() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-background-approval",
            agent: .claude,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-background-approval",
            status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Confirm"),
            at: startedAt.addingTimeInterval(1)
        )

        #expect(appStore.send(.focusPanel(workspaceID: selection.workspaceID, panelID: backgroundPanelID)))
        #expect(sessionStore.panelStatus(for: backgroundPanelID)?.status.kind == .needsApproval)
        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs.isEmpty)
    }

    @Test
    func updateStatusCollapsesReadyToIdleWhenFocusedApprovalIsResolved() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore(isApplicationActive: { true })
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-approval-resolved",
            agent: .claude,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-approval-resolved",
            status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Confirm"),
            at: startedAt.addingTimeInterval(1)
        )

        #expect(appStore.send(.focusPanel(workspaceID: selection.workspaceID, panelID: backgroundPanelID)))
        #expect(sessionStore.panelStatus(for: backgroundPanelID)?.status.kind == .needsApproval)

        sessionStore.updateStatus(
            sessionID: "sess-approval-resolved",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Continuing"),
            at: startedAt.addingTimeInterval(2)
        )
        #expect(sessionStore.panelStatus(for: backgroundPanelID)?.status.kind == .working)

        sessionStore.updateStatus(
            sessionID: "sess-approval-resolved",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Finished"),
            at: startedAt.addingTimeInterval(3)
        )

        #expect(sessionStore.panelStatus(for: backgroundPanelID)?.status.kind == .idle)
        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs.isEmpty)
    }

    @Test
    func focusPanelKeepsErrorStatusAfterRead() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-background-error",
            agent: .codex,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-background-error",
            status: SessionStatus(kind: .error, summary: "Error", detail: "Failed"),
            at: startedAt.addingTimeInterval(1)
        )

        #expect(appStore.send(.focusPanel(workspaceID: selection.workspaceID, panelID: backgroundPanelID)))
        #expect(sessionStore.panelStatus(for: backgroundPanelID)?.status.kind == .error)
        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs.isEmpty)
    }

    @Test
    func focusPanelRemovesErroredProcessWatchAfterRead() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_040)

        sessionStore.startProcessWatch(
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            displayTitleOverride: "npm test",
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        #expect(
            sessionStore.handleCommandFinished(
                panelID: backgroundPanelID,
                exitCode: 2,
                at: startedAt.addingTimeInterval(1)
            )
        )

        #expect(appStore.send(.focusPanel(workspaceID: selection.workspaceID, panelID: backgroundPanelID)))
        #expect(sessionStore.sessionRegistry.activeSession(for: backgroundPanelID) == nil)
        #expect(sessionStore.panelStatus(for: backgroundPanelID) == nil)
    }

    @Test
    func stopSessionForPanelIfOlderThanKeepsCompletedProcessWatchAliveUntilRead() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_050)

        sessionStore.startProcessWatch(
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            displayTitleOverride: "bundle exec rspec",
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        #expect(
            sessionStore.handleCommandFinished(
                panelID: backgroundPanelID,
                exitCode: 0,
                at: startedAt.addingTimeInterval(1)
            )
        )

        #expect(
            sessionStore.stopSessionForPanelIfOlderThan(
                panelID: backgroundPanelID,
                minimumRuntime: 2,
                reason: .idleAtPrompt,
                at: startedAt.addingTimeInterval(3)
            ) == false
        )
        #expect(sessionStore.sessionRegistry.activeSession(for: backgroundPanelID)?.status?.kind == .ready)
    }

    @Test
    func idleAtPromptFallbackCompletesBackgroundProcessWatchAndSendsNotification() async throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let recorder = SessionNotificationRecorder()
        let sessionStore = SessionRuntimeStore(
            sendSessionStatusNotification: { title, body, workspaceID, panelID, context in
                await recorder.record(
                    title: title,
                    body: body,
                    workspaceID: workspaceID,
                    panelID: panelID,
                    context: context
                )
            },
            isApplicationActive: { false }
        )
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_060)

        sessionStore.startProcessWatch(
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            displayTitleOverride: "bundle exec rspec",
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )

        #expect(
            sessionStore.stopSessionForPanelIfOlderThan(
                panelID: backgroundPanelID,
                minimumRuntime: 1,
                reason: .idleAtPrompt,
                at: startedAt.addingTimeInterval(2)
            )
        )

        await waitUntilNotificationCount(recorder, expectedCount: 1)

        let record = try #require(sessionStore.sessionRegistry.activeSession(for: backgroundPanelID))
        #expect(record.status?.kind == .ready)
        #expect(record.status?.detail == "Completed")

        let notification = try #require(await recorder.notifications().first)
        #expect(notification.title == "Command finished")
        #expect(notification.body == "bundle exec rspec")
        #expect(notification.workspaceID == selection.workspaceID)
        #expect(notification.panelID == backgroundPanelID)

        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs == [backgroundPanelID])
    }

    @Test
    func updateStatusDoesNotSendNotificationForFocusedManagedPanel() async throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let recorder = SessionNotificationRecorder()
        let sessionStore = SessionRuntimeStore(
            sendSessionStatusNotification: { title, body, workspaceID, panelID, context in
                await recorder.record(
                    title: title,
                    body: body,
                    workspaceID: workspaceID,
                    panelID: panelID,
                    context: context
                )
            },
            isApplicationActive: { true }
        )
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let focusedPanelID = try #require(selection.workspace.focusedPanelID)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-focused-managed",
            agent: .claude,
            panelID: focusedPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-focused-managed",
            status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Confirm"),
            at: startedAt.addingTimeInterval(1)
        )

        await settleNotificationTasks()

        let notifications = await recorder.notifications()
        #expect(notifications.isEmpty)
        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs.isEmpty)
    }

    @Test
    func updateStatusSendsNotificationForFocusedManagedPanelWhenApplicationIsInactive() async throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let recorder = SessionNotificationRecorder()
        let sessionStore = SessionRuntimeStore(
            sendSessionStatusNotification: { title, body, workspaceID, panelID, context in
                await recorder.record(
                    title: title,
                    body: body,
                    workspaceID: workspaceID,
                    panelID: panelID,
                    context: context
                )
            },
            isApplicationActive: { false }
        )
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let focusedPanelID = try #require(selection.workspace.focusedPanelID)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-focused-backgrounded",
            agent: .codex,
            panelID: focusedPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-focused-backgrounded",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Finished"),
            at: startedAt.addingTimeInterval(1)
        )

        await waitUntilNotificationCount(recorder, expectedCount: 1)

        let notification = try #require(await recorder.notifications().first)
        #expect(notification.title == "Codex is ready")
        #expect(notification.body == "Finished")

        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs == [focusedPanelID])
    }

    @Test
    func updateStatusSendsNotificationForUnfocusedManagedPanelWhenApplicationIsInactive() async throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let recorder = SessionNotificationRecorder()
        let sessionStore = SessionRuntimeStore(
            sendSessionStatusNotification: { title, body, workspaceID, panelID, context in
                await recorder.record(
                    title: title,
                    body: body,
                    workspaceID: workspaceID,
                    panelID: panelID,
                    context: context
                )
            },
            isApplicationActive: { false }
        )
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-background-backgrounded",
            agent: .codex,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-background-backgrounded",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Finished"),
            at: startedAt.addingTimeInterval(1)
        )

        await waitUntilNotificationCount(recorder, expectedCount: 1)

        let notification = try #require(await recorder.notifications().first)
        #expect(notification.title == "Codex is ready")
        #expect(notification.body == "Finished")

        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs == [backgroundPanelID])
    }

    @Test
    func updateStatusDoesNotSendNotificationForUnmanagedSession() async throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let recorder = SessionNotificationRecorder()
        let sessionStore = SessionRuntimeStore(
            sendSessionStatusNotification: { title, body, workspaceID, panelID, context in
                await recorder.record(
                    title: title,
                    body: body,
                    workspaceID: workspaceID,
                    panelID: panelID,
                    context: context
                )
            }
        )
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-unmanaged",
            agent: .codex,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-unmanaged",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Finished"),
            at: startedAt.addingTimeInterval(1)
        )

        await settleNotificationTasks()

        let notifications = await recorder.notifications()
        #expect(notifications.isEmpty)
        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs == [backgroundPanelID])
    }

    @Test
    func updateStatusDoesNotRepeatNotificationForSameActionableKind() async throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let recorder = SessionNotificationRecorder()
        let sessionStore = SessionRuntimeStore(
            sendSessionStatusNotification: { title, body, workspaceID, panelID, context in
                await recorder.record(
                    title: title,
                    body: body,
                    workspaceID: workspaceID,
                    panelID: panelID,
                    context: context
                )
            }
        )
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-repeat",
            agent: .codex,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-repeat",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "First"),
            at: startedAt.addingTimeInterval(1)
        )
        await waitUntilNotificationCount(recorder, expectedCount: 1)

        sessionStore.updateStatus(
            sessionID: "sess-repeat",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Second"),
            at: startedAt.addingTimeInterval(2)
        )
        await settleNotificationTasks()

        let notificationCount = await recorder.count()
        #expect(notificationCount == 1)
    }

    @Test
    func updateStatusClearsUnreadWhenManagedSessionReturnsToWorking() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore(isApplicationActive: { true })
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-managed-working",
            agent: .codex,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-managed-working",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Subagent finished"),
            at: startedAt.addingTimeInterval(1)
        )

        let workspaceAfterReady = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfterReady.unreadPanelIDs == [backgroundPanelID])

        sessionStore.updateStatus(
            sessionID: "sess-managed-working",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Continuing"),
            at: startedAt.addingTimeInterval(2)
        )

        let workspaceAfterWorking = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfterWorking.unreadPanelIDs.isEmpty)
        #expect(workspaceAfterWorking.unreadNotificationCount == 0)
    }

    @Test
    func updateStatusKeepsUnreadWhenFocusedManagedSessionReturnsToWorkingInInactiveApp() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore(isApplicationActive: { false })
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let focusedPanelID = try #require(selection.workspace.focusedPanelID)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-focused-managed-working-inactive",
            agent: .codex,
            panelID: focusedPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-focused-managed-working-inactive",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Subagent finished"),
            at: startedAt.addingTimeInterval(1)
        )

        let workspaceAfterReady = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfterReady.unreadPanelIDs == [focusedPanelID])

        sessionStore.updateStatus(
            sessionID: "sess-focused-managed-working-inactive",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Continuing"),
            at: startedAt.addingTimeInterval(2)
        )

        let workspaceAfterWorking = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfterWorking.unreadPanelIDs == [focusedPanelID])
        #expect(workspaceAfterWorking.unreadNotificationCount == 1)
    }

    @Test
    func updateStatusClearsUnreadWhenBackgroundManagedSessionReturnsToWorkingInInactiveApp() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore(isApplicationActive: { false })
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-background-managed-working-inactive",
            agent: .codex,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-background-managed-working-inactive",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Subagent finished"),
            at: startedAt.addingTimeInterval(1)
        )

        let workspaceAfterReady = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfterReady.unreadPanelIDs == [backgroundPanelID])

        sessionStore.updateStatus(
            sessionID: "sess-background-managed-working-inactive",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Continuing"),
            at: startedAt.addingTimeInterval(2)
        )

        let workspaceAfterWorking = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfterWorking.unreadPanelIDs.isEmpty)
        #expect(workspaceAfterWorking.unreadNotificationCount == 0)
    }

    @Test
    func updateStatusKeepsUnreadWhenUnmanagedSessionReturnsToWorking() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-unmanaged-working",
            agent: .codex,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-unmanaged-working",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Subagent finished"),
            at: startedAt.addingTimeInterval(1)
        )

        let workspaceAfterReady = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfterReady.unreadPanelIDs == [backgroundPanelID])

        sessionStore.updateStatus(
            sessionID: "sess-unmanaged-working",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Continuing"),
            at: startedAt.addingTimeInterval(2)
        )

        let workspaceAfterWorking = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfterWorking.unreadPanelIDs == [backgroundPanelID])
        #expect(workspaceAfterWorking.unreadNotificationCount == 1)
    }

    @Test
    func updateStatusFallsBackToTrimmedSummaryWhenDetailIsBlank() async throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let recorder = SessionNotificationRecorder()
        let sessionStore = SessionRuntimeStore(
            sendSessionStatusNotification: { title, body, workspaceID, panelID, context in
                await recorder.record(
                    title: title,
                    body: body,
                    workspaceID: workspaceID,
                    panelID: panelID,
                    context: context
                )
            }
        )
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-blank-detail",
            agent: .claude,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-blank-detail",
            status: SessionStatus(kind: .ready, summary: "  Ready for prompt  ", detail: "   \n"),
            at: startedAt.addingTimeInterval(1)
        )

        await waitUntilNotificationCount(recorder, expectedCount: 1)

        let notification = try #require(await recorder.notifications().first)
        #expect(notification.body == "Ready for prompt")
    }

    @Test
    func workspaceStatusesFollowSessionCreationOrder() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let orderedPanelIDs = selection.workspace.terminalPanelIDsInDisplayOrder
        let leftPanelID = try #require(orderedPanelIDs.first)
        let rightPanelID = try #require(orderedPanelIDs.last)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-right",
            agent: .codex,
            panelID: rightPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: "/repo/right",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-right",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Right panel"),
            at: startedAt.addingTimeInterval(2)
        )

        sessionStore.startSession(
            sessionID: "sess-left",
            agent: .claude,
            panelID: leftPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: "/repo/left",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-left",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Left panel"),
            at: startedAt.addingTimeInterval(1)
        )

        let statuses = sessionStore.workspaceStatuses(for: selection.workspaceID)
        #expect(statuses.map(\.panelID) == [rightPanelID, leftPanelID])
    }

    @Test
    func workspaceStatusesStayStableWhenSelectedTabChanges() throws {
        let appStore = AppStore(persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)

        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let workspaceID = selection.workspaceID
        let originalTabID = try #require(selection.workspace.resolvedSelectedTabID)
        let originalPanelID = try #require(selection.workspace.focusedPanelID)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-original-tab",
            agent: .codex,
            panelID: originalPanelID,
            windowID: selection.windowID,
            workspaceID: workspaceID,
            cwd: "/repo/original",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-original-tab",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Original tab"),
            at: startedAt.addingTimeInterval(1)
        )

        #expect(appStore.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil)))
        let workspaceWithNewTab = try #require(appStore.state.workspacesByID[workspaceID])
        let newSelectedTabID = try #require(workspaceWithNewTab.resolvedSelectedTabID)
        #expect(newSelectedTabID != originalTabID)
        let newSelectedPanelID = try #require(workspaceWithNewTab.focusedPanelID)

        sessionStore.startSession(
            sessionID: "sess-new-tab",
            agent: .claude,
            panelID: newSelectedPanelID,
            windowID: selection.windowID,
            workspaceID: workspaceID,
            cwd: "/repo/new",
            repoRoot: "/repo",
            at: startedAt.addingTimeInterval(2)
        )
        sessionStore.updateStatus(
            sessionID: "sess-new-tab",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "New tab"),
            at: startedAt.addingTimeInterval(3)
        )

        #expect(sessionStore.workspaceStatuses(for: workspaceID).map(\.sessionID) == ["sess-original-tab", "sess-new-tab"])

        #expect(appStore.send(.selectWorkspaceTab(workspaceID: workspaceID, tabID: originalTabID)))
        #expect(sessionStore.workspaceStatuses(for: workspaceID).map(\.sessionID) == ["sess-original-tab", "sess-new-tab"])

        #expect(appStore.send(.selectWorkspaceTab(workspaceID: workspaceID, tabID: newSelectedTabID)))
        #expect(sessionStore.workspaceStatuses(for: workspaceID).map(\.sessionID) == ["sess-original-tab", "sess-new-tab"])
    }

    @Test
    func handleLocalInterruptResetsWorkingClaudeSession() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-working",
            agent: .claude,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-working",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Responding"),
            at: startedAt.addingTimeInterval(1)
        )

        let didReset = sessionStore.handleLocalInterruptForPanelIfActive(
            panelID: panelID,
            kind: .escape,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didReset)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready for prompt")
        )
    }

    @Test
    func handleLocalInterruptDoesNotResetFallbackTrackedWorkingCodexSessionOnEscape() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-codex-working",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .sessionLogFallback(reason: "test"),
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-codex-working",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Responding"),
            at: startedAt.addingTimeInterval(1)
        )

        let didReset = sessionStore.handleLocalInterruptForPanelIfActive(
            panelID: panelID,
            kind: .escape,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didReset == false)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(kind: .working, summary: "Working", detail: "Responding")
        )
    }

    @Test
    func handleLocalInterruptResetsHookTrackedWorkingCodexSessionOnEscape() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-codex-hook-working",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-codex-hook-working",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Responding"),
            at: startedAt.addingTimeInterval(1)
        )

        let didReset = sessionStore.handleLocalInterruptForPanelIfActive(
            panelID: panelID,
            kind: .escape,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didReset)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready for prompt")
        )
    }

    @Test
    func handleLocalInterruptResetsHookTrackedNeedsApprovalCodexSessionOnEscape() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-codex-hook-approval",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-codex-hook-approval",
            status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
            at: startedAt.addingTimeInterval(1)
        )

        let didReset = sessionStore.handleLocalInterruptForPanelIfActive(
            panelID: panelID,
            kind: .escape,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didReset)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready for prompt")
        )
    }

    @Test
    func handleLocalInterruptKeepsCodexControlCResetBehavior() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-codex-control-c",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-codex-control-c",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Responding"),
            at: startedAt.addingTimeInterval(1)
        )

        let didReset = sessionStore.handleLocalInterruptForPanelIfActive(
            panelID: panelID,
            kind: .controlC,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didReset)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready for prompt")
        )
    }

    @Test
    func handleLocalInterruptDoesNotResetCodexSessionForDifferentPanelEscape() {
        let sessionStore = SessionRuntimeStore()
        let codexPanelID = UUID()
        let otherPanelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-codex-focused-panel",
            agent: .codex,
            panelID: codexPanelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-codex-focused-panel",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Responding"),
            at: startedAt.addingTimeInterval(1)
        )

        let didReset = sessionStore.handleLocalInterruptForPanelIfActive(
            panelID: otherPanelID,
            kind: .escape,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didReset == false)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: codexPanelID)?.status ==
                SessionStatus(kind: .working, summary: "Working", detail: "Responding")
        )
    }

    @Test
    func refreshManagedSessionStatusFromVisibleTextUpdatesWorkingCodexDetail() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-visible-text",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-visible-text",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Responding to your prompt"),
            at: startedAt.addingTimeInterval(1)
        )

        let didRefresh = sessionStore.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: """
            dev@host ~/repo % codex
            • Running pwd and git status --short in the current repo now, then I’ll report the modified-entry count.
            """,
            promptState: .busy,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didRefresh)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(
                    kind: .working,
                    summary: "Working",
                    detail: "Running pwd and git status --short in the current repo now, then I’ll report the modified-entry count."
                )
        )
    }

    @Test
    func refreshManagedSessionStatusFromVisibleTextIgnoresGenericWorkingSpinner() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-generic-visible-text",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-generic-visible-text",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Responding to your prompt"),
            at: startedAt.addingTimeInterval(1)
        )

        let didRefresh = sessionStore.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: "Working (7s • esc to interrupt)",
            promptState: .busy,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didRefresh == false)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(kind: .working, summary: "Working", detail: "Responding to your prompt")
        )
    }

    @Test
    func refreshManagedSessionStatusFromVisibleTextDoesNotRecoverIdleCodexSessionFromLiveStatusLine() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-visible-text-idle-recovery",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-visible-text-idle-recovery",
            status: SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready for prompt"),
            at: startedAt.addingTimeInterval(1)
        )

        let didRefresh = sessionStore.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: """
            dev@host ~/repo % codex
            • Running pwd and git status --short in the current repo now, then I’ll report the modified-entry count.
            Deciding on a test file (20s • esc to interrupt)
            """,
            promptState: .busy,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didRefresh == false)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready for prompt")
        )
    }

    @Test
    func refreshManagedSessionStatusFromVisibleTextDoesNotRecoverReadyCodexSessionFromLiveStatusLine() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-visible-text-ready-recovery",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-visible-text-ready-recovery",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Finished previous task"),
            at: startedAt.addingTimeInterval(1)
        )

        let didRefresh = sessionStore.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: "Deciding on a test file (20s • esc to interrupt)",
            promptState: .busy,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didRefresh == false)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(kind: .ready, summary: "Ready", detail: "Finished previous task")
        )
    }

    @Test
    func refreshManagedSessionStatusFromVisibleTextDoesNotRecoverIdleCodexSessionFromStaleBulletAtPrompt() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-visible-text-stale-bullet",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-visible-text-stale-bullet",
            status: SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready for prompt"),
            at: startedAt.addingTimeInterval(1)
        )

        let didRefresh = sessionStore.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: """
            • Running pwd and git status --short in the current repo now, then I’ll report the modified-entry count.
            dev@host ~/repo %
            """,
            promptState: .idleAtPrompt,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didRefresh == false)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready for prompt")
        )
    }

    @Test
    func refreshManagedSessionStatusFromVisibleTextPromotesWorkingCodexSessionToErrorForUsageLimitBanner() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let usageLimitBanner = """
        You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Apr 2nd, 2026 7:19 PM.
        """

        sessionStore.startSession(
            sessionID: "sess-visible-text-error",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-visible-text-error",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Responding to your prompt"),
            at: startedAt.addingTimeInterval(1)
        )

        let didRefresh = sessionStore.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: usageLimitBanner,
            promptState: .busy,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didRefresh)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(kind: .error, summary: "Error", detail: usageLimitBanner)
        )
    }

    @Test
    func refreshManagedSessionStatusFromVisibleTextKeepsErrorStatusWhenFatalBannerDisappears() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let usageLimitBanner = """
        You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Apr 2nd, 2026 7:19 PM.
        """

        sessionStore.startSession(
            sessionID: "sess-visible-text-error-sticky",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-visible-text-error-sticky",
            status: SessionStatus(kind: .error, summary: "Error", detail: usageLimitBanner),
            at: startedAt.addingTimeInterval(1)
        )

        let didRefresh = sessionStore.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: "• Running pwd",
            promptState: .busy,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didRefresh == false)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(kind: .error, summary: "Error", detail: usageLimitBanner)
        )
    }

    @Test
    func refreshManagedSessionStatusFromVisibleTextIgnoresStaleUsageLimitBannerAfterWatcherRecovery() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let usageLimitBanner = """
        You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Apr 2nd, 2026 7:19 PM.
        """

        sessionStore.startSession(
            sessionID: "sess-visible-text-error-recovery",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-visible-text-error-recovery",
            status: SessionStatus(kind: .error, summary: "Error", detail: usageLimitBanner),
            at: startedAt.addingTimeInterval(1)
        )

        sessionStore.updateStatus(
            sessionID: "sess-visible-text-error-recovery",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Running tests"),
            at: startedAt.addingTimeInterval(2)
        )

        let didRefreshStaleBanner = sessionStore.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: usageLimitBanner,
            promptState: .busy,
            at: startedAt.addingTimeInterval(3)
        )
        let didRefreshWorkingDetail = sessionStore.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: "• Running pwd",
            promptState: .busy,
            at: startedAt.addingTimeInterval(4)
        )
        let didRefreshRecoveredError = sessionStore.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: usageLimitBanner,
            promptState: .busy,
            at: startedAt.addingTimeInterval(5)
        )

        #expect(didRefreshStaleBanner == false)
        #expect(didRefreshWorkingDetail)
        #expect(didRefreshRecoveredError)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(kind: .error, summary: "Error", detail: usageLimitBanner)
        )
    }

    @Test
    func refreshManagedSessionStatusFromVisibleTextKeepsSuppressingRecoveredBannerAcrossGenericVisibleText() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let usageLimitBanner = """
        You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Apr 2nd, 2026 7:19 PM.
        """

        sessionStore.startSession(
            sessionID: "sess-visible-text-error-scroll-gap",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-visible-text-error-scroll-gap",
            status: SessionStatus(kind: .error, summary: "Error", detail: usageLimitBanner),
            at: startedAt.addingTimeInterval(1)
        )

        sessionStore.updateStatus(
            sessionID: "sess-visible-text-error-scroll-gap",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Running tests"),
            at: startedAt.addingTimeInterval(2)
        )

        let didRefreshGenericVisibleText = sessionStore.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: """
            dev@host ~/repo % codex
            OpenAI Codex (v0.1)
            """,
            promptState: .busy,
            at: startedAt.addingTimeInterval(3)
        )
        let didRefreshStaleBanner = sessionStore.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: usageLimitBanner,
            promptState: .busy,
            at: startedAt.addingTimeInterval(4)
        )

        #expect(didRefreshGenericVisibleText == false)
        #expect(didRefreshStaleBanner == false)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(kind: .working, summary: "Working", detail: "Running tests")
        )
    }

    @Test
    func refreshManagedSessionStatusFromVisibleTextIgnoresNonCodexAgent() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-visible-text-claude",
            agent: .claude,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-visible-text-claude",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Responding"),
            at: startedAt.addingTimeInterval(1)
        )

        let didRefresh = sessionStore.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: "• Running pwd",
            promptState: .busy,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didRefresh == false)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(kind: .working, summary: "Working", detail: "Responding")
        )
    }

    @Test
    func refreshManagedSessionStatusFromVisibleTextIgnoresSessionWithoutCurrentStatus() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-visible-text-no-status",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )

        let didRefresh = sessionStore.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: "• Running pwd",
            promptState: .busy,
            at: startedAt.addingTimeInterval(1)
        )

        #expect(didRefresh == false)
        #expect(sessionStore.sessionRegistry.activeSession(for: panelID)?.status == nil)
    }

    @Test
    func refreshManagedSessionStatusFromVisibleTextSkipsDuplicateWorkingDetail() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        sessionStore.startSession(
            sessionID: "sess-visible-text-duplicate",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-visible-text-duplicate",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Running pwd"),
            at: startedAt.addingTimeInterval(1)
        )

        let didRefresh = sessionStore.refreshManagedSessionStatusFromVisibleTextIfNeeded(
            panelID: panelID,
            visibleText: "• Running pwd",
            promptState: .busy,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(didRefresh == false)
        #expect(
            sessionStore.sessionRegistry.activeSession(for: panelID)?.status ==
                SessionStatus(kind: .working, summary: "Working", detail: "Running pwd")
        )
    }

    @Test
    func laterFlagPersistsWhenReadSessionIsFocused() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let sessionStore = SessionRuntimeStore()
        sessionStore.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_300)

        sessionStore.startSession(
            sessionID: "sess-later-focus",
            agent: .codex,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-later-focus",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: "Review this change"),
            at: startedAt.addingTimeInterval(1)
        )
        sessionStore.setLaterFlag(sessionID: "sess-later-focus", isFlagged: true)

        #expect(sessionStore.isLaterFlagged(sessionID: "sess-later-focus"))
        #expect(appStore.send(.focusPanel(workspaceID: selection.workspaceID, panelID: backgroundPanelID)))
        #expect(sessionStore.isLaterFlagged(sessionID: "sess-later-focus"))
        #expect(sessionStore.panelStatus(for: backgroundPanelID)?.status.kind == .idle)
    }

    @Test
    func laterFlagClearsWhenSessionReturnsToWorking() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_301)

        sessionStore.startSession(
            sessionID: "sess-later-working",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-later-working",
            status: SessionStatus(kind: .idle, summary: "Waiting", detail: "Review requested"),
            at: startedAt.addingTimeInterval(1)
        )
        sessionStore.setLaterFlag(sessionID: "sess-later-working", isFlagged: true)

        sessionStore.updateStatus(
            sessionID: "sess-later-working",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Responding"),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(sessionStore.isLaterFlagged(sessionID: "sess-later-working") == false)
    }

    @Test
    func laterFlagClearsWhenSessionTransitionsToNewActionableStatus() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_302)

        sessionStore.startSession(
            sessionID: "sess-later-actionable",
            agent: .claude,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-later-actionable",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Editing"),
            at: startedAt.addingTimeInterval(1)
        )
        sessionStore.setLaterFlag(sessionID: "sess-later-actionable", isFlagged: true)

        sessionStore.updateStatus(
            sessionID: "sess-later-actionable",
            status: SessionStatus(kind: .error, summary: "Error", detail: "Command failed"),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(sessionStore.isLaterFlagged(sessionID: "sess-later-actionable") == false)
    }

    @Test
    func laterFlagSurvivesWorkingDetailRefresh() {
        let sessionStore = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_303)

        sessionStore.startSession(
            sessionID: "sess-later-refresh",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        sessionStore.updateStatus(
            sessionID: "sess-later-refresh",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Reading files"),
            at: startedAt.addingTimeInterval(1)
        )
        sessionStore.setLaterFlag(sessionID: "sess-later-refresh", isFlagged: true)

        sessionStore.updateStatus(
            sessionID: "sess-later-refresh",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Running tests"),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(sessionStore.isLaterFlagged(sessionID: "sess-later-refresh"))
    }

    private func makeTwoPanelAppState() -> AppState {
        let leftPanelID = UUID()
        let rightPanelID = UUID()
        let leftSlotID = UUID()
        let rightSlotID = UUID()
        let workspaceID = UUID()
        let windowID = UUID()
        let workspace = WorkspaceState(
            id: workspaceID,
            title: "Workspace 1",
            layoutTree: .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.5,
                first: .slot(slotID: leftSlotID, panelID: leftPanelID),
                second: .slot(slotID: rightSlotID, panelID: rightPanelID)
            ),
            panels: [
                leftPanelID: .terminal(TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "/repo")),
                rightPanelID: .terminal(TerminalPanelState(title: "Terminal 2", shell: "zsh", cwd: "/repo")),
            ],
            focusedPanelID: leftPanelID
        )
        let window = WindowState(
            id: windowID,
            frame: CGRectCodable(x: 120, y: 120, width: 1280, height: 760),
            workspaceIDs: [workspaceID],
            selectedWorkspaceID: workspaceID
        )

        return AppState(
            windows: [window],
            workspacesByID: [workspaceID: workspace],
            selectedWindowID: windowID,
            configuredTerminalFontPoints: nil
        )
    }
}

private func persistedResumeRecord(panelID: UUID, in state: AppState) -> ManagedAgentResumeRecord? {
    guard let selection = state.workspaceSelection(containingPanelID: panelID),
          case .terminal(let terminalState)? = selection.workspace.panelState(for: panelID) else {
        return nil
    }

    return terminalState.resumeRecord
}

private struct RecordedSessionNotification: Equatable {
    let title: String
    let body: String
    let workspaceID: UUID
    let panelID: UUID
    let context: DesktopNotificationContext
}

private actor SessionNotificationRecorder {
    private var recorded: [RecordedSessionNotification] = []

    func record(
        title: String,
        body: String,
        workspaceID: UUID,
        panelID: UUID,
        context: DesktopNotificationContext
    ) {
        recorded.append(
            RecordedSessionNotification(
                title: title,
                body: body,
                workspaceID: workspaceID,
                panelID: panelID,
                context: context
            )
        )
    }

    func notifications() -> [RecordedSessionNotification] {
        recorded
    }

    func count() -> Int {
        recorded.count
    }
}

private func settleNotificationTasks(iterations: Int = 12) async {
    for _ in 0..<iterations {
        await Task.yield()
    }
}

private func waitUntilNotificationCount(
    _ recorder: SessionNotificationRecorder,
    expectedCount: Int,
    timeoutNanoseconds: UInt64 = 1_000_000_000
) async {
    let deadline = Date().addingTimeInterval(Double(timeoutNanoseconds) / 1_000_000_000)
    while await recorder.count() != expectedCount && Date() < deadline {
        await Task.yield()
    }
}

@MainActor
private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    condition: @escaping @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(Double(timeoutNanoseconds) / 1_000_000_000)
    while condition() == false && Date() < deadline {
        await Task.yield()
    }
}
