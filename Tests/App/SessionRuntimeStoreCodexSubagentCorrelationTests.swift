import Combine
import CoreState
import Foundation
import Testing
@testable import ToasttyApp

extension SessionRuntimeStoreTests {
    @Test
    func codexSubagentMetadataJoinsBeforeLifecycleStartWithoutCreatingARow() throws {
        let store = SessionRuntimeStore()
        defer { store.reset() }
        let now = Date(timeIntervalSince1970: 1_700_001_260)
        let sessionID = "sess-codex-metadata-before-start"

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
                    toolUseID: "call-spawn",
                    message: "Review security and privacy risks"
                )
            ),
            at: now.addingTimeInterval(1)
        ))
        #expect(store.recordCodexSubagentRolloutStartForTesting(
            sessionID: sessionID,
            toolUseID: "call-spawn",
            agentID: "agent-child",
            displayName: "security_privacy",
            at: now.addingTimeInterval(2)
        ))
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?
            .backgroundActivitiesByID.isEmpty == true)

        #expect(store.handleCodexHookEvent(
            sessionID: sessionID,
            event: CodexHookEvent(
                hookEventName: "SubagentStart",
                threadID: nil,
                turnID: nil,
                promptFingerprint: nil,
                status: nil,
                nativeSessionID: nil,
                sessionFilePath: nil,
                cwd: nil,
                subagentID: "agent-child",
                subagentType: "default"
            ),
            at: now.addingTimeInterval(3)
        ))
        let activity = try #require(store.sessionRegistry.activeSession(sessionID: sessionID)?
            .backgroundActivitiesByID["agent-child"])
        #expect(activity.displayName == "security_privacy")
        #expect(activity.command == "Review security and privacy risks")
    }

    @Test
    func codexSubagentMetadataEnrichesWhenLifecycleArrivesFirst() throws {
        let store = SessionRuntimeStore()
        defer { store.reset() }
        let now = Date(timeIntervalSince1970: 1_700_001_270)
        let sessionID = "sess-codex-start-before-metadata"

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
        #expect(store.handleCodexHookEvent(
            sessionID: sessionID,
            event: CodexHookEvent(
                hookEventName: "SubagentStart",
                threadID: nil,
                turnID: nil,
                promptFingerprint: nil,
                status: nil,
                nativeSessionID: nil,
                sessionFilePath: nil,
                cwd: nil,
                subagentID: "agent-child",
                subagentType: "default"
            ),
            at: now.addingTimeInterval(1)
        ))
        #expect(store.recordCodexSubagentRolloutStartForTesting(
            sessionID: sessionID,
            toolUseID: "call-spawn",
            agentID: "agent-child",
            displayName: "rollout_label",
            at: now.addingTimeInterval(2)
        ))
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?
            .backgroundActivitiesByID["agent-child"]?.displayName == "rollout_label")

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
                    toolUseID: "call-spawn",
                    taskName: "hook_label",
                    message: "Inspect the metadata join"
                )
            ),
            at: now.addingTimeInterval(3)
        ))
        let activity = try #require(store.sessionRegistry.activeSession(sessionID: sessionID)?
            .backgroundActivitiesByID["agent-child"])
        #expect(activity.displayName == "hook_label")
        #expect(activity.command == "Inspect the metadata join")
    }

    @Test
    func codexEncryptedSpawnPayloadProjectsTaskNameWithoutDescription() throws {
        let store = SessionRuntimeStore()
        defer { store.reset() }
        let now = Date(timeIntervalSince1970: 1_700_001_274)
        let sessionID = "sess-codex-encrypted-metadata"
        let workspaceID = UUID()
        // Current Codex builds expose task_name while providing message as an
        // opaque token with this shape in both hook and rollout metadata.
        let encryptedPayload = "gAAAAABqVUYlTXM2t_RUiRJdyhJC7EScV_pvZf4oTf1czpLtlOnI53DmSgBobosvD5"
            + "Be9dNM6WH5zQ6yMDpeYZ2vCxX3NxFWC6mgu-Y0O8lYQO-AQStZWi7216SJYD53GT4jg_KMQxU1ILOdm0eHXkSjWTy"

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
                threadID: nil,
                turnID: nil,
                promptFingerprint: nil,
                status: nil,
                nativeSessionID: nil,
                sessionFilePath: nil,
                cwd: nil,
                subagentID: "agent-child",
                subagentType: "default"
            ),
            at: now.addingTimeInterval(1)
        ))

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
                    toolUseID: "call-spawn",
                    taskName: "native_nav_sort",
                    message: encryptedPayload
                )
            ),
            at: now.addingTimeInterval(2)
        ))
        #expect(store.recordCodexSubagentRolloutStartForTesting(
            sessionID: sessionID,
            toolUseID: "call-spawn",
            agentID: "agent-child",
            displayName: "native_nav_sort",
            at: now.addingTimeInterval(3)
        ))
        let activity = try #require(store.sessionRegistry.activeSession(sessionID: sessionID)?
            .backgroundActivitiesByID["agent-child"])
        #expect(activity.displayName == "native_nav_sort")
        #expect(activity.command == nil)

        let child = try #require(store.workspaceStatuses(
            for: workspaceID,
            at: now.addingTimeInterval(3)
        ).first?.children.first)
        #expect(child.displayName == "native_nav_sort")
        #expect(child.context == nil)
        let hoverTip = SidebarView.sessionChildHoverTipModel(
            child: child,
            workspaceName: nil,
            elapsedText: "2s",
            now: now.addingTimeInterval(3)
        )
        #expect(hoverTip.name == "native_nav_sort")
        #expect(hoverTip.bodyText == nil)

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
                    toolUseID: "call-spawn-2",
                    taskName: encryptedPayload,
                    message: encryptedPayload
                )
            ),
            at: now.addingTimeInterval(4)
        ) == false)
    }

    @Test
    func codexDuplicateSubagentStartPreservesEnrichedDisplayName() throws {
        let store = SessionRuntimeStore()
        defer { store.reset() }
        let now = Date(timeIntervalSince1970: 1_700_001_272)
        let sessionID = "sess-codex-duplicate-start"

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
        func subagentStartEvent(subagentType: String) -> CodexHookEvent {
            CodexHookEvent(
                hookEventName: "SubagentStart",
                threadID: nil,
                turnID: nil,
                promptFingerprint: nil,
                status: nil,
                nativeSessionID: nil,
                sessionFilePath: nil,
                cwd: nil,
                subagentID: "agent-child",
                subagentType: subagentType
            )
        }

        #expect(store.handleCodexHookEvent(
            sessionID: sessionID,
            event: subagentStartEvent(subagentType: "default"),
            at: now.addingTimeInterval(1)
        ))
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?
            .backgroundActivitiesByID["agent-child"]?.displayName == "Sub-agent")

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
                    toolUseID: "call-spawn",
                    taskName: "scroll_implementation",
                    message: "Inspect the scroll implementation"
                )
            ),
            at: now.addingTimeInterval(2)
        ))
        #expect(store.recordCodexSubagentRolloutStartForTesting(
            sessionID: sessionID,
            toolUseID: "call-spawn",
            agentID: "agent-child",
            displayName: "scroll_implementation",
            at: now.addingTimeInterval(3)
        ))
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?
            .backgroundActivitiesByID["agent-child"]?.displayName == "scroll_implementation")

        #expect(store.handleCodexHookEvent(
            sessionID: sessionID,
            event: subagentStartEvent(subagentType: "default"),
            at: now.addingTimeInterval(4)
        ))
        let duplicateStartActivity = try #require(store.sessionRegistry
            .activeSession(sessionID: sessionID)?
            .backgroundActivitiesByID["agent-child"])
        #expect(duplicateStartActivity.displayName == "scroll_implementation")
        #expect(duplicateStartActivity.command == "Inspect the scroll implementation")

        #expect(store.handleCodexHookEvent(
            sessionID: sessionID,
            event: subagentStartEvent(subagentType: "reviewer"),
            at: now.addingTimeInterval(5)
        ))
        let meaningfulTypeActivity = try #require(store.sessionRegistry
            .activeSession(sessionID: sessionID)?
            .backgroundActivitiesByID["agent-child"])
        #expect(meaningfulTypeActivity.displayName == "reviewer")
        #expect(meaningfulTypeActivity.command == "Inspect the scroll implementation")
    }

    @Test
    func codexSubagentMetadataCorrelatesConcurrentSpawnsByToolUseID() throws {
        let store = SessionRuntimeStore()
        defer { store.reset() }
        let now = Date(timeIntervalSince1970: 1_700_001_275)
        let sessionID = "sess-codex-concurrent-metadata"

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

        func recordHook(toolUseID: String, taskName: String, message: String) {
            _ = store.handleCodexHookEvent(
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
                        toolUseID: toolUseID,
                        taskName: taskName,
                        message: message
                    )
                ),
                at: now
            )
        }

        func start(agentID: String) {
            _ = store.handleCodexHookEvent(
                sessionID: sessionID,
                event: CodexHookEvent(
                    hookEventName: "SubagentStart",
                    threadID: nil,
                    turnID: nil,
                    promptFingerprint: nil,
                    status: nil,
                    nativeSessionID: nil,
                    sessionFilePath: nil,
                    cwd: nil,
                    subagentID: agentID,
                    subagentType: "default"
                ),
                at: now
            )
        }

        recordHook(toolUseID: "call-a", taskName: "agent_a", message: "Review A")
        recordHook(toolUseID: "call-b", taskName: "agent_b", message: "Review B")
        _ = store.recordCodexSubagentRolloutStartForTesting(
            sessionID: sessionID,
            toolUseID: "call-b",
            agentID: "agent-b",
            displayName: nil,
            at: now
        )
        _ = store.recordCodexSubagentRolloutStartForTesting(
            sessionID: sessionID,
            toolUseID: "call-a",
            agentID: "agent-a",
            displayName: nil,
            at: now
        )
        start(agentID: "agent-a")
        start(agentID: "agent-b")

        let activities = try #require(store.sessionRegistry.activeSession(sessionID: sessionID)?
            .backgroundActivitiesByID)
        #expect(activities["agent-a"]?.displayName == "agent_a")
        #expect(activities["agent-a"]?.command == "Review A")
        #expect(activities["agent-b"]?.displayName == "agent_b")
        #expect(activities["agent-b"]?.command == "Review B")
    }

    @Test
    func codexSubagentMetadataEvictsOldestUnresolvedCorrelationAtCapacity() throws {
        let store = SessionRuntimeStore()
        defer { store.reset() }
        let now = Date(timeIntervalSince1970: 1_700_001_277)
        let sessionID = "sess-codex-metadata-capacity"

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
        for index in 0...64 {
            _ = store.handleCodexHookEvent(
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
                        toolUseID: "call-\(index)",
                        taskName: "task_\(index)",
                        message: "Description \(index)"
                    )
                ),
                at: now
            )
        }

        _ = store.recordCodexSubagentRolloutStartForTesting(
            sessionID: sessionID,
            toolUseID: "call-0",
            agentID: "agent-oldest",
            displayName: "rollout_oldest",
            at: now
        )
        _ = store.recordCodexSubagentRolloutStartForTesting(
            sessionID: sessionID,
            toolUseID: "call-64",
            agentID: "agent-newest",
            displayName: "rollout_newest",
            at: now
        )
        for agentID in ["agent-oldest", "agent-newest"] {
            _ = store.handleCodexHookEvent(
                sessionID: sessionID,
                event: CodexHookEvent(
                    hookEventName: "SubagentStart",
                    threadID: nil,
                    turnID: nil,
                    promptFingerprint: nil,
                    status: nil,
                    nativeSessionID: nil,
                    sessionFilePath: nil,
                    cwd: nil,
                    subagentID: agentID,
                    subagentType: "default"
                ),
                at: now
            )
        }

        let activities = try #require(store.sessionRegistry.activeSession(sessionID: sessionID)?
            .backgroundActivitiesByID)
        #expect(activities["agent-oldest"]?.displayName == "rollout_oldest")
        #expect(activities["agent-oldest"]?.command == nil)
        #expect(activities["agent-newest"]?.displayName == "task_64")
        #expect(activities["agent-newest"]?.command == "Description 64")
    }

    @Test
    func codexSubagentStopDropsPendingMetadataBeforeAuthoritativeReopen() throws {
        let store = SessionRuntimeStore()
        defer { store.reset() }
        let now = Date(timeIntervalSince1970: 1_700_001_280)
        let sessionID = "sess-codex-stopped-metadata"

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
        _ = store.handleCodexHookEvent(
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
                    toolUseID: "call-stale",
                    taskName: "stale_label",
                    message: "Stale description"
                )
            ),
            at: now.addingTimeInterval(1)
        )
        _ = store.recordCodexSubagentRolloutStartForTesting(
            sessionID: sessionID,
            toolUseID: "call-stale",
            agentID: "agent-child",
            displayName: "stale_label",
            at: now.addingTimeInterval(2)
        )
        _ = store.handleCodexHookEvent(
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
                subagentID: "agent-child",
                subagentType: "default"
            ),
            at: now.addingTimeInterval(3)
        )

        #expect(store.handleCodexHookEvent(
            sessionID: sessionID,
            event: CodexHookEvent(
                hookEventName: "SubagentStart",
                threadID: nil,
                turnID: nil,
                promptFingerprint: nil,
                status: nil,
                nativeSessionID: nil,
                sessionFilePath: nil,
                cwd: nil,
                subagentID: "agent-child",
                subagentType: "default"
            ),
            at: now.addingTimeInterval(4)
        ))
        let activity = try #require(store.sessionRegistry.activeSession(sessionID: sessionID)?
            .backgroundActivitiesByID["agent-child"])
        #expect(activity.displayName == "Sub-agent")
        #expect(activity.command == nil)
    }

    @Test
    func stoppingSessionClearsReducerStateBeforeSessionIDReuse() throws {
        let store = SessionRuntimeStore()
        defer { store.reset() }
        let now = Date(timeIntervalSince1970: 1_700_001_285)
        let sessionID = "sess-codex-reducer-teardown"
        let panelID = UUID()
        let windowID = UUID()
        let workspaceID = UUID()

        func startSession(at date: Date) {
            store.startSession(
                sessionID: sessionID,
                agent: .codex,
                panelID: panelID,
                windowID: windowID,
                workspaceID: workspaceID,
                usesSessionStatusNotifications: true,
                codexStatusTrackingSource: .hooks,
                cwd: "/repo",
                repoRoot: "/repo",
                at: date
            )
        }

        startSession(at: now)
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
                    toolUseID: "reused-call",
                    taskName: "stale task",
                    message: "stale command"
                )
            ),
            at: now.addingTimeInterval(1)
        ))
        store.stopSession(sessionID: sessionID, at: now.addingTimeInterval(2))

        startSession(at: now.addingTimeInterval(3))
        #expect(store.recordCodexSubagentRolloutStartForTesting(
            sessionID: sessionID,
            toolUseID: "reused-call",
            agentID: "agent-child",
            displayName: "fresh rollout",
            at: now.addingTimeInterval(4)
        ))
        #expect(store.handleCodexHookEvent(
            sessionID: sessionID,
            event: CodexHookEvent(
                hookEventName: "SubagentStart",
                threadID: nil,
                turnID: nil,
                promptFingerprint: nil,
                status: nil,
                nativeSessionID: nil,
                sessionFilePath: nil,
                cwd: nil,
                subagentID: "agent-child",
                subagentType: "default"
            ),
            at: now.addingTimeInterval(5)
        ))

        let activity = try #require(store.sessionRegistry.activeSession(sessionID: sessionID)?
            .backgroundActivitiesByID["agent-child"])
        #expect(activity.displayName == "fresh rollout")
        #expect(activity.command == nil)
    }

}

private extension SessionRuntimeStore {
    @discardableResult
    func recordCodexSubagentRolloutStartForTesting(
        sessionID: String,
        toolUseID: String,
        agentID: String,
        displayName: String?,
        at now: Date
    ) -> Bool {
        handleCodexSubagentRolloutObservation(
            sessionID: sessionID,
            observation: .started(CodexSessionBackgroundActivity(
                activityID: agentID,
                hookActivityID: agentID,
                spawnToolUseID: toolUseID,
                kind: .subagent,
                displayName: displayName
            )),
            at: now
        )
    }
}
