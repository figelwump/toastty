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
}
