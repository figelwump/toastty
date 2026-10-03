import CoreState
import Foundation
import Testing
@testable import ToasttyApp

struct GrokHookStateTests {
    @Test(arguments: [
        ("run_terminal_command", "Running a command"),
        ("read_file", "Reading files"),
        ("search_replace", "Editing files"),
        ("grep", "Searching code"),
        ("list_dir", "Listing files"),
        ("web_search", "Searching the web"),
        ("web_fetch", "Fetching a web page"),
        ("spawn_subagent", "Running a subagent"),
        ("unrecognized_tool", "Using a tool"),
    ])
    func toolActivityWithoutPromptIDUsesSafeLabels(toolName: String, detail: String) {
        var state = GrokHookState()
        _ = state.apply(event(.userPromptSubmit, prompt: "a", at: 1))
        let start = state.apply(event(.preToolUse, at: 2, tool: "call-a", name: toolName))
        #expect(start?.status?.kind == .working)
        #expect(start?.status?.detail == detail)
        let finish = state.apply(event(.postToolUse, at: 3, tool: "call-a"))
        #expect(finish?.status?.kind == .working)
        #expect(finish?.status?.detail == "Responding to your prompt")
    }

    @Test func overlappingToolsRetainActivityUntilBothFinishEvenWithLateCompletionDelivery() {
        var state = GrokHookState()
        _ = state.apply(event(.userPromptSubmit, prompt: "a", at: 1))
        _ = state.apply(event(.preToolUse, at: 2, tool: "read", name: "read_file"))
        _ = state.apply(event(.preToolUse, at: 3, tool: "command", name: "run_terminal_command"))
        #expect(state.apply(event(.postToolUse, at: 5, tool: "command"))?.status?.detail == "Reading files")
        #expect(state.apply(event(.postToolUseFailure, at: 4, tool: "read"))?.status?.detail == "Responding to your prompt")
        #expect(state.apply(event(.preToolUse, at: 3.5, tool: "read", name: "read_file")) == nil)
    }

    @Test func toolCompletionBeforeStartCannotResurrectActivity() {
        var state = GrokHookState()
        _ = state.apply(event(.userPromptSubmit, prompt: "a", at: 1))
        #expect(state.apply(event(.postToolUse, at: 3, tool: "call"))?.status == nil)
        #expect(state.apply(event(.preToolUse, at: 2, tool: "call", name: "read_file")) == nil)
    }

    @Test func toolIDsCannotCrossPromptsNativeSessionsOrCancellation() {
        var state = GrokHookState()
        _ = state.apply(event(.userPromptSubmit, prompt: "a", at: 1))
        _ = state.apply(event(.preToolUse, at: 2, tool: "old", name: "read_file"))
        _ = state.apply(event(.userPromptSubmit, prompt: "b", at: 3))
        #expect(state.apply(event(.preToolUse, prompt: "a", at: 4, tool: "wrong-prompt")) == nil)
        #expect(state.apply(event(.preToolUse, native: "foreign", at: 4, tool: "foreign")) == nil)
        #expect(state.apply(event(.postToolUse, at: 4, tool: "old"))?.status == nil)
        #expect(state.apply(event(.preToolUse, at: 2.5, tool: "late-old")) == nil)
        _ = state.apply(event(.preToolUse, at: 5, tool: "current", name: "grep"))
        _ = state.apply(event(.stopCancelled, prompt: "b", at: 6))
        #expect(state.apply(event(.postToolUse, at: 7, tool: "current")) == nil)
        #expect(state.apply(event(.preToolUse, at: 8, tool: "after-cancel")) == nil)
    }

    @Test func approvalNamesTheToolAndOlderCompletionCannotClearIt() {
        var state = GrokHookState()
        _ = state.apply(event(.userPromptSubmit, prompt: "a", at: 1))
        _ = state.apply(event(.preToolUse, at: 2, tool: "read", name: "read_file"))
        _ = state.apply(event(.preToolUse, at: 3, tool: "command", name: "run_terminal_command"))
        let approval = state.apply(event(.notification, at: 5, notification: "permission_prompt"))
        #expect(approval?.status?.detail == "Waiting for command approval")
        #expect(state.apply(event(.postToolUse, at: 4, tool: "read"))?.status?.kind == .needsApproval)
        #expect(state.apply(event(.postToolUse, at: 6, tool: "command"))?.status?.detail == "Responding to your prompt")
    }

    @Test func newerUnrelatedToolCompletionCannotClearPermission() {
        var state = GrokHookState()
        _ = state.apply(event(.userPromptSubmit, prompt: "a", at: 1))
        _ = state.apply(event(.preToolUse, at: 2, tool: "read", name: "read_file"))
        _ = state.apply(event(.preToolUse, at: 3, tool: "command", name: "run_terminal_command"))
        _ = state.apply(event(.notification, at: 4, notification: "permission_prompt"))
        #expect(state.apply(event(.postToolUse, at: 5, tool: "read"))?.status?.detail == "Waiting for command approval")
    }

    @Test func delayedPermissionAndPromptHooksAreNotDroppedByToolTimestamps() {
        var state = GrokHookState()
        _ = state.apply(event(.userPromptSubmit, prompt: "a", at: 1))
        _ = state.apply(event(.preToolUse, at: 2, tool: "read", name: "read_file"))
        _ = state.apply(event(.preToolUse, at: 3, tool: "command", name: "run_terminal_command"))
        _ = state.apply(event(.postToolUse, at: 5, tool: "read"))
        #expect(state.apply(event(.notification, at: 4, notification: "permission_prompt"))?.status?.kind == .needsApproval)
        _ = state.apply(event(.postToolUse, at: 6, tool: "command"))
        _ = state.apply(event(.preToolUse, at: 9, tool: "new", name: "grep"))
        #expect(state.apply(event(.userPromptSubmit, prompt: "b", at: 8))?.status?.detail == "Searching code")
        #expect(state.apply(event(.stop, prompt: "b", at: 10))?.status?.kind == .idle)
    }

    @Test func delayedPermissionCannotReopenAnAlreadyCompletedApproval() {
        var state = GrokHookState()
        _ = state.apply(event(.userPromptSubmit, prompt: "a", at: 1))
        _ = state.apply(event(.preToolUse, at: 2, tool: "command", name: "run_terminal_command"))
        _ = state.apply(event(.postToolUse, at: 4, tool: "command"))
        #expect(state.apply(event(.notification, at: 3, notification: "permission_prompt"))?.status == nil)
    }

    @Test func completionBeforeStartClearsAnExplicitPendingPermission() {
        var state = GrokHookState()
        _ = state.apply(event(.userPromptSubmit, prompt: "a", at: 1))
        _ = state.apply(event(.permissionRequest, prompt: "a", at: 3, tool: "call"))
        #expect(state.apply(event(.postToolUse, at: 5, tool: "call"))?.status?.kind == .working)
        #expect(state.apply(event(.preToolUse, at: 2, tool: "call", name: "read_file")) == nil)
    }

    @Test func parallelCompletedToolDoesNotSuppressApprovalForAnActiveTool() {
        var state = GrokHookState()
        _ = state.apply(event(.userPromptSubmit, prompt: "a", at: 1))
        _ = state.apply(event(.preToolUse, at: 2, tool: "command", name: "run_terminal_command"))
        _ = state.apply(event(.preToolUse, at: 3, tool: "read", name: "read_file"))
        _ = state.apply(event(.postToolUse, at: 5, tool: "read"))
        #expect(state.apply(event(.notification, at: 4, notification: "permission_prompt"))?.status?.detail == "Waiting for command approval")
    }

    @Test func completionPredatingPermissionReleasesInferredBindingWithoutClearingApproval() {
        var state = GrokHookState()
        _ = state.apply(event(.userPromptSubmit, prompt: "a", at: 1))
        _ = state.apply(event(.preToolUse, at: 2, tool: "read", name: "read_file"))
        _ = state.apply(event(.notification, at: 4, notification: "permission_prompt"))
        #expect(state.apply(event(.postToolUse, at: 3, tool: "read"))?.status?.kind == .needsApproval)
        #expect(state.apply(event(.preToolUse, at: 3.5, tool: "command", name: "run_terminal_command"))?.status?.detail == "Waiting for command approval")
        #expect(state.apply(event(.postToolUse, at: 5, tool: "command"))?.status?.kind == .working)
    }

    @Test func notificationRetainsAnExplicitPermissionBinding() {
        var state = GrokHookState()
        _ = state.apply(event(.userPromptSubmit, prompt: "a", at: 1))
        _ = state.apply(event(.preToolUse, at: 2, tool: "command", name: "run_terminal_command"))
        _ = state.apply(event(.permissionRequest, prompt: "a", at: 3, tool: "command"))
        _ = state.apply(event(.preToolUse, at: 4, tool: "read", name: "read_file"))
        #expect(state.apply(event(.notification, at: 5, notification: "permission_prompt"))?.status?.detail == "Waiting for command approval")
        #expect(state.apply(event(.postToolUse, at: 6, tool: "command"))?.status?.detail == "Reading files")
    }

    @Test func coarseTimestampsStillAllowToolStartAndCompletion() {
        var state = GrokHookState()
        _ = state.apply(event(.userPromptSubmit, prompt: "a", at: 1))
        #expect(state.apply(event(.preToolUse, at: 1, tool: "read", name: "read_file"))?.status?.detail == "Reading files")
        #expect(state.apply(event(.postToolUse, at: 1, tool: "read"))?.status?.detail == "Responding to your prompt")
    }

    @Test func stopRejectsOldToolActivityButPreservesAContinuationAlreadyObserved() {
        var state = GrokHookState()
        _ = state.apply(event(.userPromptSubmit, prompt: "a", at: 1))
        _ = state.apply(event(.preToolUse, at: 4, tool: "continued", name: "grep"))
        #expect(state.apply(event(.stop, prompt: "a", at: 3))?.status?.detail == "Searching code")
        #expect(state.apply(event(.preToolUse, at: 3, tool: "old", name: "read_file")) == nil)
        #expect(state.apply(event(.postToolUse, at: 5, tool: "continued"))?.status?.detail == "Responding to your prompt")
    }

    @Test func longTurnsKeepReportingNewToolsWithoutRevivingDiscardedCompletions() {
        var state = GrokHookState()
        _ = state.apply(event(.userPromptSubmit, prompt: "a", at: 1))
        for index in 0..<140 {
            let start = Double(2 + index * 2)
            #expect(state.apply(event(.preToolUse, at: start, tool: "call-\(index)", name: "read_file"))?.status?.detail == "Reading files")
            #expect(state.apply(event(.postToolUse, at: start + 1, tool: "call-\(index)"))?.status?.detail == "Responding to your prompt")
        }
        #expect(state.apply(event(.preToolUse, at: 2, tool: "call-0", name: "read_file")) == nil)
    }

    @Test func newRootPromptRecoversMissingSessionEndButNestedPromptCannotRebind() {
        var state = GrokHookState()
        _ = state.apply(event(.sessionStart, at: 1))
        _ = state.apply(event(.userPromptSubmit, prompt: "a", at: 2))
        var nested = event(.userPromptSubmit, native: "nested", prompt: "child", at: 3)
        nested.isSubagent = true
        #expect(state.apply(nested) == nil)
        #expect(state.apply(event(.userPromptSubmit, native: "cleared", prompt: "b", at: 4))?.status?.kind == .working)
        #expect(state.apply(event(.sessionEnd, at: 3.5)) == nil)
        #expect(state.apply(event(.stop, native: "cleared", prompt: "b", at: 5))?.status?.kind == .idle)
    }

    @Test func promptAndFailureDoNotDependOnStartupDelivery() {
        var state = GrokHookState()
        #expect(state.apply(event(.userPromptSubmit, prompt: "a", at: 2))?.status?.kind == .working)
        #expect(state.apply(event(.stopFailure, prompt: "a", at: 3))?.status?.kind == .error)
        #expect(state.apply(event(.sessionStart, at: 1)) == nil)
    }

    @Test func correlatesPromptsAndPreservesFailureAcrossIdle() {
        var state = GrokHookState()
        #expect(state.apply(event(.sessionStart, at: 1))?.status?.kind == .idle)
        #expect(state.apply(event(.userPromptSubmit, prompt: "a", at: 2))?.status?.kind == .working)
        #expect(state.apply(event(.userPromptSubmit, prompt: "b", at: 3))?.status?.kind == .working)
        #expect(state.apply(event(.stop, prompt: "a", at: 4)) == nil)
        #expect(state.apply(event(.notification, at: 4, notification: "permission_prompt"))?.status?.kind == .needsApproval)
        #expect(state.apply(event(.postToolUse, prompt: "b", at: 5))?.status?.kind == .working)
        #expect(state.apply(event(.stopFailure, prompt: "b", at: 6))?.status?.kind == .error)
        #expect(state.apply(event(.notification, at: 7, notification: "idle_prompt"))?.status == nil)
        #expect(state.apply(event(.preToolUse, prompt: "b", at: 8)) == nil)
    }

    @Test func stopIsProvisionalAndLaterActivityResumesWorking() {
        var state = GrokHookState()
        _ = state.apply(event(.sessionStart, at: 1))
        _ = state.apply(event(.userPromptSubmit, prompt: "a", at: 2))
        #expect(state.apply(event(.stop, prompt: "a", at: 3))?.status?.kind == .idle)
        #expect(state.apply(event(.preToolUse, prompt: "a", at: 4))?.status?.kind == .working)
        #expect(state.apply(event(.notification, at: 3.5, notification: "idle_prompt")) == nil)
        #expect(state.apply(event(.stopCancelled, prompt: "a", at: 5))?.status?.summary == "Stopped")
        #expect(state.apply(event(.notification, at: 6, notification: "idle_prompt"))?.status == nil)
    }

    @Test func promptEstablishesRootAndForeignNonPromptEventsCannotReplaceIt() {
        var state = GrokHookState()
        #expect(state.apply(event(.userPromptSubmit, prompt: "a", at: 2))?.status?.kind == .working)
        #expect(state.apply(event(.sessionStart, at: 1)) == nil)
        #expect(state.apply(event(.sessionStart, native: "nested", at: 3)) == nil)
        #expect(state.apply(event(.stop, native: "nested", prompt: "a", at: 4)) == nil)
        var nested = event(.stop, prompt: "a", at: 5)
        nested.isSubagent = true
        #expect(state.apply(nested) == nil)
        _ = state.apply(event(.sessionEnd, at: 6))
        #expect(state.apply(event(.sessionStart, native: "new", at: 7))?.status?.kind == .idle)
        #expect(state.apply(event(.sessionStart, at: 1)) == nil)
    }

    @Test func shutdownStopAndUnknownNotificationsCannotCompleteTurn() {
        var state = GrokHookState()
        _ = state.apply(event(.sessionStart, at: 1))
        _ = state.apply(event(.userPromptSubmit, prompt: "a", at: 2))
        #expect(state.apply(event(.stop, at: 3)) == nil)
        #expect(state.apply(event(.notification, at: 4, notification: "future")) == nil)
        #expect(state.apply(event(.stop, prompt: "a", at: 5))?.status?.kind == .idle)
        #expect(state.apply(event(.notification, at: 6, notification: "idle_prompt"))?.status?.kind == .ready)
        #expect(state.apply(event(.stop, prompt: "a", at: 7)) == nil)
    }

    private func event(_ kind: GrokHookEvent.Kind, native: String = "root", prompt: String? = nil, at time: Double, notification: String? = nil, tool: String? = nil, name: String? = nil) -> GrokHookEvent {
        GrokHookEvent(kind: kind, nativeSessionID: native, promptID: prompt, timestamp: Date(timeIntervalSince1970: time), notificationType: notification, toolName: name, toolUseID: tool)
    }
}
