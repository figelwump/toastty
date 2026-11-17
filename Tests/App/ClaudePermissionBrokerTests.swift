import CoreState
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyApp

struct ClaudePermissionBrokerTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let identity = ClaudeQuestionBroker.Identity(sessionID: "managed", bindingID: UUID(), panelID: UUID(),
        nativeSessionID: "native", transcriptPath: "/tmp/native.jsonl")
    let decision = RemoteInteractionQuestion(id: "decision", header: "Bash", question: "Approve Running ls\n\nls",
        options: [.init(id: "allow", label: "Allow once"), .init(id: "deny", label: "Deny")])

    func preTool(_ callID: String, digest: String = "digest") -> ClaudeQuestionHookRequest {
        .init(phase: .observe, sessionID: identity.sessionID, panelID: identity.panelID, event: .init(
            eventName: .preToolUse, nativeSessionID: identity.nativeSessionID, promptID: "prompt",
            transcriptPath: identity.transcriptPath, providerCallID: callID, toolName: "Bash",
            toolInputDigest: digest, timestamp: now))
    }
    func begin(_ responseID: String, digest: String = "digest") -> ClaudeQuestionHookRequest {
        .init(phase: .begin, sessionID: identity.sessionID, panelID: identity.panelID, event: .init(
            eventName: .permissionRequest, nativeSessionID: identity.nativeSessionID, promptID: "prompt",
            transcriptPath: identity.transcriptPath, toolName: "Bash", toolInputDigest: digest,
            permission: .init(summary: "Approve Running ls",
                              detail: .init(toolName: "Bash", description: "List", preview: "ls"),
                              decision: decision),
            timestamp: now), responseID: responseID)
    }
    func poll(_ responseID: String) -> ClaudeQuestionHookRequest {
        .init(phase: .poll, sessionID: identity.sessionID, panelID: identity.panelID, responseID: responseID)
    }
    func answer(_ responseID: String, optionID: String = "allow", text: String? = nil) -> RemoteQuestionAnswerRequest {
        .init(conversationID: .init(), interactionID: .init(rawValue: "claude:call:call-1"), responseID: responseID,
              expectedInputEpoch: .init(bindingID: identity.bindingID, counter: 1), clientRequestID: "request",
              answers: [.init(questionID: "decision", selectedOptionIDs: optionID.isEmpty ? [] : [optionID], text: text)])
    }
    /// Claude's transcript parser identifies a tool result by its call ID.
    func toolResult(_ callID: String, at offset: TimeInterval) -> ProviderTranscriptObservation {
        .init(timestamp: now.addingTimeInterval(offset), providerIdentity: callID, fingerprint: "call_out:\(callID)",
              payload: .transcript(.toolFinished(.init(callID: callID, outcome: .succeeded))))
    }

    @Test func permissionBindsToItsToolCallAndPresentsAnAnswerableCard() throws {
        var broker = ClaudeQuestionBroker()
        _ = broker.handle(preTool("other", digest: "other"), identity: identity, at: now)
        _ = broker.handle(preTool("call-1"), identity: identity, at: now)
        let responseID = UUID().uuidString
        let reply = broker.handle(begin(responseID), identity: identity, at: now)
        #expect(reply.status == .pending)
        #expect(reply.providerCallID == "call-1")
        guard case .interactionPresented(let presented) = try #require(broker.drainChanges().first).payload else {
            Issue.record("Expected a presented permission")
            return
        }
        #expect(presented.kind == .permission)
        #expect(presented.providerCallID == "call-1")
        #expect(presented.prompt == "Approve Running ls")
        #expect(presented.permission?.preview == "ls")
        #expect(presented.questions == [decision])
        #expect(presented.responseID == responseID)
    }

    @Test func missingOrAmbiguousToolCallLeavesTheRequestToTheDesktop() {
        var broker = ClaudeQuestionBroker()
        #expect(broker.handle(begin(UUID().uuidString), identity: identity, at: now).status == .unavailable)
        _ = broker.handle(preTool("call-1"), identity: identity, at: now)
        _ = broker.handle(preTool("call-2"), identity: identity, at: now)
        #expect(broker.handle(begin(UUID().uuidString), identity: identity, at: now).status == .unavailable)
    }

    @Test func overflowedToolCallRingStopsBindingUntilTheNextTurn() {
        var broker = ClaudeQuestionBroker()
        _ = broker.handle(preTool("call-1"), identity: identity, at: now)
        for index in 0..<ClaudeQuestionBroker.maximumRecentToolCalls {
            _ = broker.handle(preTool("filler-\(index)", digest: "filler-\(index)"), identity: identity, at: now)
        }
        _ = broker.handle(preTool("call-2"), identity: identity, at: now)
        #expect(broker.handle(begin(UUID().uuidString), identity: identity, at: now).status == .unavailable)
        broker.reconcile([.init(timestamp: now.addingTimeInterval(1), fingerprint: "turn", payload: .turnStarted(turnID: nil))],
                         identity: identity, at: now.addingTimeInterval(1))
        _ = broker.handle(preTool("call-1"), identity: identity, at: now.addingTimeInterval(2))
        #expect(broker.handle(begin(UUID().uuidString), identity: identity, at: now.addingTimeInterval(2)).status == .pending)
    }

    @Test func onlyOneOfferedDecisionIsAccepted() {
        var broker = ClaudeQuestionBroker()
        _ = broker.handle(preTool("call-1"), identity: identity, at: now)
        let responseID = UUID().uuidString
        _ = broker.handle(begin(responseID), identity: identity, at: now)
        #expect(broker.submit(answer(responseID, optionID: "", text: "do something else"), identity: identity, at: now)
            == .rejected(reason: .invalidAnswers))
        #expect(broker.submit(answer(responseID, optionID: "always:0"), identity: identity, at: now)
            == .rejected(reason: .invalidAnswers))
        #expect(broker.submit(answer(responseID, optionID: "deny"), identity: identity, at: now) == .submitted)
        let reply = broker.handle(poll(responseID), identity: identity, at: now.addingTimeInterval(1))
        #expect(reply.status == .answer)
        #expect(reply.answers == [.init(questionID: "decision", selectedOptionIDs: ["deny"])])
    }

    @Test func desktopAnswerClosesThePollingHookThroughTheTranscript() throws {
        var broker = ClaudeQuestionBroker()
        _ = broker.handle(preTool("call-1"), identity: identity, at: now)
        let responseID = UUID().uuidString
        _ = broker.handle(begin(responseID), identity: identity, at: now)
        _ = broker.drainChanges()
        broker.reconcile([toolResult("call-1", at: 5)], identity: identity, at: now.addingTimeInterval(5))
        #expect(broker.handle(poll(responseID), identity: identity, at: now.addingTimeInterval(6)).status == .finished)
        guard case .transcript(.interactionResponseClosed) = try #require(broker.drainChanges().first).payload else {
            Issue.record("Expected the phone's response window to close")
            return
        }
    }

    @Test func deliveredDecisionClosesWithoutClaimingWhichAnswerWon() {
        var broker = ClaudeQuestionBroker()
        _ = broker.handle(preTool("call-1"), identity: identity, at: now)
        let responseID = UUID().uuidString
        _ = broker.handle(begin(responseID), identity: identity, at: now)
        _ = broker.drainChanges()
        #expect(broker.submit(answer(responseID), identity: identity, at: now) == .submitted)
        #expect(broker.handle(poll(responseID), identity: identity, at: now.addingTimeInterval(1)).status == .answer)
        // A long-running tool outlives the confirmation window, and its result
        // arrives later. Neither marks the phone's answer closed or accepted.
        broker.expire(at: now.addingTimeInterval(400))
        broker.reconcile([toolResult("call-1", at: 500)], identity: identity, at: now.addingTimeInterval(500))
        #expect(broker.drainChanges().isEmpty)
    }
}
