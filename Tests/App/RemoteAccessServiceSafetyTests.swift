import CoreState
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyApp

struct RemoteAccessServiceSafetyTests {
    @Test func readAcknowledgementAcceptsAuthoritativeEmptyAndRejectsStaleBoundaries() {
        let runID = RemoteProjectionRunID()
        let empty = RemoteConversationReadAcknowledgementRequest(
            conversationID: RemoteConversationID(),
            projectionRunID: runID,
            projectionGeneration: 2,
            observedThroughSequence: 0
        )
        let matching = RemoteConversationReadAcknowledgementRequest(
            conversationID: RemoteConversationID(),
            projectionRunID: runID,
            projectionGeneration: 2,
            observedThroughSequence: 8
        )

        #expect(RemoteAccessService.readAcknowledgementResult(
            request: empty,
            currentProjectionRunID: runID,
            currentProjectionGeneration: 2,
            currentLatestSequence: 0,
            isUnread: true
        ) == .acknowledged)
        #expect(RemoteAccessService.readAcknowledgementResult(
            request: matching,
            currentProjectionRunID: runID,
            currentProjectionGeneration: 2,
            currentLatestSequence: 0,
            isUnread: true
        ) == .staleBoundary)
        #expect(RemoteAccessService.readAcknowledgementResult(
            request: matching,
            currentProjectionRunID: RemoteProjectionRunID(),
            currentProjectionGeneration: 2,
            currentLatestSequence: 8,
            isUnread: true
        ) == .staleBoundary)
        #expect(RemoteAccessService.readAcknowledgementResult(
            request: matching,
            currentProjectionRunID: runID,
            currentProjectionGeneration: 3,
            currentLatestSequence: 8,
            isUnread: true
        ) == .staleBoundary)
        #expect(RemoteAccessService.readAcknowledgementResult(
            request: matching,
            currentProjectionRunID: runID,
            currentProjectionGeneration: 2,
            currentLatestSequence: 9,
            isUnread: true
        ) == .staleBoundary)
        #expect(RemoteAccessService.readAcknowledgementResult(
            request: matching,
            currentProjectionRunID: runID,
            currentProjectionGeneration: 2,
            currentLatestSequence: 7,
            isUnread: true
        ) == .staleBoundary)
    }

    @Test func readAcknowledgementIsIdempotentAfterCurrentBoundaryIsRead() {
        let runID = RemoteProjectionRunID()
        let request = RemoteConversationReadAcknowledgementRequest(
            conversationID: RemoteConversationID(),
            projectionRunID: runID,
            projectionGeneration: 2,
            observedThroughSequence: 8
        )

        #expect(RemoteAccessService.readAcknowledgementResult(
            request: request,
            currentProjectionRunID: runID,
            currentProjectionGeneration: 2,
            currentLatestSequence: 8,
            isUnread: true
        ) == .acknowledged)
        #expect(RemoteAccessService.readAcknowledgementResult(
            request: request,
            currentProjectionRunID: runID,
            currentProjectionGeneration: 2,
            currentLatestSequence: 8,
            isUnread: false
        ) == .alreadyRead)
    }

    @Test func desktopSessionStatusMapsExactlyToRemotePresentationStatus() {
        let cases: [(SessionStatusKind, RemoteSessionPresentationStatus)] = [
            (.idle, .idle),
            (.working, .working),
            (.needsApproval, .needsApproval),
            (.ready, .ready),
            (.error, .error),
        ]

        for (desktop, remote) in cases {
            #expect(RemoteAccessService.remotePresentationStatus(for: desktop) == remote)
        }
    }

    @Test func transcriptReplacementExpiresPendingSendBeforeIdenticalHistoryReplay() throws {
        let conversationID = RemoteConversationID()
        let unaffectedConversationID = RemoteConversationID()
        let pendingText = "Please run the focused tests."
        var correlator = RemotePendingSendCorrelator()
        correlator.record(RemoteMessageSendRequest(
            conversationID: conversationID,
            clientRequestID: "new-request",
            expectedInputEpoch: RemoteInputEpoch(bindingID: UUID(), counter: 1),
            text: pendingText
        ))
        correlator.record(RemoteMessageSendRequest(
            conversationID: unaffectedConversationID,
            clientRequestID: "unaffected-request",
            expectedInputEpoch: RemoteInputEpoch(bindingID: UUID(), counter: 1),
            text: pendingText
        ))

        // `.fileReplaced` replays the transcript from byte zero. The service
        // invokes this expiration before it starts the replacement tailer.
        correlator.discard(for: conversationID)
        let replayed = correlator.stamp(
            [Self.userObservation(text: pendingText, fingerprint: "historical")],
            for: conversationID
        )
        let replayedPayload = try #require(Self.userPayload(from: replayed[0]))

        #expect(replayedPayload.origin == .unknown)
        #expect(replayedPayload.clientRequestID == nil)

        // Expiration is conversation-scoped, not a global correlation reset.
        let unaffected = correlator.stamp(
            [Self.userObservation(text: pendingText, fingerprint: "current")],
            for: unaffectedConversationID
        )
        let unaffectedPayload = try #require(Self.userPayload(from: unaffected[0]))
        #expect(unaffectedPayload.origin == .remote)
        #expect(unaffectedPayload.clientRequestID == "unaffected-request")
        #expect(unaffectedPayload.text == pendingText)
    }

    @Test func pendingSendCorrelationRemainsFIFOAndExpiresOldestMismatch() throws {
        let conversationID = RemoteConversationID()
        var correlator = RemotePendingSendCorrelator()
        correlator.record(Self.request(
            conversationID: conversationID,
            clientRequestID: "first-request",
            text: "first text"
        ))
        correlator.record(Self.request(
            conversationID: conversationID,
            clientRequestID: "second-request",
            text: "second text"
        ))

        let firstObservation = correlator.stamp(
            [Self.userObservation(text: "second text", fingerprint: "first-observation")],
            for: conversationID
        )
        let firstPayload = try #require(Self.userPayload(from: firstObservation[0]))
        #expect(firstPayload.origin == .unknown)
        #expect(firstPayload.clientRequestID == nil)

        let secondObservation = correlator.stamp(
            [Self.userObservation(text: "second text", fingerprint: "second-observation")],
            for: conversationID
        )
        let secondPayload = try #require(Self.userPayload(from: secondObservation[0]))
        #expect(secondPayload.origin == .remote)
        #expect(secondPayload.clientRequestID == "second-request")
    }

    @Test func pendingSendCorrelationRetainsOnlyNewestThirtyTwoRequests() throws {
        let conversationID = RemoteConversationID()
        var correlator = RemotePendingSendCorrelator()
        for index in 1...33 {
            correlator.record(Self.request(
                conversationID: conversationID,
                clientRequestID: "request-\(index)",
                text: "text \(index)"
            ))
        }

        let observation = correlator.stamp(
            [Self.userObservation(text: "text 2", fingerprint: "oldest-retained")],
            for: conversationID
        )
        let payload = try #require(Self.userPayload(from: observation[0]))
        #expect(payload.origin == .remote)
        #expect(payload.clientRequestID == "request-2")
    }

    @Test func finalPendingConsumptionRemovesConversationTrackingForMatchAndMismatch() {
        let matchingConversationID = RemoteConversationID()
        let mismatchingConversationID = RemoteConversationID()
        var correlator = RemotePendingSendCorrelator()
        correlator.record(Self.request(
            conversationID: matchingConversationID,
            clientRequestID: "matching-request",
            text: "matching text"
        ))
        correlator.record(Self.request(
            conversationID: mismatchingConversationID,
            clientRequestID: "mismatching-request",
            text: "expected text"
        ))

        _ = correlator.stamp(
            [Self.userObservation(text: "matching text", fingerprint: "match")],
            for: matchingConversationID
        )
        #expect(correlator.conversationIDs == Set([mismatchingConversationID]))

        _ = correlator.stamp(
            [Self.userObservation(text: "different text", fingerprint: "mismatch")],
            for: mismatchingConversationID
        )
        #expect(correlator.conversationIDs.isEmpty)
    }

    private static func request(
        conversationID: RemoteConversationID,
        clientRequestID: String,
        text: String
    ) -> RemoteMessageSendRequest {
        RemoteMessageSendRequest(
            conversationID: conversationID,
            clientRequestID: clientRequestID,
            expectedInputEpoch: RemoteInputEpoch(bindingID: UUID(), counter: 1),
            text: text
        )
    }

    private static func userObservation(
        text: String,
        fingerprint: String
    ) -> ProviderTranscriptObservation {
        ProviderTranscriptObservation(
            timestamp: Date(timeIntervalSince1970: 1_786_000_000),
            fingerprint: fingerprint,
            payload: .transcript(.userMessage(ConversationUserMessagePayload(
                text: text,
                origin: .unknown
            )))
        )
    }

    private static func userPayload(
        from observation: ProviderTranscriptObservation
    ) -> ConversationUserMessagePayload? {
        guard case .transcript(.userMessage(let payload)) = observation.payload else {
            return nil
        }
        return payload
    }
}
