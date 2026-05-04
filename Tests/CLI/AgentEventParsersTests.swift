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
    func claudePostToolUseFailureMapsToWorkingRetryStatus() throws {
        let commands = try AgentEventIngestor.commands(
            for: .claudeHooks,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"hook_event_name":"PostToolUseFailure","tool_name":"Bash"}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .working,
                summary: "Working",
                detail: "Retrying after Bash failed"
            )
        ])
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
}
