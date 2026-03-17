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
}
