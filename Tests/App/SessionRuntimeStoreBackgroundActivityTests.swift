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
    func codexCorrelatedRolloutInterruptAndFollowUpControlHookActivity() {
        let store = SessionRuntimeStore()
        defer { store.reset() }
        let now = Date(timeIntervalSince1970: 1_700_001_260)
        let sessionID = "sess-codex-correlated-turns"
        let providerAgentID = "thread-teller"
        let activityID = "/root/teller_schema_contract"

        store.startSession(
            sessionID: sessionID,
            agent: .codex,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: now
        )

        let hookStart = CodexHookEvent(
            hookEventName: "SubagentStart",
            threadID: "thread-root",
            turnID: "turn-root",
            promptFingerprint: nil,
            status: nil,
            nativeSessionID: "thread-root",
            sessionFilePath: nil,
            cwd: nil,
            subagentID: providerAgentID,
            subagentType: "reviewer"
        )
        #expect(store.handleCodexHookEvent(
            sessionID: sessionID,
            event: hookStart,
            at: now.addingTimeInterval(1)
        ))

        let interrupted = CodexSessionBackgroundActivity(
            activityID: activityID,
            hookActivityID: providerAgentID,
            kind: .subagent,
            turnTransition: .deactivated
        )
        #expect(store.handleCodexSubagentRolloutObservation(
            sessionID: sessionID,
            observation: .finished(interrupted),
            at: now.addingTimeInterval(2)
        ))
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?
            .backgroundActivitiesByID[providerAgentID] == nil)

        let followedUp = CodexSessionBackgroundActivity(
            activityID: activityID,
            hookActivityID: providerAgentID,
            kind: .subagent,
            displayName: "teller_schema_contract",
            turnTransition: .activated
        )
        #expect(store.handleCodexSubagentRolloutObservation(
            sessionID: sessionID,
            observation: .started(followedUp),
            at: now.addingTimeInterval(3)
        ))
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?
            .backgroundActivitiesByID[providerAgentID]?.displayName == "teller_schema_contract")
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?
            .backgroundActivitiesByID[activityID] == nil)

        #expect(store.handleCodexSubagentRolloutObservation(
            sessionID: sessionID,
            observation: .finished(interrupted),
            at: now.addingTimeInterval(4)
        ))
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?
            .backgroundActivitiesByID[providerAgentID] == nil)
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

        let activity = CodexSessionBackgroundActivity(
            activityID: activityID,
            kind: .subagent,
            displayName: "plan_review"
        )
        #expect(store.handleCodexSubagentRolloutObservation(
            sessionID: sessionID,
            observation: .started(activity),
            at: now
        ))
        #expect(store.handleCodexSubagentRolloutObservation(
            sessionID: sessionID,
            observation: .finished(activity),
            at: now.addingTimeInterval(1)
        ))

        #expect(store.handleCodexSubagentRolloutObservation(
            sessionID: sessionID,
            observation: .started(activity),
            at: now.addingTimeInterval(2)
        ) == false)
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?
            .backgroundActivitiesByID[activityID] == nil)

        let correlatedFollowUp = CodexSessionBackgroundActivity(
            activityID: activityID,
            kind: .subagent,
            displayName: "plan_review",
            turnTransition: .activated
        )
        #expect(store.handleCodexSubagentRolloutObservation(
            sessionID: sessionID,
            observation: .started(correlatedFollowUp),
            at: now.addingTimeInterval(3)
        ))
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?
            .backgroundActivitiesByID[activityID]?.displayName == "plan_review")
    }

    @Test
    func codexSubagentRolloutObservationUsesSessionFixedAuthority() {
        let store = SessionRuntimeStore()
        defer { store.reset() }
        let now = Date(timeIntervalSince1970: 1_700_001_290)
        let hookSessionID = "sess-codex-fixed-hooks"
        let fallbackSessionID = "sess-codex-fixed-fallback"

        for (sessionID, source) in [
            (hookSessionID, CodexStatusTrackingSource.hooks),
            (fallbackSessionID, .sessionLogFallback(reason: "test")),
        ] {
            store.startSession(
                sessionID: sessionID,
                agent: .codex,
                panelID: UUID(),
                windowID: UUID(),
                workspaceID: UUID(),
                usesSessionStatusNotifications: true,
                codexStatusTrackingSource: source,
                cwd: "/repo",
                repoRoot: "/repo",
                at: now
            )
        }

        let rolloutActivity = CodexSessionBackgroundActivity(
            activityID: "rollout-row",
            hookActivityID: "provider-agent",
            kind: .subagent,
            displayName: "rollout display"
        )
        #expect(store.handleCodexSubagentRolloutObservation(
            sessionID: hookSessionID,
            observation: .started(rolloutActivity),
            at: now.addingTimeInterval(1)
        ) == false)
        #expect(store.sessionRegistry.activeSession(sessionID: hookSessionID)?
            .backgroundActivitiesByID.isEmpty == true)

        #expect(store.handleCodexSubagentRolloutObservation(
            sessionID: fallbackSessionID,
            observation: .started(rolloutActivity),
            at: now.addingTimeInterval(1)
        ))
        #expect(store.sessionRegistry.activeSession(sessionID: fallbackSessionID)?
            .backgroundActivitiesByID["rollout-row"]?.displayName == "rollout display")
        #expect(store.sessionRegistry.activeSession(sessionID: fallbackSessionID)?
            .backgroundActivitiesByID["provider-agent"] == nil)

        #expect(store.handleCodexHookEvent(
            sessionID: fallbackSessionID,
            event: CodexHookEvent(
                hookEventName: "SubagentStart",
                threadID: nil,
                turnID: nil,
                promptFingerprint: nil,
                status: nil,
                nativeSessionID: nil,
                sessionFilePath: nil,
                cwd: nil,
                subagentID: "provider-agent",
                subagentType: "reviewer"
            ),
            at: now.addingTimeInterval(2)
        ) == false)
        #expect(store.sessionRegistry.activeSession(sessionID: fallbackSessionID)?
            .backgroundActivitiesByID["provider-agent"] == nil)
    }

    @Test
    func codexSubagentProfileEnrichmentUsesAuthorityAndNeverCreatesRows() {
        let store = SessionRuntimeStore()
        defer { store.reset() }
        let now = Date(timeIntervalSince1970: 1_700_001_292)
        let hookSessionID = "sess-codex-profile-hooks"
        let fallbackSessionID = "sess-codex-profile-fallback"
        let profile = SessionAgentExecutionProfile(
            modelIdentifier: "gpt-5.6-luna",
            reasoningEffort: "xhigh"
        )

        for (sessionID, source) in [
            (hookSessionID, CodexStatusTrackingSource.hooks),
            (fallbackSessionID, .sessionLogFallback(reason: "test")),
        ] {
            store.startSession(
                sessionID: sessionID,
                agent: .codex,
                panelID: UUID(),
                windowID: UUID(),
                workspaceID: UUID(),
                usesSessionStatusNotifications: true,
                codexStatusTrackingSource: source,
                cwd: "/repo",
                repoRoot: "/repo",
                at: now
            )
        }

        #expect(store.handleCodexHookEvent(
            sessionID: hookSessionID,
            event: CodexHookEvent(
                hookEventName: "SubagentStart",
                threadID: nil,
                turnID: nil,
                promptFingerprint: nil,
                status: nil,
                nativeSessionID: nil,
                sessionFilePath: nil,
                cwd: nil,
                subagentID: "provider-agent",
                subagentType: "explorer"
            ),
            at: now.addingTimeInterval(1)
        ))
        #expect(store.handleCodexSubagentRolloutObservation(
            sessionID: fallbackSessionID,
            observation: .started(CodexSessionBackgroundActivity(
                activityID: "/root/explore",
                hookActivityID: "provider-agent",
                kind: .subagent,
                displayName: "explore"
            )),
            at: now.addingTimeInterval(1)
        ))
        let hookSessionUpdatedAt = store.sessionRegistry.activeSession(sessionID: hookSessionID)?.updatedAt
        let hookActivityUpdatedAt = store.sessionRegistry.activeSession(sessionID: hookSessionID)?
            .backgroundActivitiesByID["provider-agent"]?.lastUpdatedAt
        let fallbackSessionUpdatedAt = store.sessionRegistry.activeSession(sessionID: fallbackSessionID)?.updatedAt
        let fallbackActivityUpdatedAt = store.sessionRegistry.activeSession(sessionID: fallbackSessionID)?
            .backgroundActivitiesByID["/root/explore"]?.lastUpdatedAt

        #expect(store.enrichCodexSubagentExecutionProfile(
            sessionID: hookSessionID,
            rolloutActivityID: "/root/explore",
            providerAgentID: "provider-agent",
            profile: profile,
            at: now.addingTimeInterval(2)
        ))
        #expect(store.enrichCodexSubagentExecutionProfile(
            sessionID: fallbackSessionID,
            rolloutActivityID: "/root/explore",
            providerAgentID: "provider-agent",
            profile: profile,
            at: now.addingTimeInterval(2)
        ))
        #expect(store.sessionRegistry.activeSession(sessionID: hookSessionID)?
            .backgroundActivitiesByID["provider-agent"]?.executionProfile == profile)
        #expect(store.sessionRegistry.activeSession(sessionID: fallbackSessionID)?
            .backgroundActivitiesByID["/root/explore"]?.executionProfile == profile)
        #expect(store.sessionRegistry.activeSession(sessionID: hookSessionID)?.updatedAt == hookSessionUpdatedAt)
        #expect(store.sessionRegistry.activeSession(sessionID: hookSessionID)?
            .backgroundActivitiesByID["provider-agent"]?.lastUpdatedAt == hookActivityUpdatedAt)
        #expect(store.sessionRegistry.activeSession(sessionID: fallbackSessionID)?.updatedAt == fallbackSessionUpdatedAt)
        #expect(store.sessionRegistry.activeSession(sessionID: fallbackSessionID)?
            .backgroundActivitiesByID["/root/explore"]?.lastUpdatedAt == fallbackActivityUpdatedAt)

        #expect(store.finishBackgroundActivity(
            sessionID: fallbackSessionID,
            activityID: "/root/explore",
            at: now.addingTimeInterval(3)
        ))
        #expect(store.enrichCodexSubagentExecutionProfile(
            sessionID: fallbackSessionID,
            rolloutActivityID: "/root/explore",
            providerAgentID: "provider-agent",
            profile: profile,
            at: now.addingTimeInterval(4)
        ) == false)
        #expect(store.sessionRegistry.activeSession(sessionID: fallbackSessionID)?
            .backgroundActivitiesByID.isEmpty == true)
    }

    @Test
    func codexSubagentNilSourcePreservesLegacyHookAndRolloutResetBehavior() {
        let store = SessionRuntimeStore()
        defer { store.reset() }
        let now = Date(timeIntervalSince1970: 1_700_001_295)
        let sessionID = "sess-codex-legacy-nil-source"

        store.startSession(
            sessionID: sessionID,
            agent: .codex,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: nil,
            cwd: "/repo",
            repoRoot: "/repo",
            at: now
        )

        #expect(store.handleCodexHookEvent(
            sessionID: sessionID,
            event: CodexHookEvent(
                hookEventName: "PreToolUse",
                threadID: nil,
                turnID: nil,
                promptFingerprint: nil,
                status: nil,
                nativeSessionID: nil,
                sessionFilePath: nil,
                cwd: nil,
                spawnMetadata: CodexSpawnHookMetadata(
                    toolUseID: "legacy-call",
                    taskName: "legacy task"
                )
            ),
            at: now.addingTimeInterval(1)
        ))

        let hookStart = CodexHookEvent(
            hookEventName: "SubagentStart",
            threadID: nil,
            turnID: nil,
            promptFingerprint: nil,
            status: nil,
            nativeSessionID: nil,
            sessionFilePath: nil,
            cwd: nil,
            subagentID: "hook-agent",
            subagentType: "reviewer"
        )
        #expect(store.handleCodexHookEvent(
            sessionID: sessionID,
            event: hookStart,
            at: now.addingTimeInterval(2)
        ))

        #expect(store.handleCodexSubagentRolloutObservation(
            sessionID: sessionID,
            observation: .started(CodexSessionBackgroundActivity(
                activityID: "rollout-agent",
                kind: .subagent,
                displayName: "rollout fallback"
            )),
            at: now.addingTimeInterval(3)
        ))
        let activities = store.sessionRegistry.activeSession(sessionID: sessionID)?
            .backgroundActivitiesByID
        #expect(activities?["hook-agent"]?.displayName == "reviewer")
        #expect(activities?["rollout-agent"]?.displayName == "rollout fallback")

        #expect(store.handleCodexSubagentRolloutObservation(
            sessionID: sessionID,
            observation: .streamReset,
            at: now.addingTimeInterval(4)
        ))
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?
            .backgroundActivitiesByID.isEmpty == true)

        #expect(store.handleCodexHookEvent(
            sessionID: sessionID,
            event: hookStart,
            at: now.addingTimeInterval(5)
        ))
        #expect(store.handleCodexHookEvent(
            sessionID: sessionID,
            event: CodexHookEvent(
                hookEventName: "SubagentStop",
                threadID: nil,
                turnID: nil,
                promptFingerprint: nil,
                status: nil,
                nativeSessionID: nil,
                sessionFilePath: nil,
                cwd: nil,
                subagentID: "hook-agent"
            ),
            at: now.addingTimeInterval(6)
        ))
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?
            .backgroundActivitiesByID["hook-agent"] == nil)
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
