import CoreState
import Foundation
import Testing
@testable import ToasttyCLIKit

struct AgentEventParsersTests {
    @Test
    func claudeUserPromptSubmitMapsToWorkingStatus() throws {
        let commands = try AgentEventIngestor.commands(
            for: .claudeHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(#"{"hook_event_name":"UserPromptSubmit","prompt":"summarize skills in here"}"#.utf8)
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .working,
                summary: "Working",
                detail: "summarize skills in here"
            )
        ])
    }

    @Test
    func claudeUserPromptSubmitFallsBackWithoutPromptText() throws {
        let commands = try AgentEventIngestor.commands(
            for: .claudeHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(#"{"hook_event_name":"UserPromptSubmit"}"#.utf8)
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .working,
                summary: "Working",
                detail: "Responding to your prompt"
            )
        ])
    }

    @Test
    func claudeStopMapsToReadyStatusWithAssistantSummary() throws {
        let commands = try AgentEventIngestor.commands(
            for: .claudeHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hook_event_name":"Stop","last_assistant_message":"Updated the sidebar and validated the tests."}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .ready,
                summary: "Ready",
                detail: "Updated the sidebar and validated the tests."
            )
        ])
    }

    @Test
    func claudeStopWithRunningSubagentSyncsBeforeReadyStatus() throws {
        let commands = try AgentEventIngestor.commands(
            for: .claudeHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"Agent launched successfully. Waiting for completion...","background_tasks":[{"id":"a79d12ebe682a90d6","type":"subagent","status":"running","description":"Test background agent sleep command","agent_type":"general-purpose"}],"session_crons":[]}"#.utf8
            )
        )

        #expect(commands == [
            .sessionBackgroundActivitySync(
                sessionID: "sess-123",
                panelID: nil,
                kind: .subagent,
                entries: [
                    SessionBackgroundActivitySyncEntry(
                        id: "a79d12ebe682a90d6",
                        displayName: "general-purpose",
                        command: "Test background agent sleep command"
                    ),
                ],
                pendingBackgroundTaskCount: 0,
                preserveUnlistedActivities: false
            ),
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .ready,
                summary: "Ready",
                detail: "Agent launched successfully. Waiting for completion..."
            ),
        ])
    }

    @Test
    func claudeStopWithRunningWorkflowPreservesLifecycleSubagents() throws {
        let commands = try AgentEventIngestor.commands(
            for: .claudeHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hook_event_name":"Stop","last_assistant_message":"Workflow still running","background_tasks":[{"id":"workflow-1","type":"workflow","status":"running","description":"Review the diff"}]}"#.utf8
            )
        )

        #expect(commands == [
            .sessionBackgroundActivitySync(
                sessionID: "sess-123",
                panelID: nil,
                kind: .subagent,
                entries: [],
                pendingBackgroundTaskCount: 1,
                preserveUnlistedActivities: true
            ),
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .ready,
                summary: "Ready",
                detail: "Workflow still running"
            ),
        ])
    }

    @Test
    func claudeStopWithOnlyShellTasksSyncsPendingCount() throws {
        let commands = try AgentEventIngestor.commands(
            for: .claudeHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hook_event_name":"Stop","last_assistant_message":"Shell still running","background_tasks":[{"id":"shell-1","type":"shell","status":"running","description":"npm test"}]}"#.utf8
            )
        )

        #expect(commands == [
            .sessionBackgroundActivitySync(
                sessionID: "sess-123",
                panelID: nil,
                kind: .subagent,
                entries: [],
                pendingBackgroundTaskCount: 1,
                preserveUnlistedActivities: false
            ),
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .ready,
                summary: "Ready",
                detail: "Shell still running"
            ),
        ])
    }

    @Test
    func claudeStopWithEmptyBackgroundTasksClearsSync() throws {
        let commands = try AgentEventIngestor.commands(
            for: .claudeHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hook_event_name":"Stop","last_assistant_message":"DONE-ALL","background_tasks":[]}"#.utf8
            )
        )

        #expect(commands == [
            .sessionBackgroundActivitySync(
                sessionID: "sess-123",
                panelID: nil,
                kind: .subagent,
                entries: [],
                pendingBackgroundTaskCount: 0,
                preserveUnlistedActivities: false
            ),
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .ready,
                summary: "Ready",
                detail: "DONE-ALL"
            ),
        ])
    }

    @Test
    func claudePermissionRequestMapsToNeedsApprovalStatus() throws {
        let commands = try AgentEventIngestor.commands(
            for: .claudeHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hook_event_name":"PermissionRequest","message":"Need approval to run npm test"}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .needsApproval,
                summary: "Needs approval",
                detail: "Need approval to run npm test"
            )
        ])
    }

    @Test
    func claudePreToolUseMapsToWorkingToolStatus() throws {
        let commands = try AgentEventIngestor.commands(
            for: .claudeHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"npm test"}}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .working,
                summary: "Working",
                detail: "Running npm test"
            )
        ])
    }

    @Test
    func claudePostToolUseHooksAreIgnored() throws {
        let postCommands = try AgentEventIngestor.commands(
            for: .claudeHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(#"{"hook_event_name":"PostToolUse","tool_name":"Bash"}"#.utf8)
        )
        let failureCommands = try AgentEventIngestor.commands(
            for: .claudeHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(#"{"hook_event_name":"PostToolUseFailure","tool_name":"Bash"}"#.utf8)
        )

        #expect(postCommands.isEmpty)
        #expect(failureCommands.isEmpty)
    }

    @Test
    func claudeForegroundAgentPostToolUseIsIgnored() throws {
        let commands = try AgentEventIngestor.commands(
            for: .claudeHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"description":"Foreground agent","subagent_type":"general-purpose"},"tool_response":{"description":"Foreground agent done"}}"#.utf8
            )
        )

        #expect(commands.isEmpty)
    }

    @Test
    func claudeAgentPostToolUseAsyncLaunchStartsSubagentActivity() throws {
        let commands = try AgentEventIngestor.commands(
            for: .claudeHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"description":"Test background agent sleep command","prompt":"...","run_in_background":true,"subagent_type":"general-purpose"},"tool_response":{"agentId":"a79d12ebe682a90d6","canReadOutputFile":false,"description":"Test background agent sleep command","isAsync":true,"outputFile":"/path","prompt":"...","resolvedModel":"claude-haiku-4-5-20251001","status":"async_launched"}}"#.utf8
            )
        )

        #expect(commands == [
            .sessionBackgroundActivity(
                sessionID: "sess-123",
                panelID: nil,
                phase: .start,
                activityID: "a79d12ebe682a90d6",
                kind: .subagent,
                displayName: "general-purpose",
                command: "Test background agent sleep command",
                processID: nil,
                preserveWhenUnlisted: false
            ),
        ])
    }

    @Test
    func claudeTaskPostToolUseAsyncLaunchStartsSubagentActivity() throws {
        let commands = try AgentEventIngestor.commands(
            for: .claudeHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hook_event_name":"PostToolUse","tool_name":"Task","tool_input":{"description":"Ask a task","subagent_type":"reviewer"},"tool_response":{"agentId":"task-agent-1","status":"async_launched"}}"#.utf8
            )
        )

        #expect(commands == [
            .sessionBackgroundActivity(
                sessionID: "sess-123",
                panelID: nil,
                phase: .start,
                activityID: "task-agent-1",
                kind: .subagent,
                displayName: "reviewer",
                command: "Ask a task",
                processID: nil,
                preserveWhenUnlisted: false
            ),
        ])
    }

    @Test
    func claudeSubagentStartCreatesGenericActivityFromLifecycleIdentity() throws {
        let commands = try AgentEventIngestor.commands(
            for: .claudeHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hook_event_name":"SubagentStart","agent_id":"workflow-agent-1","agent_type":"workflow-subagent"}"#.utf8
            )
        )

        #expect(commands == [
            .sessionBackgroundActivity(
                sessionID: "sess-123",
                panelID: nil,
                phase: .start,
                activityID: "workflow-agent-1",
                kind: .subagent,
                displayName: nil,
                command: nil,
                processID: nil,
                preserveWhenUnlisted: true
            ),
        ])
    }

    @Test
    func claudeSubagentStopFinishesSubagentActivity() throws {
        let commands = try AgentEventIngestor.commands(
            for: .claudeHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hook_event_name":"SubagentStop","agent_id":"a79d12ebe682a90d6","agent_type":"general-purpose","agent_transcript_path":"/path","last_assistant_message":"done","background_tasks":[{"id":"a79d12ebe682a90d6","type":"subagent","status":"running","description":"...","agent_type":"general-purpose"}]}"#.utf8
            )
        )

        #expect(commands == [
            .sessionBackgroundActivity(
                sessionID: "sess-123",
                panelID: nil,
                phase: .finish,
                activityID: "a79d12ebe682a90d6",
                kind: .subagent,
                displayName: nil,
                command: nil,
                processID: nil,
                preserveWhenUnlisted: false
            ),
        ])
    }

    @Test
    func claudeSubagentLifecycleWithoutAgentIDIsIgnored() throws {
        let startCommands = try AgentEventIngestor.commands(
            for: .claudeHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(#"{"hook_event_name":"SubagentStart","agent_type":"workflow-subagent"}"#.utf8)
        )
        let stopCommands = try AgentEventIngestor.commands(
            for: .claudeHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(#"{"hook_event_name":"SubagentStop","agent_type":"workflow-subagent"}"#.utf8)
        )

        #expect(startCommands.isEmpty)
        #expect(stopCommands.isEmpty)
    }

    @Test
    func claudeSubagentStartIgnoresNonWorkflowSubagents() throws {
        let commands = try AgentEventIngestor.commands(
            for: .claudeHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hook_event_name":"SubagentStart","agent_id":"regular-agent-1","agent_type":"general-purpose"}"#.utf8
            )
        )

        #expect(commands.isEmpty)
    }

    @Test
    func claudePostToolUseDoesNotUpdateResumeRecordFromCommonMetadata() throws {
        let panelID = UUID()
        let commands = try AgentEventIngestor.commands(
            for: .claudeHooks,
            sessionID: "sess-123",
            panelID: panelID,
            payload: Data(
                #"{"hook_event_name":"PostToolUse","session_id":"claude-root","transcript_path":"/tmp/claude/session.jsonl","cwd":"/tmp/repo","tool_name":"Read"}"#.utf8
            )
        )

        #expect(commands.isEmpty)
    }

    @Test
    func claudeNotificationIdlePromptMapsToReadyStatus() throws {
        let commands = try AgentEventIngestor.commands(
            for: .claudeHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"Claude is waiting for your response"}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .ready,
                summary: "Ready",
                detail: "Claude is waiting for your response"
            )
        ])
    }

    @Test
    func claudeNotificationIdlePromptFallsBackWithoutMessage() throws {
        let commands = try AgentEventIngestor.commands(
            for: .claudeHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hook_event_name":"Notification","notification_type":"idle_prompt"}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .ready,
                summary: "Ready",
                detail: "Waiting for input"
            )
        ])
    }

    @Test
    func claudeNotificationPermissionPromptMapsToNeedsApprovalStatus() throws {
        let commands = try AgentEventIngestor.commands(
            for: .claudeHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Need approval to exit plan mode"}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .needsApproval,
                summary: "Needs approval",
                detail: "Need approval to exit plan mode"
            )
        ])
    }

    @Test
    func claudeNotificationPermissionPromptFallsBackWithoutMessage() throws {
        let commands = try AgentEventIngestor.commands(
            for: .claudeHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hook_event_name":"Notification","notification_type":"permission_prompt"}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .needsApproval,
                summary: "Needs approval",
                detail: "Claude Code is waiting for approval"
            )
        ])
    }

    @Test
    func claudeNotificationElicitationDialogMapsToNeedsInputStatus() throws {
        let commands = try AgentEventIngestor.commands(
            for: .claudeHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hook_event_name":"Notification","notification_type":"elicitation_dialog","message":"Choose a target project"}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .needsApproval,
                summary: "Needs input",
                detail: "Choose a target project"
            )
        ])
    }

    @Test
    func claudeNotificationAuthSuccessIsIgnored() throws {
        let commands = try AgentEventIngestor.commands(
            for: .claudeHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hook_event_name":"Notification","notification_type":"auth_success","message":"Signed in"}"#.utf8
            )
        )

        #expect(commands.isEmpty)
    }

    @Test
    func claudeNotificationUnknownTypeIsIgnored() throws {
        let commands = try AgentEventIngestor.commands(
            for: .claudeHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hook_event_name":"Notification","notification_type":"some_other_type","message":"Something happened"}"#.utf8
            )
        )

        #expect(commands.isEmpty)
    }

    @Test
    func claudeSessionStartHookMapsToResumeRecordUpdate() throws {
        let panelID = UUID()
        let commands = try AgentEventIngestor.commands(
            for: .claudeHooks,
            sessionID: "sess-123",
            panelID: panelID,
            payload: Data(
                #"{"hook_event_name":"SessionStart","session_id":"claude-root","transcript_path":"/tmp/claude/session.jsonl","cwd":"/tmp/repo"}"#.utf8
            )
        )

        #expect(commands == [
            .sessionUpdateResumeRecord(
                sessionID: "sess-123",
                panelID: panelID,
                agent: .claude,
                nativeSessionID: "claude-root",
                sessionFilePath: "/tmp/claude/session.jsonl",
                cwd: "/tmp/repo"
            ),
        ])
    }

    @Test
    func claudeSessionStartHookAllowsMissingCwdForAppFallback() throws {
        let panelID = UUID()
        let commands = try AgentEventIngestor.commands(
            for: .claudeHooks,
            sessionID: "sess-123",
            panelID: panelID,
            payload: Data(
                #"{"hook_event_name":"SessionStart","session_id":"claude-root","transcript_path":"/tmp/claude/session.jsonl"}"#.utf8
            )
        )

        #expect(commands == [
            .sessionUpdateResumeRecord(
                sessionID: "sess-123",
                panelID: panelID,
                agent: .claude,
                nativeSessionID: "claude-root",
                sessionFilePath: "/tmp/claude/session.jsonl",
                cwd: nil
            ),
        ])
    }

    @Test
    func claudeResumeRecordUpdateRequiresPanelID() throws {
        let commands = try AgentEventIngestor.commands(
            for: .claudeHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hook_event_name":"SessionStart","session_id":"claude-root","transcript_path":"/tmp/claude/session.jsonl","cwd":"/tmp/repo"}"#.utf8
            )
        )

        #expect(commands.isEmpty)
    }

    @Test
    func codexTurnCompletePreservesThreadIdentityForAppFiltering() throws {
        let commands = try AgentEventIngestor.commands(
            for: .codexNotify,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"type":"agent-turn-complete","thread-id":"thread-root","turn-id":"turn-1","input-messages":["Fix the sidebar"],"last-assistant-message":"Finished updating the launch path."}"#.utf8
            )
        )

        #expect(commands == [
            .sessionCodexNotifyCompletion(
                sessionID: "sess-123",
                panelID: nil,
                completion: CodexNotifyCompletion(
                    notificationType: "agent-turn-complete",
                    threadID: "thread-root",
                    turnID: "turn-1",
                    lastInputMessageFingerprint: CodexInputFingerprint.fingerprint(for: "Fix the sidebar"),
                    inputMessageCount: 1,
                    detail: "Finished updating the launch path."
                )
            )
        ])
    }

    @Test
    func codexTaskCompleteUsesNotifyCompletionFallback() throws {
        let commands = try AgentEventIngestor.commands(
            for: .codexNotify,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"type":"task_complete","last_agent_message":"Finished updating the launch path."}"#.utf8
            )
        )

        #expect(commands == [
            .sessionCodexNotifyCompletion(
                sessionID: "sess-123",
                panelID: nil,
                completion: CodexNotifyCompletion(
                    notificationType: "task_complete",
                    threadID: nil,
                    turnID: nil,
                    lastInputMessageFingerprint: nil,
                    inputMessageCount: 0,
                    detail: "Finished updating the launch path."
                )
            )
        ])
    }

    @Test
    func codexUserPromptSubmitHookMapsToThreadedWorkingEvent() throws {
        let commands = try AgentEventIngestor.commands(
            for: .codexHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hook_event_name":"UserPromptSubmit","session_id":"thread-root","turn_id":"turn-1","prompt":"Fix Codex hooks"}"#.utf8
            )
        )

        #expect(commands == [
            .sessionCodexHookEvent(
                sessionID: "sess-123",
                panelID: nil,
                event: CodexHookEvent(
                    hookEventName: "UserPromptSubmit",
                    threadID: "thread-root",
                    turnID: "turn-1",
                    promptFingerprint: CodexInputFingerprint.fingerprint(for: "Fix Codex hooks"),
                    status: SessionStatus(kind: .working, summary: "Working", detail: "Fix Codex hooks"),
                    nativeSessionID: "thread-root",
                    sessionFilePath: nil,
                    cwd: nil
                )
            ),
        ])
    }

    @Test
    func codexPermissionRequestHookMapsToApprovalStatus() throws {
        let commands = try AgentEventIngestor.commands(
            for: .codexHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hook_event_name":"PermissionRequest","permission_mode":"default","session_id":"thread-root","turn_id":"turn-root","tool_name":"Bash","tool_input":{"command":"git status --short"}}"#.utf8
            )
        )

        #expect(commands == [
            .sessionCodexHookEvent(
                sessionID: "sess-123",
                panelID: nil,
                event: CodexHookEvent(
                    hookEventName: "PermissionRequest",
                    permissionMode: "default",
                    threadID: "thread-root",
                    turnID: "turn-root",
                    promptFingerprint: nil,
                    status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve git status --short"),
                    nativeSessionID: "thread-root",
                    sessionFilePath: nil,
                    cwd: nil
                )
            ),
        ])

        guard case .sessionCodexHookEvent(_, _, let event) = try #require(commands.first) else {
            Issue.record("Expected Codex hook event")
            return
        }
        // Codex's current PermissionRequest hook payload normally omits all
        // operation identifiers. Preserve that absence rather than deriving one.
        #expect(event.toolUseID == nil)
        #expect(event.callID == nil)
        #expect(event.approvalID == nil)
    }

    @Test
    func codexHookPreservesIndependentOperationIdentifiersInEnvelope() throws {
        let commands = try AgentEventIngestor.commands(
            for: .codexHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hook_event_name":"PermissionRequest","session_id":"thread-root","tool_use_id":" tool-1 ","call_id":" call-1 ","approval_id":" approval-1 "}"#.utf8
            )
        )

        guard case .sessionCodexHookEvent(_, _, let event) = try #require(commands.first) else {
            Issue.record("Expected Codex hook event")
            return
        }
        #expect(event.toolUseID == "tool-1")
        #expect(event.callID == "call-1")
        #expect(event.approvalID == "approval-1")

        let envelope = try #require(commands.first?.makeEventEnvelope())
        #expect(envelope.payload.string("toolUseID") == "tool-1")
        #expect(envelope.payload.string("callID") == "call-1")
        #expect(envelope.payload.string("approvalID") == "approval-1")
    }

    @Test
    func codexPreToolUseHookMapsToWorkingToolStatus() throws {
        let commands = try AgentEventIngestor.commands(
            for: .codexHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hook_event_name":"PreToolUse","session_id":"thread-root","tool_name":"Bash","tool_input":{"command":"git status --short"}}"#.utf8
            )
        )

        #expect(commands == [
            .sessionCodexHookEvent(
                sessionID: "sess-123",
                panelID: nil,
                event: CodexHookEvent(
                    hookEventName: "PreToolUse",
                    threadID: "thread-root",
                    turnID: nil,
                    promptFingerprint: nil,
                    status: SessionStatus(kind: .working, summary: "Working", detail: "Running git status --short"),
                    nativeSessionID: "thread-root",
                    sessionFilePath: nil,
                    cwd: nil
                )
            ),
        ])
    }

    @Test
    func codexSpawnPreToolUseHookCarriesCorrelationMetadata() throws {
        let commands = try AgentEventIngestor.commands(
            for: .codexHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hook_event_name":"PreToolUse","session_id":"thread-root","tool_name":"collaborationspawn_agent","tool_use_id":"call-spawn","tool_input":{"task_name":"security_privacy","message":"Review the security and privacy implications"}}"#.utf8
            )
        )

        guard case .sessionCodexHookEvent(_, _, let event) = try #require(commands.first) else {
            Issue.record("Expected Codex hook event")
            return
        }
        #expect(event.spawnMetadata == CodexSpawnHookMetadata(
            toolUseID: "call-spawn",
            taskName: "security_privacy",
            message: "Review the security and privacy implications"
        ))
        #expect(event.toolUseID == "call-spawn")

        let envelope = try #require(commands.first?.makeEventEnvelope())
        #expect(envelope.payload.string("toolUseID") == "call-spawn")
        #expect(envelope.payload.string("spawnToolUseID") == "call-spawn")
        #expect(envelope.payload.string("spawnTaskName") == "security_privacy")
        #expect(envelope.payload.string("spawnMessage") == "Review the security and privacy implications")
    }

    @Test
    func codexSubagentStartHookMapsLifecycleIdentity() throws {
        let commands = try AgentEventIngestor.commands(
            for: .codexHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hook_event_name":"SubagentStart","session_id":"thread-root","turn_id":"turn-root","agent_id":"agent-child","agent_type":"reviewer"}"#.utf8
            )
        )

        #expect(commands == [
            .sessionCodexHookEvent(
                sessionID: "sess-123",
                panelID: nil,
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
                )
            ),
        ])
        let envelope = try #require(commands.first?.makeEventEnvelope())
        #expect(envelope.eventType == "session.codex_hook_event")
        #expect(envelope.payload.string("subagentID") == "agent-child")
        #expect(envelope.payload.string("subagentType") == "reviewer")
    }

    @Test
    func codexSubagentStopHookMapsLifecycleIdentity() throws {
        let commands = try AgentEventIngestor.commands(
            for: .codexHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hook_event_name":"SubagentStop","session_id":"thread-root","turn_id":"turn-root","agent_id":"agent-child","agent_type":"reviewer","agent_transcript_path":"/tmp/child.jsonl"}"#.utf8
            )
        )

        guard case .sessionCodexHookEvent(_, _, let event) = try #require(commands.first) else {
            Issue.record("Expected Codex hook event")
            return
        }
        #expect(commands.count == 1)
        #expect(event.hookEventName == "SubagentStop")
        #expect(event.threadID == "thread-root")
        #expect(event.subagentID == "agent-child")
        #expect(event.subagentType == "reviewer")
    }

    @Test
    func codexPostToolUseHookIsIgnored() throws {
        let postCommands = try AgentEventIngestor.commands(
            for: .codexHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hook_event_name":"PostToolUse","session_id":"thread-root","tool_name":"Bash","tool_input":{"command":"git status --short"}}"#.utf8
            )
        )
        let failureCommands = try AgentEventIngestor.commands(
            for: .codexHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hook_event_name":"PostToolUseFailure","session_id":"thread-root","tool_name":"Bash","tool_input":{"command":"git status --short"}}"#.utf8
            )
        )

        #expect(postCommands.isEmpty)
        #expect(failureCommands.isEmpty)
    }

    @Test
    func codexStopHookMapsToReadyStatus() throws {
        let commands = try AgentEventIngestor.commands(
            for: .codexHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hook_event_name":"Stop","session_id":"thread-root","last_assistant_message":"Updated the hook installer."}"#.utf8
            )
        )

        #expect(commands == [
            .sessionCodexHookEvent(
                sessionID: "sess-123",
                panelID: nil,
                event: CodexHookEvent(
                    hookEventName: "Stop",
                    threadID: "thread-root",
                    turnID: nil,
                    promptFingerprint: nil,
                    status: SessionStatus(kind: .ready, summary: "Ready", detail: "Updated the hook installer."),
                    nativeSessionID: "thread-root",
                    sessionFilePath: nil,
                    cwd: nil
                )
            ),
        ])
    }

    @Test
    func codexSessionStartHookMapsToHookEvent() throws {
        let panelID = UUID()
        let commands = try AgentEventIngestor.commands(
            for: .codexHooks,
            sessionID: "sess-123",
            panelID: panelID,
            payload: Data(
                #"{"hook_event_name":"SessionStart","source":"startup","session_id":"thread-root","transcript_path":"/tmp/codex/session.jsonl","cwd":"/tmp/repo"}"#.utf8
            )
        )

        #expect(commands == [
            .sessionCodexHookEvent(
                sessionID: "sess-123",
                panelID: panelID,
                event: CodexHookEvent(
                    hookEventName: "SessionStart",
                    source: "startup",
                    threadID: "thread-root",
                    turnID: nil,
                    promptFingerprint: nil,
                    status: nil,
                    nativeSessionID: "thread-root",
                    sessionFilePath: "/tmp/codex/session.jsonl",
                    cwd: "/tmp/repo"
                )
            ),
        ])
    }

    @Test
    func codexHookParserAcceptsLargePayloads() throws {
        let prompt = String(repeating: "x", count: 70 * 1024)
        let payload = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "UserPromptSubmit",
            "session_id": "thread-root",
            "prompt": prompt,
        ])

        let commands = try AgentEventIngestor.commands(
            for: .codexHooks,
            sessionID: "sess-large-hook",
            panelID: nil,
            payload: payload
        )

        let command = try #require(commands.first)
        guard case .sessionCodexHookEvent(_, _, let event) = command else {
            #expect(Bool(false))
            return
        }
        #expect(commands.count == 1)
        #expect(event.threadID == "thread-root")
        #expect(event.promptFingerprint == CodexInputFingerprint.fingerprint(for: prompt))
        #expect(event.status?.detail?.hasSuffix("...") == true)
    }

    @Test
    func piNativeSessionEventMapsToResumeRecordUpdate() throws {
        let panelID = UUID()
        let commands = try AgentEventIngestor.commands(
            for: .piExtension,
            sessionID: "sess-123",
            panelID: panelID,
            payload: Data(
                #"{"source":"pi-extension","version":1,"toasttySessionID":"sess-123","event":"native_session","nativeSessionID":"019e31af-e0ed-718b-a695-37afddc7e494","sessionFilePath":"/tmp/pi sessions/session.jsonl","cwd":"/tmp/repo with spaces"}"#.utf8
            )
        )

        #expect(commands == [
            .sessionUpdateResumeRecord(
                sessionID: "sess-123",
                panelID: panelID,
                agent: .pi,
                nativeSessionID: "019e31af-e0ed-718b-a695-37afddc7e494",
                sessionFilePath: "/tmp/pi sessions/session.jsonl",
                cwd: "/tmp/repo with spaces"
            ),
        ])
    }

    @Test
    func piNativeSessionEventIgnoresIncompleteMetadata() throws {
        let commands = try AgentEventIngestor.commands(
            for: .piExtension,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"source":"pi-extension","version":1,"toasttySessionID":"sess-123","event":"native_session","nativeSessionID":"019e31af-e0ed-718b-a695-37afddc7e494","cwd":"/tmp/repo"}"#.utf8
            )
        )

        #expect(commands.isEmpty)
    }

    @Test
    func piNativeSessionEventRequiresPanelID() throws {
        let commands = try AgentEventIngestor.commands(
            for: .piExtension,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"source":"pi-extension","version":1,"toasttySessionID":"sess-123","event":"native_session","nativeSessionID":"019e31af-e0ed-718b-a695-37afddc7e494","sessionFilePath":"/tmp/session.jsonl","cwd":"/tmp/repo"}"#.utf8
            )
        )

        #expect(commands.isEmpty)
    }

    @Test
    func piAgentStartMapsToWorkingStatus() throws {
        let commands = try AgentEventIngestor.commands(
            for: .piExtension,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"source":"pi-extension","version":1,"toasttySessionID":"sess-123","event":"agent_start"}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .working,
                summary: "Working",
                detail: "Pi is responding"
            )
        ])
    }

    @Test
    func piAgentStartUsesProvidedDetailWhenAvailable() throws {
        let commands = try AgentEventIngestor.commands(
            for: .piExtension,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"source":"pi-extension","version":1,"toasttySessionID":"sess-123","event":"agent_start","detail":"Summarize the issue"}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .working,
                summary: "Working",
                detail: "Summarize the issue"
            )
        ])
    }

    @Test
    func piBeforeAgentStartMapsPromptToWorkingStatus() throws {
        let commands = try AgentEventIngestor.commands(
            for: .piExtension,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"source":"pi-extension","version":1,"toasttySessionID":"sess-123","event":"before_agent_start","prompt":"Investigate the Pi sidebar status updates"}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .working,
                summary: "Working",
                detail: "Investigate the Pi sidebar status updates"
            )
        ])
    }

    @Test
    func piToolCallUsesSemanticDetailAndChangedFiles() throws {
        let commands = try AgentEventIngestor.commands(
            for: .piExtension,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"source":"pi-extension","version":1,"toasttySessionID":"sess-123","event":"tool_call","toolName":"grep","detail":"Searching for AgentKind","files":["Sources/Core/Sessions"]}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .working,
                summary: "Working",
                detail: "Searching for AgentKind"
            ),
            .sessionUpdateFiles(
                sessionID: "sess-123",
                panelID: nil,
                files: ["Sources/Core/Sessions"],
                cwd: nil,
                repoRoot: nil
            ),
        ])
    }

    @Test
    func piSuccessfulToolResultOnlyUpdatesChangedFiles() throws {
        let commands = try AgentEventIngestor.commands(
            for: .piExtension,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"source":"pi-extension","version":1,"toasttySessionID":"sess-123","event":"tool_result","toolName":"edit","files":["Sources/App/ToasttyApp.swift","Sources/App/ToasttyApp.swift"],"isError":false}"#.utf8
            )
        )

        #expect(commands == [
            .sessionUpdateFiles(
                sessionID: "sess-123",
                panelID: nil,
                files: ["Sources/App/ToasttyApp.swift"],
                cwd: nil,
                repoRoot: nil
            ),
        ])
    }

    @Test
    func piFailedToolResultMapsToFailureStatus() throws {
        let commands = try AgentEventIngestor.commands(
            for: .piExtension,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"source":"pi-extension","version":1,"toasttySessionID":"sess-123","event":"tool_result","toolName":"bash","isError":true}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .working,
                summary: "Working",
                detail: "Bash failed"
            )
        ])
    }

    @Test
    func piAgentEndMapsAssistantSummaryToReadyStatus() throws {
        let commands = try AgentEventIngestor.commands(
            for: .piExtension,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"source":"pi-extension","version":1,"toasttySessionID":"sess-123","event":"agent_end","summary":"Updated the Pi sidebar status behavior."}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .ready,
                summary: "Ready",
                detail: "Updated the Pi sidebar status behavior."
            )
        ])
    }

    @Test
    func piAgentEndClearsTurnCompleteDetail() throws {
        let commands = try AgentEventIngestor.commands(
            for: .piExtension,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"source":"pi-extension","version":1,"toasttySessionID":"sess-123","event":"agent_end"}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .ready,
                summary: "Ready",
                detail: nil
            )
        ])
    }

    @Test
    func piExtensionRejectsOversizedPayload() throws {
        let payload = Data(String(repeating: "x", count: 64 * 1024 + 1).utf8)

        #expect(throws: PiExtensionEventParserError.payloadTooLarge) {
            _ = try AgentEventIngestor.commands(
                for: .piExtension,
                sessionID: "sess-123",
                panelID: nil,
                payload: payload
            )
        }
    }

    @Test
    func piExtensionIgnoresMissingOrMismatchedSessionRecords() throws {
        let commands = try AgentEventIngestor.commands(
            for: .piExtension,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"source":"pi-extension","version":1,"toasttySessionID":"other-session","event":"agent_start"}"#.utf8
            )
        )

        #expect(commands.isEmpty)
    }

    @Test
    func opencodeStatusBusyMapsToWorkingStatus() throws {
        let commands = try AgentEventIngestor.commands(
            for: .opencodePlugin,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"type":"session.status","properties":{"sessionID":"ses_provider","status":{"type":"busy"}}}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .working,
                summary: "Working",
                detail: nil
            )
        ])
    }

    @Test
    func opencodeNativeSessionEventMapsToResumeRecordUpdate() throws {
        let panelID = UUID()
        let commands = try AgentEventIngestor.commands(
            for: .opencodePlugin,
            sessionID: "sess-123",
            panelID: panelID,
            payload: Data(
                #"{"type":"toastty.native_session","properties":{"nativeSessionID":"ses_provider","sessionFilePath":"/tmp/toastty/managed-agent-resume/opencode-plugin-ses_provider.json","cwd":"/tmp/repo"}}"#.utf8
            )
        )

        #expect(commands == [
            .sessionUpdateResumeRecord(
                sessionID: "sess-123",
                panelID: panelID,
                agent: .opencode,
                nativeSessionID: "ses_provider",
                sessionFilePath: "/tmp/toastty/managed-agent-resume/opencode-plugin-ses_provider.json",
                cwd: "/tmp/repo"
            ),
        ])
    }

    @Test
    func mimocodeNativeSessionEventMapsToResumeRecordUpdate() throws {
        let panelID = UUID()
        let commands = try AgentEventIngestor.commands(
            for: .mimocodePlugin,
            sessionID: "sess-123",
            panelID: panelID,
            payload: Data(
                #"{"type":"toastty.native_session","properties":{"nativeSessionID":"ses_mimo","sentinelPath":"/tmp/toastty/managed-agent-resume/mimocode-plugin-ses_mimo.json","cwd":"/tmp/repo"}}"#.utf8
            )
        )

        #expect(commands == [
            .sessionUpdateResumeRecord(
                sessionID: "sess-123",
                panelID: panelID,
                agent: .mimocode,
                nativeSessionID: "ses_mimo",
                sessionFilePath: "/tmp/toastty/managed-agent-resume/mimocode-plugin-ses_mimo.json",
                cwd: "/tmp/repo"
            ),
        ])
    }

    @Test
    func opencodeNativeSessionEventRequiresPanelID() throws {
        let commands = try AgentEventIngestor.commands(
            for: .opencodePlugin,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"type":"toastty.native_session","properties":{"nativeSessionID":"ses_provider","sessionFilePath":"/tmp/marker.json","cwd":"/tmp/repo"}}"#.utf8
            )
        )

        #expect(commands.isEmpty)
    }

    @Test
    func opencodeNormalizedToolStatusMapsToWorkingStatus() throws {
        let commands = try AgentEventIngestor.commands(
            for: .opencodePlugin,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"type":"toastty.status","properties":{"kind":"working","summary":"Working","detail":"Bash completed"}}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .working,
                summary: "Working",
                detail: "Bash completed"
            )
        ])
    }

    @Test
    func mimocodeNormalizedFinalMapsToReadyStatusWithResponseText() throws {
        let commands = try AgentEventIngestor.commands(
            for: .mimocodePlugin,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"type":"toastty.final","properties":{"text":"Done editing files."}}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .ready,
                summary: "Ready",
                detail: "Done editing files."
            )
        ])
    }

    @Test
    func opencodeNormalizedApprovalStatusMapsToNeedsApproval() throws {
        let commands = try AgentEventIngestor.commands(
            for: .opencodePlugin,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"type":"toastty.status","properties":{"kind":"needs_approval","summary":"Needs approval","detail":"Approve git status"}}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .needsApproval,
                summary: "Needs approval",
                detail: "Approve git status"
            )
        ])
    }

    @Test
    func mimocodeStatusBusyUsesOptionalMessage() throws {
        let commands = try AgentEventIngestor.commands(
            for: .mimocodePlugin,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"event":{"type":"session.status","properties":{"sessionID":"ses_provider","status":{"type":"busy","message":"Editing files"}}}}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .working,
                summary: "Working",
                detail: "Editing files"
            )
        ])
    }

    @Test
    func opencodeStatusRetryMapsToRetryingStatus() throws {
        let commands = try AgentEventIngestor.commands(
            for: .opencodePlugin,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"type":"session.status","properties":{"status":{"type":"retry","attempt":2,"message":"Provider overloaded","next":1500}}}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .working,
                summary: "Retrying",
                detail: "Provider overloaded"
            )
        ])
    }

    @Test
    func opencodeIdleEventsMapToReadyStatus() throws {
        let commands = try AgentEventIngestor.commands(
            for: .opencodePlugin,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(#"{"type":"session.idle","properties":{"sessionID":"ses_provider"}}"#.utf8)
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .ready,
                summary: "Ready",
                detail: nil
            )
        ])
    }

    @Test
    func opencodePermissionAskedMapsToApprovalStatus() throws {
        let commands = try AgentEventIngestor.commands(
            for: .opencodePlugin,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"type":"permission.asked","properties":{"id":"per_123","sessionID":"ses_provider","permission":"bash","patterns":["git status"],"metadata":{"tool":"bash","input":{"command":"git status --short"}},"always":[]}}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .needsApproval,
                summary: "Needs approval",
                detail: "Approve git status --short"
            )
        ])
    }

    @Test
    func opencodePermissionRepliedClearsApprovalStatus() throws {
        let commands = try AgentEventIngestor.commands(
            for: .opencodePlugin,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"type":"permission.replied","properties":{"sessionID":"ses_provider","requestID":"per_123","reply":"once"}}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .working,
                summary: "Working",
                detail: "Approval resolved"
            )
        ])
    }

    @Test
    func opencodeSessionErrorMapsToErrorStatus() throws {
        let commands = try AgentEventIngestor.commands(
            for: .opencodePlugin,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"type":"session.error","properties":{"sessionID":"ses_provider","error":{"name":"ProviderError","data":{"message":"rate limited"}}}}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .error,
                summary: "Error",
                detail: "rate limited"
            )
        ])
    }

    @Test
    func opencodeFamilyParserRejectsOversizedPayload() throws {
        let payload = Data(String(repeating: "x", count: 64 * 1024 + 1).utf8)

        #expect(throws: OpenCodeFamilyEventParserError.payloadTooLarge) {
            _ = try AgentEventIngestor.commands(
                for: .opencodePlugin,
                sessionID: "sess-123",
                panelID: nil,
                payload: payload
            )
        }
    }

    // MARK: - Grok hooks

    @Test
    func grokEncodedSessionCwdFolderNamePercentEncodesSlashes() {
        #expect(
            GrokHookEventParser.encodedSessionCwdFolderName("/private/tmp/foo")
                == "%2Fprivate%2Ftmp%2Ffoo"
        )
        #expect(
            GrokHookEventParser.encodedSessionCwdFolderName("/private/tmp/toastty-grok-spike-12593")
                == "%2Fprivate%2Ftmp%2Ftoastty-grok-spike-12593"
        )
    }

    @Test
    func grokUserPromptSubmitMapsToWorkingStatus() throws {
        let commands = try AgentEventIngestor.commands(
            for: .grokHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hookEventName":"user_prompt_submit","sessionId":"native-1","prompt":"summarize the workspace"}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .working,
                summary: "Working",
                detail: "summarize the workspace"
            ),
        ])
    }

    @Test
    func grokUserPromptSubmitStripsUserQueryWrapper() throws {
        let commands = try AgentEventIngestor.commands(
            for: .grokHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hookEventName":"user_prompt_submit","prompt":"<user_query>reply with pong only</user_query>"}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .working,
                summary: "Working",
                detail: "reply with pong only"
            ),
        ])
    }

    @Test
    func grokUserPromptSubmitFallsBackWithoutPromptText() throws {
        let commands = try AgentEventIngestor.commands(
            for: .grokHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(#"{"hookEventName":"user_prompt_submit"}"#.utf8)
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .working,
                summary: "Working",
                detail: "Responding to your prompt"
            ),
        ])
    }

    @Test
    func grokPreToolUseMapsToWorkingToolStatus() throws {
        let commands = try AgentEventIngestor.commands(
            for: .grokHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hookEventName":"pre_tool_use","toolName":"read_file","toolInput":{"target_file":"/tmp/repo/README.md"}}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .working,
                summary: "Working",
                detail: "Reading README.md"
            ),
        ])
    }

    @Test
    func grokPreToolUseShellCommandMapsToRunningDetail() throws {
        let commands = try AgentEventIngestor.commands(
            for: .grokHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hookEventName":"pre_tool_use","toolName":"run_terminal_command","toolInput":{"command":"npm test","description":"Run tests"}}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .working,
                summary: "Working",
                detail: "Running npm test"
            ),
        ])
    }

    @Test
    func grokPostToolUseIsIgnoredForStatus() throws {
        let commands = try AgentEventIngestor.commands(
            for: .grokHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hookEventName":"post_tool_use","toolName":"read_file","toolInput":{"target_file":"/tmp/x"}}"#.utf8
            )
        )

        #expect(commands.isEmpty)
    }

    @Test
    func grokStopEndTurnMapsToReadyWithAssistantSummary() throws {
        let commands = try AgentEventIngestor.commands(
            for: .grokHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hookEventName":"stop","reason":"end_turn","lastAssistantMessage":"pong","backgroundTasks":[]}"#.utf8
            )
        )

        #expect(commands == [
            .sessionBackgroundActivitySync(
                sessionID: "sess-123",
                panelID: nil,
                kind: .subagent,
                entries: [],
                pendingBackgroundTaskCount: 0,
                preserveUnlistedActivities: false
            ),
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .ready,
                summary: "Ready",
                detail: "pong"
            ),
        ])
    }

    @Test
    func grokStopWithRunningSubagentSyncsBeforeReadyStatus() throws {
        let commands = try AgentEventIngestor.commands(
            for: .grokHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hookEventName":"stop","reason":"end_turn","lastAssistantMessage":"Agent launched","backgroundTasks":[{"id":"sub-1","type":"subagent","description":"Sleep briefly","agentType":"general-purpose"}]}"#.utf8
            )
        )

        #expect(commands == [
            .sessionBackgroundActivitySync(
                sessionID: "sess-123",
                panelID: nil,
                kind: .subagent,
                entries: [
                    SessionBackgroundActivitySyncEntry(
                        id: "sub-1",
                        displayName: "general-purpose",
                        command: "Sleep briefly"
                    ),
                ],
                pendingBackgroundTaskCount: 0,
                preserveUnlistedActivities: false
            ),
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .ready,
                summary: "Ready",
                detail: "Agent launched"
            ),
        ])
    }

    @Test
    func grokStopShutdownDoesNotMapToReady() throws {
        let commands = try AgentEventIngestor.commands(
            for: .grokHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hookEventName":"stop","reason":"shutdown","lastAssistantMessage":"bye"}"#.utf8
            )
        )

        #expect(commands.isEmpty)
    }

    @Test
    func grokStopChannelClosedDoesNotMapToReady() throws {
        let commands = try AgentEventIngestor.commands(
            for: .grokHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hookEventName":"stop","reason":"channel_closed"}"#.utf8
            )
        )

        #expect(commands.isEmpty)
    }

    @Test
    func grokStopFailureMapsToError() throws {
        let commands = try AgentEventIngestor.commands(
            for: .grokHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hookEventName":"stop_failure","lastAssistantMessage":"rate limited"}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .error,
                summary: "Error",
                detail: "rate limited"
            ),
        ])
    }

    @Test
    func grokNotificationPermissionPromptMapsToNeedsApproval() throws {
        let commands = try AgentEventIngestor.commands(
            for: .grokHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hookEventName":"notification","notificationType":"permission_prompt","message":"Tool permission requested"}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .needsApproval,
                summary: "Needs approval",
                detail: "Tool permission requested"
            ),
        ])
    }

    @Test
    func grokNotificationTaskCompleteIsIgnored() throws {
        let commands = try AgentEventIngestor.commands(
            for: .grokHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hookEventName":"notification","notificationType":"task_complete","message":"Background task completed: task-1"}"#.utf8
            )
        )

        #expect(commands.isEmpty)
    }

    @Test
    func grokSubagentStartMapsToBackgroundActivity() throws {
        let commands = try AgentEventIngestor.commands(
            for: .grokHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hookEventName":"subagent_start","subagentId":"sub-abc","subagentType":"general-purpose","description":"Reply with subok only"}"#.utf8
            )
        )

        #expect(commands == [
            .sessionBackgroundActivity(
                sessionID: "sess-123",
                panelID: nil,
                phase: .start,
                activityID: "sub-abc",
                kind: .subagent,
                displayName: "general-purpose",
                command: "Reply with subok only",
                processID: nil,
                preserveWhenUnlisted: false
            ),
        ])
    }

    @Test
    func grokSubagentStopFinishesBackgroundActivity() throws {
        let commands = try AgentEventIngestor.commands(
            for: .grokHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hookEventName":"subagent_stop","subagentId":"sub-abc","subagentType":"general-purpose"}"#.utf8
            )
        )

        #expect(commands == [
            .sessionBackgroundActivity(
                sessionID: "sess-123",
                panelID: nil,
                phase: .finish,
                activityID: "sub-abc",
                kind: .subagent,
                displayName: nil,
                command: nil,
                processID: nil,
                preserveWhenUnlisted: false
            ),
        ])
    }

    @Test
    func grokSessionStartDerivesResumePathWithoutTranscript() throws {
        let panelID = UUID()
        let nativeSessionID = "019fe0b5-ab92-7ee2-a2e5-a2d720fe5a43"
        let cwd = "/private/tmp/toastty-grok-spike-12593"
        let expectedPath = GrokHookEventParser.derivedSessionFilePath(
            sessionId: nativeSessionID,
            cwd: cwd
        )

        let commands = try AgentEventIngestor.commands(
            for: .grokHooks,
            sessionID: "sess-123",
            panelID: panelID,
            payload: Data(
                #"{"hookEventName":"session_start","sessionId":"\#(nativeSessionID)","cwd":"\#(cwd)","workspaceRoot":"\#(cwd)","source":"new"}"#.utf8
            )
        )

        #expect(commands == [
            .sessionUpdateResumeRecord(
                sessionID: "sess-123",
                panelID: panelID,
                agent: .grok,
                nativeSessionID: nativeSessionID,
                sessionFilePath: expectedPath,
                cwd: cwd
            ),
        ])
        #expect(expectedPath.hasSuffix("/summary.json"))
        #expect(expectedPath.contains("%2Fprivate%2Ftmp%2Ftoastty-grok-spike-12593"))
    }

    @Test
    func grokDerivedSessionFilePathHonorsCustomGrokHome() {
        let nativeSessionID = "019fe0b5-ab92-7ee2-a2e5-a2d720fe5a43"
        let cwd = "/private/tmp/custom-home-cwd"
        let customHome = URL(fileURLWithPath: "/var/tmp/custom-grok-home", isDirectory: true)
        let path = GrokHookEventParser.derivedSessionFilePath(
            sessionId: nativeSessionID,
            cwd: cwd,
            grokHome: customHome
        )
        #expect(path.hasPrefix(customHome.path))
        #expect(path.contains("/sessions/"))
        #expect(path.hasSuffix("/\(nativeSessionID)/summary.json"))
        #expect(path.contains(GrokHookEventParser.encodedSessionCwdFolderName(cwd)))
    }

    @Test
    func grokDerivedSessionFilePathReadsGROK_HOMEFromEnvironment() {
        let nativeSessionID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let cwd = "/tmp/env-home"
        let path = GrokHookEventParser.derivedSessionFilePath(
            sessionId: nativeSessionID,
            cwd: cwd,
            environment: ["GROK_HOME": "/opt/isolated-grok"]
        )
        #expect(path.hasPrefix("/opt/isolated-grok/sessions/"))
        #expect(path.hasSuffix("/\(nativeSessionID)/summary.json"))
    }

    @Test
    func grokSessionStartPrefersTranscriptPathWhenPresent() throws {
        let panelID = UUID()
        let transcript = "/Users/jd/.grok/sessions/%2Ftmp%2Frepo/native-1/updates.jsonl"
        let commands = try AgentEventIngestor.commands(
            for: .grokHooks,
            sessionID: "sess-123",
            panelID: panelID,
            payload: Data(
                #"{"hookEventName":"session_start","sessionId":"native-1","cwd":"/tmp/repo","transcriptPath":"\#(transcript)"}"#.utf8
            )
        )

        #expect(commands == [
            .sessionUpdateResumeRecord(
                sessionID: "sess-123",
                panelID: panelID,
                agent: .grok,
                nativeSessionID: "native-1",
                sessionFilePath: transcript,
                cwd: "/tmp/repo"
            ),
        ])
    }

    @Test
    func grokSessionStartRequiresPanelID() throws {
        let commands = try AgentEventIngestor.commands(
            for: .grokHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hookEventName":"session_start","sessionId":"native-1","cwd":"/tmp/repo"}"#.utf8
            )
        )

        #expect(commands.isEmpty)
    }

    @Test
    func grokPermissionDeniedIsIgnored() throws {
        let commands = try AgentEventIngestor.commands(
            for: .grokHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hookEventName":"permission_denied","toolName":"run_terminal_command"}"#.utf8
            )
        )

        #expect(commands.isEmpty)
    }

    @Test
    func grokSessionEndIsIgnored() throws {
        let commands = try AgentEventIngestor.commands(
            for: .grokHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hookEventName":"session_end","reason":"shutdown"}"#.utf8
            )
        )

        #expect(commands.isEmpty)
    }

    @Test
    func grokAcceptsPascalCaseEventNamesForResilience() throws {
        let commands = try AgentEventIngestor.commands(
            for: .grokHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hookEventName":"UserPromptSubmit","prompt":"hello from pascal"}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .working,
                summary: "Working",
                detail: "hello from pascal"
            ),
        ])
    }

    @Test
    func grokFallsBackToSnakeCaseFieldNames() throws {
        let commands = try AgentEventIngestor.commands(
            for: .grokHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hook_event_name":"pre_tool_use","tool_name":"read_file","tool_input":{"target_file":"/tmp/a.txt"}}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .working,
                summary: "Working",
                detail: "Reading a.txt"
            ),
        ])
    }
}
