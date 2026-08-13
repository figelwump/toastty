import RemoteProtocol
import Foundation
import Testing
@testable import CoreState

struct ConversationEventCodingTests {
    static let conversationID = RemoteConversationID(rawValue: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!)
    static let bindingID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
    static let timestamp = Date(timeIntervalSince1970: 1_786_000_805.25)

    static func makeEvent(_ payload: ConversationEventPayload, turnID: String? = nil) -> ConversationEvent {
        ConversationEvent(
            conversationID: conversationID,
            sequence: 7,
            eventID: "codex:test",
            timestamp: timestamp,
            provider: .codex,
            providerIdentity: "msg_test",
            turnID: turnID,
            payload: payload
        )
    }

    static let samplePayloads: [ConversationEventPayload] = [
        .userMessage(ConversationUserMessagePayload(text: "hello", origin: .remote, clientRequestID: "req-1")),
        .assistantMessage(ConversationAssistantMessagePayload(text: "hi", phase: .final)),
        .toolStarted(ConversationToolStartedPayload(callID: "call_1", toolName: "exec_command", detail: "ls")),
        .toolFinished(ConversationToolFinishedPayload(callID: "call_1", toolName: "exec_command", outcome: .succeeded, detail: "ok")),
        .statusChanged(ConversationStatusChangedPayload(
            state: .awaitingInput,
            inputAvailability: .openPrompt(epoch: RemoteInputEpoch(bindingID: bindingID, counter: 3))
        )),
        .interactionPresented(RemotePendingInteraction(
            id: RemotePendingInteraction.ID(rawValue: "codex:approval:appr_1"),
            kind: .permission,
            providerCallID: "call_1",
            providerApprovalID: "appr_1",
            prompt: "Approve rm -rf build",
            inputEpoch: RemoteInputEpoch(bindingID: bindingID, counter: 2),
            presentedAt: timestamp
        )),
        .interactionResolved(ConversationInteractionResolvedPayload(
            interactionID: RemotePendingInteraction.ID(rawValue: "codex:approval:appr_1"),
            resolution: .superseded
        )),
        .subagentSummary(ConversationSubagentSummaryPayload(
            subagentID: "thread-1",
            displayName: "audit_worker",
            phase: .started,
            detail: "/root/audit_worker"
        )),
        .sessionBindingChanged(ConversationSessionBindingChangedPayload(
            reason: .runtimeResumed,
            providerSessionID: "0190-session",
            providerSessionFilePath: "/tmp/rollout.jsonl"
        )),
    ]

    @Test func everyEventKindRoundTripsThroughWireJSON() throws {
        let encoder = ConversationEventCoding.makeEncoder()
        let decoder = ConversationEventCoding.makeDecoder()
        for payload in Self.samplePayloads {
            let event = Self.makeEvent(payload, turnID: "turn-1")
            let data = try encoder.encode(event)
            let decoded = try decoder.decode(ConversationEvent.self, from: data)
            #expect(decoded == event)
        }
    }

    @Test func wireDiscriminatorsAreSnakeCase() throws {
        let encoder = ConversationEventCoding.makeEncoder()
        var kindStrings: Set<String> = []
        for payload in Self.samplePayloads {
            let data = try encoder.encode(Self.makeEvent(payload))
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            kindStrings.insert(try #require(object["kind"] as? String))
        }
        #expect(kindStrings == [
            "user_message",
            "assistant_message",
            "tool_started",
            "tool_finished",
            "status_changed",
            "interaction_presented",
            "interaction_resolved",
            "subagent_summary",
            "session_binding_changed",
        ])
    }

    @Test func timestampsEncodeAsFractionalISO8601() throws {
        let encoder = ConversationEventCoding.makeEncoder()
        let data = try encoder.encode(Self.makeEvent(Self.samplePayloads[0]))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(#""timestamp":"2026-08-06T07:20:05.250Z""#))
    }

    @Test func availabilityCasesEncodeSnakeCaseKinds() throws {
        let encoder = ConversationEventCoding.makeEncoder()
        let decoder = ConversationEventCoding.makeDecoder()
        let epoch = RemoteInputEpoch(bindingID: Self.bindingID, counter: 4)
        let cases: [(RemoteInputAvailability, String)] = [
            (.unavailable(reason: .unknownProviderState), #""kind":"unavailable""#),
            (.unavailable(reason: .sessionWritesDisabled), #""reason":"session_writes_disabled""#),
            (.openPrompt(epoch: epoch), #""kind":"open_prompt""#),
            (.pendingInteraction(interactionIDs: [RemotePendingInteraction.ID(rawValue: "codex:call:c1")]), #""kind":"pending_interaction""#),
            (.localDraft(epoch: epoch), #""kind":"local_draft""#),
        ]
        for (availability, expectedFragment) in cases {
            let data = try encoder.encode(availability)
            let json = try #require(String(data: data, encoding: .utf8))
            #expect(json.contains(expectedFragment))
            let decoded = try decoder.decode(RemoteInputAvailability.self, from: data)
            #expect(decoded == availability)
        }
        let unavailableJSON = try #require(String(
            data: try encoder.encode(RemoteInputAvailability.unavailable(reason: .unknownProviderState)),
            encoding: .utf8
        ))
        #expect(unavailableJSON.contains(#""reason":"unknown_provider_state""#))
    }

    @Test func decoderAcceptsWholeSecondTimestamps() throws {
        let decoder = ConversationEventCoding.makeDecoder()
        let json = #"{"bindingID":"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB","counter":1}"#
        let epoch = try decoder.decode(RemoteInputEpoch.self, from: Data(json.utf8))
        #expect(epoch.counter == 1)

        struct Dated: Codable, Equatable {
            var at: Date
        }
        let whole = try decoder.decode(Dated.self, from: Data(#"{"at":"2026-08-06T07:20:05Z"}"#.utf8))
        #expect(whole.at == Date(timeIntervalSince1970: 1_786_000_805))
    }

    @Test func conversationReadAcknowledgementModelsRoundTrip() throws {
        let encoder = ConversationEventCoding.makeEncoder()
        let decoder = ConversationEventCoding.makeDecoder()
        let request = RemoteConversationReadAcknowledgementRequest(
            conversationID: Self.conversationID,
            projectionRunID: RemoteProjectionRunID(
                rawValue: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
            ),
            projectionGeneration: 4,
            observedThroughSequence: 19
        )
        #expect(try decoder.decode(
            RemoteConversationReadAcknowledgementRequest.self,
            from: encoder.encode(request)
        ) == request)

        for result in [
            RemoteConversationReadAcknowledgementResult.acknowledged,
            .alreadyRead,
            .staleBoundary,
            .conversationNotFound,
        ] {
            let response = RemoteConversationReadAcknowledgementResponse(result: result)
            #expect(try decoder.decode(
                RemoteConversationReadAcknowledgementResponse.self,
                from: encoder.encode(response)
            ) == response)
        }
    }

    @Test func snapshotAndPageModelsRoundTrip() throws {
        let encoder = ConversationEventCoding.makeEncoder()
        let decoder = ConversationEventCoding.makeDecoder()

        let summary = RemoteConversationSummary(
            conversationID: Self.conversationID,
            provider: .codex,
            title: "Sync job work",
            placement: RemoteConversationPlacement(workspaceID: UUID(), panelID: UUID()),
            cwd: "/tmp/demo",
            state: .awaitingInput,
            presentationStatus: .needsApproval,
            inputAvailability: .openPrompt(epoch: RemoteInputEpoch(bindingID: Self.bindingID, counter: 1)),
            projectionGeneration: 2,
            latestSequence: 41,
            updatedAt: Self.timestamp
        )
        let encodedSummary = try encoder.encode(summary)
        let encodedSummaryJSON = try #require(String(data: encodedSummary, encoding: .utf8))
        #expect(encodedSummaryJSON.contains(#""presentationStatus":"needs_approval""#))
        #expect(try decoder.decode(RemoteConversationSummary.self, from: encodedSummary) == summary)

        var legacySummary = summary
        legacySummary.presentationStatus = nil
        let legacySummaryJSON = try #require(String(
            data: try encoder.encode(legacySummary),
            encoding: .utf8
        ))
        #expect(legacySummaryJSON.contains("presentationStatus") == false)

        let snapshot = RemoteSessionListSnapshot(
            projectionRunID: RemoteProjectionRunID(),
            conversations: [summary],
            generatedAt: Self.timestamp
        )
        let decodedSnapshot = try decoder.decode(
            RemoteSessionListSnapshot.self,
            from: try encoder.encode(snapshot)
        )
        #expect(decodedSnapshot == snapshot)

        let page = ConversationEventPage(
            conversationID: Self.conversationID,
            projectionRunID: snapshot.projectionRunID,
            projectionGeneration: 2,
            events: [Self.makeEvent(Self.samplePayloads[0])],
            latestSequence: 41
        )
        let decodedPage = try decoder.decode(
            ConversationEventPage.self,
            from: try encoder.encode(page)
        )
        #expect(decodedPage == page)
        #expect(decodedPage.continuationCursor?.afterSequence == 7)
        #expect(decodedPage.continuationCursor?.projectionGeneration == 2)
    }
}
