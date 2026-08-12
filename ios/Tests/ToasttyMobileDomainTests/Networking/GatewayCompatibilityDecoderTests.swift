import Foundation
import RemoteProtocol
import XCTest
@testable import ToasttyMobileDomain

final class GatewayCompatibilityDecoderTests: XCTestCase {
    private let decoder = GatewayCompatibilityDecoder()

    func testEventPagePreservesWireOrderForInvariantValidation() throws {
        let data = Data(#"{"outcome":"page","page":{"conversationID":"11111111-1111-1111-1111-111111111111","events":[{"conversationID":"11111111-1111-1111-1111-111111111111","eventID":"two","kind":"future_optional_event","payload":{},"provider":"codex","schemaVersion":1,"sequence":2,"timestamp":"2026-08-08T14:40:00.125Z"},{"conversationID":"11111111-1111-1111-1111-111111111111","eventID":"one","kind":"future_optional_event","payload":{},"provider":"codex","schemaVersion":1,"sequence":1,"timestamp":"2026-08-08T14:40:00.125Z"}],"firstAvailableSequence":1,"historyTruncated":false,"latestSequence":2,"projectionGeneration":7,"projectionRunID":"22222222-2222-2222-2222-222222222222"},"protocolVersion":"1.0"}"#.utf8)

        guard case .page(let page) = try decoder.decodeEventsResponse(data) else {
            return XCTFail("Expected page")
        }
        XCTAssertEqual(page.events.map(\.sequence), [2, 1])
    }

    func testCanonicalTranscriptFixtureCoversEveryKnownEventKindInStableOrder() throws {
        let bundle = Bundle(for: Self.self)
        let fixtureURL = try XCTUnwrap(
            bundle.url(
                forResource: "events-response-page",
                withExtension: "json",
                subdirectory: "v1"
            )
        )
        let response = try decoder.decodeEventsResponse(Data(contentsOf: fixtureURL))
        guard case .page(let page) = response else { return XCTFail("Expected canonical event page") }

        XCTAssertEqual(page.events.map(\.sequence), Array(1...37).map(UInt64.init))
        XCTAssertEqual(
            Set(page.events.map(\.kind)),
            Set([
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
        )

        let knownEventsBySequence = Dictionary(uniqueKeysWithValues: page.events.compactMap { event -> (UInt64, ConversationEvent)? in
            guard case .known(let known) = event else { return nil }
            return (known.sequence, known)
        })

        let first = try XCTUnwrap(knownEventsBySequence[1])
        XCTAssertEqual(first.eventID, "fixture:event:1")
        guard case .userMessage(let user) = first.payload else {
            return XCTFail("Sequence 1 must remain a user message")
        }
        XCTAssertEqual(user.text, "User message from local")
        XCTAssertEqual(user.origin, .local)
        XCTAssertNil(user.clientRequestID)

        guard case .statusChanged(let status) = page.events[11] else {
            return XCTFail("Sequence 12 must remain a compatible status change")
        }
        XCTAssertEqual(status.sequence, 12)
        XCTAssertEqual(status.state, .starting)
        XCTAssertEqual(status.inputAvailability, .unavailable(reason: .known(.starting)))

        let interactionEvent = try XCTUnwrap(knownEventsBySequence[23])
        XCTAssertEqual(interactionEvent.eventID, "fixture:event:23")
        guard case .interactionPresented(let interaction) = interactionEvent.payload else {
            return XCTFail("Sequence 23 must remain an interaction card")
        }
        XCTAssertEqual(interaction.id.rawValue, "interaction-permission")
        XCTAssertEqual(interaction.kind, .permission)
        XCTAssertEqual(interaction.state, .pending)

        let bindingEvent = try XCTUnwrap(knownEventsBySequence[37])
        XCTAssertEqual(bindingEvent.eventID, "fixture:event:37")
        guard case .sessionBindingChanged(let binding) = bindingEvent.payload else {
            return XCTFail("Sequence 37 must remain a binding change")
        }
        XCTAssertEqual(binding.reason, .projectionRebuilt)
    }

    func testVersionMismatchFailsAdmission() throws {
        XCTAssertThrowsError(try decoder.decodeHello(CompatibilityFixture.data("version-mismatch"))) { error in
            XCTAssertEqual(error as? GatewayCompatibilityError, .unsupportedProtocolVersion("2.0"))
        }
    }

    func testHelloIgnoresUnknownAdditiveCapabilities() throws {
        let data = Data(#"{"protocolVersion":"1.0","minimumSupportedProtocolVersion":"1.0","capabilities":["native_bearer_pairing","future_optional_capability","conversation_backward_paging"]}"#.utf8)

        let hello = try decoder.decodeHello(data)

        XCTAssertEqual(
            hello.capabilities,
            [.nativeBearerPairing, .conversationBackwardPaging]
        )
    }

    func testUnknownTopLevelStreamMessageIsIgnored() throws {
        XCTAssertEqual(
            try decoder.decodeStreamMessage(CompatibilityFixture.data("stream-unknown-top-level")),
            .ignoredUnknown(type: "future_notification")
        )
    }

    func testRESTPagePreservesUnknownMiddleEventAndCursorProgress() throws {
        let response = try decoder.decodeEventsResponse(CompatibilityFixture.data("events-unknown-middle"))
        guard case .page(let page) = response else { return XCTFail("Expected page") }

        XCTAssertEqual(page.events.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(page.events[1].kind, "future_optional_event")
        XCTAssertEqual(page.continuationCursor?.afterSequence, 3)
        guard case .unknown(let conversationID, 2, "future_optional_event") = page.events[1] else {
            return XCTFail("Expected compatible unknown event")
        }
        XCTAssertEqual(conversationID.rawValue.uuidString, "11111111-1111-1111-1111-111111111111")
    }

    func testUnknownEventBetweenStatusAndInteractionKeepsBothSemanticNeighbors() throws {
        let response = try decoder.decodeEventsResponse(
            CompatibilityFixture.data("events-unknown-between-status-interaction")
        )
        guard case .page(let page) = response else {
            return XCTFail("Expected a compatible page")
        }

        XCTAssertEqual(page.events.map(\.sequence), [1, 2, 3])
        guard case .statusChanged = page.events[0],
              case .unknown(_, 2, "future_optional_event") = page.events[1],
              case .known(let interaction) = page.events[2] else {
            return XCTFail("Expected status, unknown, and known interaction neighbors")
        }
        XCTAssertEqual(interaction.kind, .interactionPresented)
        XCTAssertEqual(page.continuationCursor?.afterSequence, 3)
    }

    func testStreamUsesSameTolerantPageDecoder() throws {
        let message = try decoder.decodeStreamMessage(CompatibilityFixture.data("stream-unknown-middle"))
        guard case .conversationEvents(let page) = message else { return XCTFail("Expected event page") }

        XCTAssertEqual(page.events.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(page.events[1].kind, "future_optional_event")
    }

    func testKnownStatusChangedPreservesUnknownDisplayAndInputDiscriminators() throws {
        let response = try decoder.decodeEventsResponse(CompatibilityFixture.data("status-unknown-discriminators"))
        guard case .page(let page) = response, page.events.count == 2 else {
            return XCTFail("Expected two status events")
        }
        guard case .statusChanged(let first) = page.events[0] else {
            return XCTFail("Expected compatible status event")
        }
        XCTAssertEqual(first.state, .unsupported(rawValue: "future_display_state"))
        XCTAssertEqual(
            first.inputAvailability,
            .unavailable(reason: .unsupported(rawValue: "future_lock_reason"))
        )
        XCTAssertFalse(first.inputAvailability.allowsRemoteSend)

        guard case .statusChanged(let second) = page.events[1] else {
            return XCTFail("Expected compatible status event")
        }
        XCTAssertEqual(second.inputAvailability, .unsupported(rawKind: "future_input_mode"))
        XCTAssertFalse(second.inputAvailability.allowsRemoteSend)
    }

    func testSessionSnapshotRetainsMetadataAndUnknownRawValuesReadOnly() throws {
        let snapshot = try decoder.decodeSessionListResponse(
            CompatibilityFixture.data("session-unknown-display-input")
        )
        let summary = try XCTUnwrap(snapshot.conversations.first)

        XCTAssertEqual(snapshot.projectionRunID.rawValue.uuidString, "22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(summary.projectionGeneration, UInt64.max)
        XCTAssertEqual(summary.latestSequence, UInt64.max)
        XCTAssertEqual(summary.state, .unsupported(rawValue: "future_display_state"))
        XCTAssertEqual(summary.inputAvailability, .unsupported(rawKind: "future_input_mode"))
        XCTAssertFalse(summary.inputAvailability.allowsRemoteSend)

        let presentation = snapshot.presentation(hostName: "test-mac")
        let mobile = try XCTUnwrap(presentation.workspaces.first?.conversations.first)
        XCTAssertEqual(mobile.state, .unsupported(rawValue: "future_display_state"))
        XCTAssertFalse(mobile.inputAvailability.allowsReply)
    }

    func testUnavailableReasonRecognizesSessionPolicyAndKeepsFutureReasonsReadOnly() throws {
        let disabledData = try sessionSnapshotData(
            inputAvailability: [
                "kind": "unavailable",
                "reason": "session_writes_disabled",
            ],
            preview: NSNull()
        )
        let disabled = try XCTUnwrap(
            decoder.decodeSessionListResponse(disabledData).conversations.first
        )
        XCTAssertEqual(
            disabled.inputAvailability,
            .unavailable(reason: .known(.sessionWritesDisabled))
        )
        XCTAssertFalse(disabled.inputAvailability.allowsRemoteSend)

        let futureData = try sessionSnapshotData(
            inputAvailability: [
                "kind": "unavailable",
                "reason": "future_policy_lock",
            ],
            preview: NSNull()
        )
        let future = try XCTUnwrap(
            decoder.decodeSessionListResponse(futureData).conversations.first
        )
        XCTAssertEqual(
            future.inputAvailability,
            .unavailable(reason: .unsupported(rawValue: "future_policy_lock"))
        )
        XCTAssertFalse(future.inputAvailability.allowsRemoteSend)
        XCTAssertFalse(future.inputAvailability.presentation().allowsReply)
    }

    func testCanonicalSessionStateAndInputCombinationsRemainIndependent() throws {
        let bundle = Bundle(for: Self.self)
        let fixtureURL = try XCTUnwrap(
            bundle.url(
                forResource: "session-list-response",
                withExtension: "json",
                subdirectory: "v1"
            )
        )
        let snapshot = try decoder.decodeSessionListResponse(Data(contentsOf: fixtureURL))

        XCTAssertEqual(snapshot.conversations.count, 11)
        let expectedStates: [MobileSessionDisplayState] = [
            .starting, .working, .awaitingInput, .ready,
            .interrupted, .ended, .error, .offline,
        ]
        for state in expectedStates {
            XCTAssertTrue(snapshot.conversations.contains { $0.state == state })
        }
        XCTAssertEqual(
            snapshot.conversations.filter { $0.inputAvailability.allowsRemoteSend }.count,
            1,
            "Only the exact open-prompt availability enables a send, independently of display state."
        )
        let claude = try XCTUnwrap(snapshot.conversations.first {
            $0.provider == .claude
                && $0.inputAvailability == .unavailable(reason: .known(.unknownProviderState))
        })
        XCTAssertFalse(claude.inputAvailability.allowsRemoteSend)
    }

    func testUnexpectedKnownStateWithOpenPromptPreservesBothFacts() throws {
        let data = Data(
            #"{"protocolVersion":"1.0","snapshot":{"conversations":[{"conversationID":"11111111-1111-1111-1111-111111111111","inputAvailability":{"epoch":{"bindingID":"33333333-3333-3333-3333-333333333333","counter":9},"kind":"open_prompt"},"latestSequence":1,"placement":{},"projectionGeneration":1,"provider":"codex","state":"working","title":"Unexpected combination","updatedAt":"2026-08-08T14:40:00.125Z"}],"generatedAt":"2026-08-08T14:41:00.125Z","projectionRunID":"22222222-2222-2222-2222-222222222222"}}"#.utf8
        )
        let summary = try XCTUnwrap(decoder.decodeSessionListResponse(data).conversations.first)

        XCTAssertEqual(summary.state, .working)
        guard case .openPrompt(let epoch) = summary.inputAvailability else {
            return XCTFail("Expected the exact open-prompt epoch to survive")
        }
        XCTAssertEqual(epoch.counter, 9)
        XCTAssertTrue(summary.inputAvailability.allowsRemoteSend)
    }

    func testPendingInteractionPreviewFlowsIntoPresentationOnlyForPendingInteraction() throws {
        let preview = try JSONSerialization.jsonObject(
            with: fixtureData(named: "pending-interaction-preview")
        ) as! [String: Any]
        let data = try sessionSnapshotData(
            inputAvailability: ["kind": "pending_interaction", "interactionIDs": ["approval-1"]],
            preview: preview
        )

        let snapshot = try decoder.decodeSessionListResponse(data)
        let summary = try XCTUnwrap(snapshot.conversations.first)
        XCTAssertEqual(summary.pendingInteractionPreview?.prompt, "Approve the gateway command on the Mac")
        let mobile = try XCTUnwrap(snapshot.presentation().workspaces.first?.conversations.first)
        XCTAssertEqual(mobile.inputAvailability, .pendingInteraction(preview: "Approve the gateway command on the Mac"))

        let openPromptData = try sessionSnapshotData(
            inputAvailability: [
                "kind": "open_prompt",
                "epoch": ["bindingID": "33333333-3333-3333-3333-333333333333", "counter": 1],
            ],
            preview: preview
        )
        let openPrompt = try XCTUnwrap(decoder.decodeSessionListResponse(openPromptData).conversations.first)
        XCTAssertNil(openPrompt.pendingInteractionPreview)
        XCTAssertEqual(openPrompt.inputAvailability.presentation(), .openPrompt)
    }

    func testMalformedOptionalPendingPreviewDoesNotDestroySnapshot() throws {
        for malformed: Any in [
            ["prompt": String(repeating: "x", count: 241)],
            ["prompt": "misleading\u{202E}text"],
            ["future": true],
            "future-shape",
        ] {
            let data = try sessionSnapshotData(
                inputAvailability: ["kind": "pending_interaction", "interactionIDs": ["approval-1"]],
                preview: malformed
            )
            let snapshot = try decoder.decodeSessionListResponse(data)
            let summary = try XCTUnwrap(snapshot.conversations.first)
            XCTAssertNil(summary.pendingInteractionPreview)
            XCTAssertEqual(summary.inputAvailability.presentation(), .pendingInteraction(preview: nil))
        }
    }

    func testPresentationUsesIdentifiersAsDuplicateTitleTiebreaks() {
        let timestamp = Date(timeIntervalSince1970: 1_786_200_000)
        let summaries = [
            compatibleSummary(conversation: "00000000-0000-0000-0000-000000000004", workspace: "00000000-0000-0000-0000-000000000002"),
            compatibleSummary(conversation: "00000000-0000-0000-0000-000000000003", workspace: "00000000-0000-0000-0000-000000000001"),
            compatibleSummary(conversation: "00000000-0000-0000-0000-000000000002", workspace: "00000000-0000-0000-0000-000000000001"),
        ]
        let snapshot = CompatibleSessionListSnapshot(
            projectionRunID: RemoteProjectionRunID(rawValue: UUID()),
            conversations: summaries,
            generatedAt: timestamp
        ).presentation()

        XCTAssertEqual(snapshot.workspaces.map(\.id.uuidString), [
            "00000000-0000-0000-0000-000000000001",
            "00000000-0000-0000-0000-000000000002",
        ])
        XCTAssertEqual(snapshot.workspaces[0].conversations.map(\.id.uuidString), [
            "00000000-0000-0000-0000-000000000002",
            "00000000-0000-0000-0000-000000000003",
        ])
    }

    func testUnknownSendStatusAndRejectionReasonFailOnlySendDecode() throws {
        XCTAssertThrowsError(try decoder.decodeSendResult(CompatibilityFixture.data("send-unknown-status"))) { error in
            XCTAssertEqual(error as? GatewayCompatibilityError, .unsupportedSendStatus("scheduled_for_future"))
        }
        XCTAssertThrowsError(try decoder.decodeSendResult(CompatibilityFixture.data("send-unknown-reason"))) { error in
            XCTAssertEqual(error as? GatewayCompatibilityError, .unsupportedSendRejectionReason("future_policy"))
        }
    }

    private func fixtureData(named name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: "json", subdirectory: "v1")
        )
        return try Data(contentsOf: url)
    }

    private func sessionSnapshotData(
        inputAvailability: [String: Any],
        preview: Any
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "protocolVersion": "1.0",
            "snapshot": [
                "projectionRunID": "22222222-2222-2222-2222-222222222222",
                "generatedAt": "2026-08-08T14:41:00.125Z",
                "conversations": [[
                    "conversationID": "11111111-1111-1111-1111-111111111111",
                    "provider": "codex",
                    "title": "Needs review",
                    "placement": [:],
                    "state": "awaiting_input",
                    "inputAvailability": inputAvailability,
                    "pendingInteractionPreview": preview,
                    "projectionGeneration": 1,
                    "latestSequence": 1,
                    "updatedAt": "2026-08-08T14:40:00.125Z",
                ]],
            ],
        ], options: [.sortedKeys])
    }

    private func compatibleSummary(conversation: String, workspace: String) -> CompatibleConversationSummary {
        CompatibleConversationSummary(
            conversationID: RemoteConversationID(rawValue: UUID(uuidString: conversation)!),
            provider: .codex,
            title: "Duplicate",
            placement: RemoteConversationPlacement(
                workspaceID: UUID(uuidString: workspace)!,
                workspaceTitle: "Duplicate"
            ),
            cwd: nil,
            state: .ready,
            inputAvailability: .unavailable(reason: .known(.ended)),
            projectionGeneration: 1,
            latestSequence: 1,
            updatedAt: Date(timeIntervalSince1970: 1_786_200_000)
        )
    }
}
