import CoreState
import Foundation

/// Reconciles hook processes using producer timestamps and native prompt IDs.
/// Stop is a gate: only a later idle observation confirms it actually settled.
struct GrokHookState {
    struct Update: Equatable {
        var status: SessionStatus?
    }

    private(set) var nativeSessionID: String?
    private var promptID: String?
    private var latestTimestamp = Date.distantPast
    private var stopObserved = false

    mutating func apply(_ event: GrokHookEvent) -> Update? {
        guard !event.isSubagent else { return nil }
        if event.kind == .sessionStart {
            guard nativeSessionID == nil, event.timestamp > latestTimestamp else { return nil }
            nativeSessionID = event.nativeSessionID
            latestTimestamp = event.timestamp
            return Update(status: SessionStatus(kind: .idle, summary: "Waiting", detail: "Grok is ready"))
        }
        guard event.timestamp > latestTimestamp else { return nil }
        if event.kind == .userPromptSubmit {
            guard event.promptID != nil else { return nil }
            // Root prompts have no subagentType and the launch helper checks
            // the producer PID. They recover lost startup/end observations
            // and establish the conversation selected by /clear or /resume.
            nativeSessionID = event.nativeSessionID
        }
        guard event.nativeSessionID == nativeSessionID else { return nil }

        let status: SessionStatus?
        switch event.kind {
        case .sessionStart:
            return nil
        case .userPromptSubmit:
            guard let id = event.promptID else { return nil }
            promptID = id
            stopObserved = false
            status = SessionStatus(kind: .working, summary: "Working", detail: "Responding to your prompt")
        case .preToolUse, .postToolUse, .postToolUseFailure:
            guard matchesPrompt(event) else { return nil }
            stopObserved = false
            status = SessionStatus(kind: .working, summary: "Working", detail: "Grok is using a tool")
        case .permissionRequest:
            guard matchesPrompt(event) else { return nil }
            status = SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Grok is waiting for permission")
        case .stop:
            guard matchesPrompt(event) else { return nil }
            stopObserved = true
            status = SessionStatus(kind: .idle, summary: "Waiting", detail: "Grok finished a response")
        case .stopFailure, .stopCancelled:
            guard matchesPrompt(event) else { return nil }
            promptID = nil
            stopObserved = false
            status = event.kind == .stopFailure
                ? SessionStatus(kind: .error, summary: "Error", detail: "Grok could not complete the turn")
                : SessionStatus(kind: .idle, summary: "Stopped", detail: "Grok stopped the turn")
        case .notification:
            switch event.notificationType {
            case "permission_prompt":
                guard promptID != nil else { return nil }
                status = SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Grok is waiting for permission")
            case "agent_error":
                guard promptID != nil else { return nil }
                promptID = nil
                stopObserved = false
                status = SessionStatus(kind: .error, summary: "Error", detail: "Grok reported an error")
            case "idle_prompt":
                if promptID != nil {
                    status = stopObserved
                        ? SessionStatus(kind: .ready, summary: "Ready", detail: "Turn complete")
                        : SessionStatus(kind: .idle, summary: "Waiting", detail: "Grok is waiting for your next prompt")
                } else {
                    // Idle also follows failures and cancellations; keep them visible.
                    status = nil
                }
                promptID = nil
                stopObserved = false
            default:
                return nil
            }
        case .sessionEnd:
            status = promptID == nil ? nil : SessionStatus(kind: .idle, summary: "Stopped", detail: "Grok session ended")
            nativeSessionID = nil
            promptID = nil
            stopObserved = false
        }
        latestTimestamp = event.timestamp
        return Update(status: status)
    }

    private func matchesPrompt(_ event: GrokHookEvent) -> Bool {
        promptID != nil && event.promptID == promptID
    }
}
