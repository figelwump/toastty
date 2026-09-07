import CoreState
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyApp

struct ClaudeQuestionBrokerTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let identity = ClaudeQuestionBroker.Identity(sessionID: "managed", bindingID: UUID(), panelID: UUID(),
        nativeSessionID: "native", transcriptPath: "/tmp/native.jsonl")
    let questions = [RemoteInteractionQuestion(id: "0", header: "Color", question: "Which color?",
        options: [.init(id: "0", label: "Blue"), .init(id: "1", label: "Green")])]

    func event(_ name: ClaudeQuestionHookEvent.EventName, callID: String? = nil,
               answers: [String: String]? = nil) -> ClaudeQuestionHookEvent {
        .init(eventName: name, nativeSessionID: identity.nativeSessionID, promptID: "prompt",
              transcriptPath: identity.transcriptPath, providerCallID: callID, questions: questions,
              answers: answers, timestamp: now)
    }
    func hook(_ phase: ClaudeQuestionHookRequest.Phase, event: ClaudeQuestionHookEvent? = nil,
              responseID: String? = nil) -> ClaudeQuestionHookRequest {
        .init(phase: phase, sessionID: identity.sessionID, panelID: identity.panelID,
              event: event, responseID: responseID)
    }
    func started() -> (ClaudeQuestionBroker, String) {
        var broker = ClaudeQuestionBroker()
        _ = broker.handle(hook(.observe, event: event(.preToolUse, callID: "call")), identity: identity, at: now)
        let responseID = UUID().uuidString
        #expect(broker.handle(hook(.begin, event: event(.permissionRequest), responseID: responseID),
                              identity: identity, at: now).status == .pending)
        _ = broker.drainChanges()
        return (broker, responseID)
    }
    func answer(_ responseID: String) -> RemoteQuestionAnswerRequest {
        .init(conversationID: .init(), interactionID: .init(rawValue: "claude:call:call"), responseID: responseID,
              expectedInputEpoch: .init(bindingID: identity.bindingID, counter: 1), clientRequestID: "request",
              answers: [.init(questionID: "0", selectedOptionIDs: ["0"])])
    }

    @Test func exactRegistrationRejectsAmbiguityAndNativeIdentityMismatch() {
        var broker = ClaudeQuestionBroker()
        for call in ["call-a", "call-b"] {
            _ = broker.handle(hook(.observe, event: event(.preToolUse, callID: call)), identity: identity, at: now)
        }
        #expect(broker.handle(hook(.begin, event: event(.permissionRequest), responseID: UUID().uuidString),
                              identity: identity, at: now).status == .unavailable)
        var wrong = event(.preToolUse, callID: "wrong")
        wrong.transcriptPath = "/tmp/other.jsonl"
        #expect(broker.handle(hook(.observe, event: wrong), identity: identity, at: now).status == .unavailable)
        broker.expire(at: now.addingTimeInterval(61))
        #expect(broker.entries.isEmpty)
    }

    @Test func duplicateIsIdempotentTwoDevicesCannotReplaceAnswerAndPollRetriesReturnSameAnswer() {
        var (broker, responseID) = started()
        let request = answer(responseID)
        #expect(broker.submit(request, identity: identity, at: now) == .submitted)
        #expect(broker.submit(request, identity: identity, at: now) == .duplicate)
        var competing = request
        competing.clientRequestID = "other-device"
        #expect(broker.submit(competing, identity: identity, at: now) == .rejected(reason: .alreadySubmitted))
        competing = request
        competing.answers = [.init(questionID: "0", selectedOptionIDs: ["1"])]
        #expect(broker.submit(competing, identity: identity, at: now) == .rejected(reason: .alreadySubmitted))
        let poll = hook(.poll, responseID: responseID)
        let first = broker.handle(poll, identity: identity, at: now)
        #expect(first.status == .answer)
        #expect(broker.handle(poll, identity: identity, at: now.addingTimeInterval(1)) == first)
        #expect(broker.drainChanges().isEmpty)
        #expect(!broker.entries[0].resolved)
    }

    @Test func leaseExpiryClosesAuthorityWithoutResolvingProviderQuestion() throws {
        var (broker, responseID) = started()
        broker.expire(at: now.addingTimeInterval(11))
        #expect(broker.submit(answer(responseID), identity: identity, at: now.addingTimeInterval(11)) == .rejected(reason: .expired))
        let changes = broker.drainChanges()
        #expect(changes.count == 1)
        guard case .transcript(.interactionResponseClosed(let closed)) = try #require(changes.first).payload else {
            Issue.record("Expected response closure, not provider resolution")
            return
        }
        #expect(closed.reason == .expired)
        #expect(!broker.entries[0].resolved)
    }

    @Test func desktopCompletionWinsAndEnrichesAcceptedAnswersEvenAfterLeaseClosed() throws {
        var (broker, responseID) = started()
        broker.expire(at: now.addingTimeInterval(11))
        _ = broker.drainChanges()
        _ = broker.handle(hook(.observe, event: event(.postToolUse, callID: "call", answers: ["Which color?": "Green"])),
                          identity: identity, at: now.addingTimeInterval(12))
        let changes = broker.drainChanges()
        guard case .transcript(.interactionResolved(let resolved)) = try #require(changes.first).payload else {
            Issue.record("Expected authoritative provider resolution")
            return
        }
        #expect(resolved.answers == [.init(questionID: "0", selectedOptionIDs: ["1"])])
        #expect(broker.handle(hook(.poll, responseID: responseID), identity: identity, at: now.addingTimeInterval(12)).status == .finished)
    }

    @Test func invalidAnswersAndReplacedBindingFailClosed() {
        var (broker, responseID) = started()
        var request = answer(responseID)
        request.answers = [.init(questionID: "0", selectedOptionIDs: ["invented"])]
        #expect(broker.submit(request, identity: identity, at: now) == .rejected(reason: .invalidAnswers))
        var replacement = identity
        replacement.bindingID = UUID()
        #expect(broker.submit(answer(responseID), identity: replacement, at: now) == .rejected(reason: .notPending))
        #expect(broker.handle(hook(.poll, responseID: responseID), identity: replacement, at: now).status == .unavailable)
    }

    @Test func livePollRenewsLeaseButCannotExtendAbsoluteDeadline() {
        var (broker, responseID) = started()
        for second in stride(from: 5, through: 295, by: 5) {
            #expect(broker.handle(hook(.poll, responseID: responseID), identity: identity,
                                  at: now.addingTimeInterval(Double(second))).status == .pending)
        }
        #expect(broker.handle(hook(.poll, responseID: responseID), identity: identity,
                              at: now.addingTimeInterval(300)).status == .finished)
    }
}


extension ClaudeQuestionBrokerTests {
    @Test func transcriptCompletionClosesResponseButRetainsSnapshotForAcceptedAnswerEnrichment() throws {
        var (broker, responseID) = started()
        broker.reconcile([.init(timestamp: now.addingTimeInterval(1), providerIdentity: identity.nativeSessionID,
            fingerprint: "finished", payload: .transcript(.toolFinished(.init(callID: "call"))))], identity: identity)
        #expect(broker.handle(hook(.poll, responseID: responseID), identity: identity, at: now.addingTimeInterval(2)).status == .finished)
        #expect(!broker.entries[0].resolved)
        _ = broker.drainChanges()
        _ = broker.handle(hook(.observe, event: event(.postToolUse, callID: "call", answers: ["Which color?": "Blue"])),
                          identity: identity, at: now.addingTimeInterval(3))
        guard case .transcript(.interactionResolved(let resolution)) = try #require(broker.drainChanges().first).payload else {
            Issue.record("Expected late accepted-answer enrichment")
            return
        }
        #expect(resolution.answers == [.init(questionID: "0", selectedOptionIDs: ["0"])])
    }
}


extension ClaudeQuestionBrokerTests {
    @Test func submittedAnswerExpiresWhenHookDoesNotPollBeforeLeaseDeadline() throws {
        var (broker, responseID) = started()
        let request = answer(responseID)
        #expect(broker.submit(request, identity: identity, at: now.addingTimeInterval(9)) == .submitted)
        broker.expire(at: now.addingTimeInterval(11))
        #expect(broker.handle(hook(.poll, responseID: responseID), identity: identity,
                              at: now.addingTimeInterval(11)).status == .finished)
        #expect(!broker.entries[0].delivered)
        #expect(!broker.entries[0].resolved)
        let changes = broker.drainChanges()
        #expect(changes.count == 1)
        guard case .transcript(.interactionResponseClosed(let closure)) = try #require(changes.first).payload else {
            Issue.record("Expected lease closure without provider completion")
            return
        }
        #expect(closure.reason == .expired)
    }
}
