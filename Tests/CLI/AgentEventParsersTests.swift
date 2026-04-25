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
    func codexTurnCompleteMapsToReadyStatusWithAssistantSummary() throws {
        let commands = try AgentEventIngestor.commands(
            for: .codexNotify,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"type":"agent-turn-complete","last-assistant-message":"Finished updating the launch path."}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .ready,
                summary: "Ready",
                detail: "Finished updating the launch path."
            )
        ])
    }

    @Test
    func codexTaskCompleteMapsToReadyStatusWithAssistantSummary() throws {
        let commands = try AgentEventIngestor.commands(
            for: .codexNotify,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"type":"task_complete","last_agent_message":"Finished updating the launch path."}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .ready,
                summary: "Ready",
                detail: "Finished updating the launch path."
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
    func piToolExecutionMapsStatusAndChangedFiles() throws {
        let commands = try AgentEventIngestor.commands(
            for: .piExtension,
            sessionID: "sess-123",
            panelID: nil,
            payload: Data(
                #"{"source":"pi-extension","version":1,"toasttySessionID":"sess-123","event":"tool_execution_end","toolName":"edit","files":["Sources/App/ToasttyApp.swift","Sources/App/ToasttyApp.swift"],"isError":false}"#.utf8
            )
        )

        #expect(commands == [
            .sessionStatus(
                sessionID: "sess-123",
                panelID: nil,
                kind: .working,
                summary: "Working",
                detail: "Finished Edit"
            ),
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
