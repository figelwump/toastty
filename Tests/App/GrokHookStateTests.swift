import CoreState
import Foundation
import Testing
@testable import ToasttyApp

struct GrokHookStateTests {
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

    private func event(_ kind: GrokHookEvent.Kind, native: String = "root", prompt: String? = nil, at time: Double, notification: String? = nil) -> GrokHookEvent {
        GrokHookEvent(kind: kind, nativeSessionID: native, promptID: prompt, timestamp: Date(timeIntervalSince1970: time), notificationType: notification)
    }
}
