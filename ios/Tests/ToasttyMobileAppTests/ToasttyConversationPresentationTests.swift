import Foundation
import RemoteProtocol
import XCTest
@testable import ToasttyMobileApp
@testable import ToasttyMobileDomain

final class ToasttyConversationPresentationTests: XCTestCase {
    func testAdapterRendersEveryKnownEventKindInSequenceAndDropsUnknownRows() throws {
        let state = ToasttyConversationPresentationAdapter.makeState(
            events: allKnownEventsWithUnknownMiddle(),
            projectionRunID: runID(1),
            projectionGeneration: 7,
            phase: .live,
            revision: .initial,
            historyTruncated: false
        )

        XCTAssertEqual(state.rows.map(\.id.sequence), Array(1...9).map(UInt64.init))
        XCTAssertEqual(state.rows.map(\.id.projectionRunID), Array(repeating: runID(1).rawValue, count: 9))
        XCTAssertEqual(state.rows.map(\.id.projectionGeneration), Array(repeating: 7, count: 9))
        XCTAssertEqual(state.rows.map(\.id.conversationID), Array(repeating: conversationID.rawValue, count: 9))
        XCTAssertFalse(state.rows.contains { [10, 11].contains($0.id.sequence) })

        guard case .userMessage(let text, let origin) = state.rows[0].content else {
            return XCTFail("Expected user message row")
        }
        XCTAssertEqual(text, "user")
        XCTAssertEqual(origin, .remote)

        guard case .assistantMessage(let text, let phase) = state.rows[1].content else {
            return XCTFail("Expected assistant message row")
        }
        XCTAssertEqual(text, "assistant")
        XCTAssertEqual(phase, .final)

        guard case .toolStarted(let callID, let name, let detail) = state.rows[2].content else {
            return XCTFail("Expected tool-start row")
        }
        XCTAssertEqual(callID, "call-1")
        XCTAssertEqual(name, "Read")
        XCTAssertEqual(detail, "input")

        guard case .toolFinished(let callID, let name, let outcome, let detail) = state.rows[3].content else {
            return XCTFail("Expected tool-finish row")
        }
        XCTAssertEqual(callID, "call-1")
        XCTAssertEqual(name, "Read", "A missing finish name must correlate to the earlier start")
        XCTAssertEqual(outcome, .succeeded)
        XCTAssertEqual(detail, "output")

        guard case .statusChanged(let status, let availability) = state.rows[4].content else {
            return XCTFail("Expected status row")
        }
        XCTAssertEqual(status, "waiting for input")
        XCTAssertEqual(availability, "interaction pending on Mac")

        guard case .interaction(let interaction) = state.rows[5].content else {
            return XCTFail("Expected interaction card")
        }
        XCTAssertEqual(interaction.id, interactionID)
        XCTAssertEqual(
            interaction.state,
            .resolved,
            "A later resolution must update the earlier card without reordering it"
        )

        guard case .interactionResolved(let resolvedID, let resolution) = state.rows[6].content else {
            return XCTFail("Expected interaction-resolution marker")
        }
        XCTAssertEqual(resolvedID, interactionID)
        XCTAssertEqual(resolution, .resolved)

        guard case .subagentSummary(let name, let phase, let detail) = state.rows[7].content else {
            return XCTFail("Expected subagent row")
        }
        XCTAssertEqual(name, "Verifier")
        XCTAssertEqual(phase, .updated)
        XCTAssertEqual(detail, "checked")

        guard case .sessionBindingChanged(let reason) = state.rows[8].content else {
            return XCTFail("Expected binding marker")
        }
        XCTAssertEqual(reason, .runtimeResumed)
    }

    func testRowIdentityChangesAcrossProjectionRunOrGenerationEvenWhenSequenceRepeats() throws {
        let event = knownEvent(
            sequence: 1,
            payload: .assistantMessage(.init(text: "same event", phase: .final))
        )
        let first = ToasttyConversationPresentationAdapter.makeState(
            events: [event],
            projectionRunID: runID(1),
            projectionGeneration: 7,
            phase: .live,
            revision: .initial,
            historyTruncated: false
        )
        let regenerated = ToasttyConversationPresentationAdapter.makeState(
            events: [event],
            projectionRunID: runID(1),
            projectionGeneration: 8,
            phase: .live,
            revision: .rebuilt,
            historyTruncated: false
        )
        let restarted = ToasttyConversationPresentationAdapter.makeState(
            events: [event],
            projectionRunID: runID(2),
            projectionGeneration: 8,
            phase: .live,
            revision: .rebuilt,
            historyTruncated: false
        )

        let firstID = try XCTUnwrap(first.rows.first?.id)
        let regeneratedID = try XCTUnwrap(regenerated.rows.first?.id)
        let restartedID = try XCTUnwrap(restarted.rows.first?.id)
        XCTAssertNotEqual(firstID, regeneratedID)
        XCTAssertEqual(firstID.projectionRunID, regeneratedID.projectionRunID)
        XCTAssertNotEqual(firstID.projectionGeneration, regeneratedID.projectionGeneration)
        XCTAssertEqual(firstID.conversationID, regeneratedID.conversationID)
        XCTAssertEqual(firstID.sequence, regeneratedID.sequence)
        XCTAssertEqual(firstID.accessibilitySuffix, regeneratedID.accessibilitySuffix)
        XCTAssertNotEqual(firstID, restartedID)
        XCTAssertEqual(firstID.conversationID, restartedID.conversationID)
        XCTAssertEqual(firstID.sequence, restartedID.sequence)
        XCTAssertNotEqual(firstID.projectionRunID, restartedID.projectionRunID)
    }

    func testFiveThousandRowsBecomePresentableWithinSimulatorFirstContentBudget() {
        let events = (1...5_000).map { sequence in
            knownEvent(
                sequence: UInt64(sequence),
                payload: .assistantMessage(.init(
                    text: "Deterministic presentation row \(sequence)",
                    phase: .final
                ))
            )
        }
        let clock = ContinuousClock()
        let start = clock.now

        let state = ToasttyConversationPresentationAdapter.makeState(
            events: events,
            projectionRunID: runID(1),
            projectionGeneration: 7,
            phase: .live,
            revision: .initial,
            historyTruncated: false
        )
        let elapsed = start.duration(to: clock.now)

        print("TOASTTY_TRANSCRIPT_PRESENTATION_PERFORMANCE rows=5000 elapsed=\(elapsed)")
        XCTAssertEqual(state.rows.count, 5_000)
        XCTAssertEqual(state.rows.first?.id.sequence, 1)
        XCTAssertEqual(state.rows.last?.id.sequence, 5_000)
        XCTAssertLessThanOrEqual(
            elapsed,
            .seconds(2),
            "Simulator presentation exceeded the first-content device target; physical rendering still requires Instruments validation."
        )
    }

    func testToolDisclosureStaysCollapsedUntilToggledAndHonorsExplicitState() throws {
        let historicalEvents: [CompatibleConversationEvent] = [
            knownEvent(
                sequence: 1,
                payload: .toolStarted(.init(
                    callID: "historical-call",
                    toolName: "Read",
                    detail: "input"
                ))
            ),
            knownEvent(
                sequence: 2,
                payload: .toolFinished(.init(
                    callID: "historical-call",
                    outcome: .succeeded,
                    detail: "output"
                ))
            ),
        ]
        let historical = ToasttyConversationPresentationAdapter.makeState(
            events: historicalEvents,
            projectionRunID: runID(1),
            projectionGeneration: 7,
            phase: .live,
            revision: .initial,
            historyTruncated: false
        )
        var disclosure = ToasttyToolBatchDisclosureState()
        disclosure.reconcile(
            activity: ToasttyToolBatchActivity.make(from: historical.blocks),
            revision: historical.revision
        )
        let historicalID = try XCTUnwrap(historical.blocks.first?.id)
        XCTAssertFalse(disclosure.isExpanded(historicalID))

        let appendedEvents = historicalEvents + [
            knownEvent(
                sequence: 3,
                payload: .assistantMessage(.init(text: "next step", phase: .final))
            ),
            knownEvent(
                sequence: 4,
                payload: .toolStarted(.init(
                    callID: "live-call",
                    toolName: "Build",
                    detail: "starting"
                ))
            ),
        ]
        let appendedStart = ToasttyConversationPresentationAdapter.makeState(
            events: appendedEvents,
            projectionRunID: runID(1),
            projectionGeneration: 7,
            phase: .live,
            revision: .appended,
            historyTruncated: false
        )
        disclosure.reconcile(
            activity: ToasttyToolBatchActivity.make(from: appendedStart.blocks),
            revision: appendedStart.revision
        )
        let liveID = try XCTUnwrap(appendedStart.blocks.last?.id)
        XCTAssertFalse(disclosure.isExpanded(historicalID))
        XCTAssertFalse(
            disclosure.isExpanded(liveID),
            "New live activity must not auto-expand its batch"
        )
        disclosure.toggle(liveID)
        XCTAssertTrue(disclosure.isExpanded(liveID))

        let finishedEvents = appendedEvents + [
            knownEvent(
                sequence: 5,
                payload: .toolFinished(.init(
                    callID: "live-call",
                    outcome: .succeeded,
                    detail: "finished"
                ))
            ),
        ]
        let appendedFinish = ToasttyConversationPresentationAdapter.makeState(
            events: finishedEvents,
            projectionRunID: runID(1),
            projectionGeneration: 7,
            phase: .live,
            revision: .appended,
            historyTruncated: false
        )
        disclosure.reconcile(
            activity: ToasttyToolBatchActivity.make(from: appendedFinish.blocks),
            revision: appendedFinish.revision
        )
        XCTAssertTrue(
            disclosure.isExpanded(liveID),
            "An expanded live batch must stay expanded as more rows arrive"
        )

        disclosure.toggle(liveID)
        XCTAssertFalse(disclosure.isExpanded(liveID))

        let appendedAfterCollapse = ToasttyConversationPresentationAdapter.makeState(
            events: finishedEvents + [
                knownEvent(
                    sequence: 6,
                    payload: .toolStarted(.init(
                        callID: "next-live-call",
                        toolName: "Test",
                        detail: "starting"
                    ))
                ),
            ],
            projectionRunID: runID(1),
            projectionGeneration: 7,
            phase: .live,
            revision: .appended,
            historyTruncated: false
        )
        disclosure.reconcile(
            activity: ToasttyToolBatchActivity.make(from: appendedAfterCollapse.blocks),
            revision: appendedAfterCollapse.revision
        )
        XCTAssertFalse(
            disclosure.isExpanded(liveID),
            "A user-collapsed live batch must stay collapsed as more rows arrive"
        )

        disclosure.toggle(liveID)
        XCTAssertTrue(disclosure.isExpanded(liveID))
    }

    func testLongAssistantMessageSplitsIntoStableChunkBlocks() throws {
        let giant = (1 ... 14).map { index in
            "Paragraph \(index): " + Array(repeating: "chunked transcript body", count: 20)
                .joined(separator: " ")
        }.joined(separator: "\n\n")
        XCTAssertGreaterThan(giant.count, ToasttyMarkdownChunking.chunkThreshold)

        let events = [
            knownEvent(sequence: 1, payload: .userMessage(.init(text: "user", origin: .local))),
            knownEvent(sequence: 2, payload: .assistantMessage(.init(text: giant, phase: .final))),
            knownEvent(sequence: 3, payload: .assistantMessage(.init(text: "tail", phase: .final))),
        ]
        let state = ToasttyConversationPresentationAdapter.makeState(
            events: events,
            projectionRunID: runID(1),
            projectionGeneration: 7,
            phase: .live,
            revision: .initial,
            historyTruncated: false
        )

        XCTAssertEqual(state.rows.count, 3)
        let chunkBlocks = state.blocks.filter { $0.id.rowID.sequence == 2 }
        XCTAssertGreaterThan(chunkBlocks.count, 1)
        XCTAssertEqual(chunkBlocks.map(\.id.chunkIndex), Array(0 ..< chunkBlocks.count))
        XCTAssertEqual(chunkBlocks.first?.id.accessibilitySuffix, "2")
        XCTAssertEqual(chunkBlocks[1].id.accessibilitySuffix, "2-c1")

        var recombined: [String] = []
        for (index, block) in chunkBlocks.enumerated() {
            guard case .messageChunk(let chunk) = block.content else {
                return XCTFail("Expected a message chunk block")
            }
            XCTAssertEqual(chunk.index, index)
            XCTAssertEqual(chunk.isLast, index == chunkBlocks.count - 1)
            XCTAssertEqual(chunk.row.id.sequence, 2)
            recombined.append(contentsOf: chunk.blocks.map { String($0.content.characters) })
        }
        XCTAssertEqual(recombined.joined(), ToasttyMarkdownParser.parse(giant).map { String($0.content.characters) }.joined())

        let short = try XCTUnwrap(state.blocks.last)
        guard case .row = short.content else {
            return XCTFail("A short assistant message must stay a single row block")
        }
        XCTAssertEqual(short.id.chunkIndex, 0)

        let regrouped = ToasttyConversationPresentationAdapter.makeState(
            events: events,
            projectionRunID: runID(1),
            projectionGeneration: 7,
            phase: .live,
            revision: .appended,
            historyTruncated: false
        )
        XCTAssertEqual(
            regrouped.blocks.map(\.id),
            state.blocks.map(\.id),
            "Chunk identity must be stable across regrouping of the same rows"
        )
    }

    private func allKnownEventsWithUnknownMiddle() -> [CompatibleConversationEvent] {
        let interaction = RemotePendingInteraction(
            id: interactionID,
            kind: .structuredChoice,
            prompt: "Choose on the Mac",
            inputEpoch: RemoteInputEpoch(bindingID: bindingID, counter: 1),
            presentedAt: Date(timeIntervalSince1970: 6),
            state: .pending
        )
        return [
            knownEvent(
                sequence: 1,
                payload: .userMessage(.init(text: "user", origin: .remote))
            ),
            knownEvent(
                sequence: 2,
                payload: .assistantMessage(.init(text: "assistant", phase: .final))
            ),
            knownEvent(
                sequence: 3,
                payload: .toolStarted(.init(callID: "call-1", toolName: "Read", detail: "input"))
            ),
            knownEvent(
                sequence: 4,
                payload: .toolFinished(.init(
                    callID: "call-1",
                    outcome: .succeeded,
                    detail: "output"
                ))
            ),
            knownEvent(
                sequence: 5,
                payload: .statusChanged(.init(
                    state: .awaitingInput,
                    inputAvailability: .pendingInteraction(interactionIDs: [interactionID])
                ))
            ),
            knownEvent(sequence: 6, payload: .interactionPresented(interaction)),
            knownEvent(
                sequence: 7,
                payload: .interactionResolved(.init(
                    interactionID: interactionID,
                    resolution: .resolved
                ))
            ),
            knownEvent(
                sequence: 8,
                payload: .subagentSummary(.init(
                    subagentID: "subagent-1",
                    displayName: "Verifier",
                    phase: .updated,
                    detail: "checked"
                ))
            ),
            knownEvent(
                sequence: 9,
                payload: .sessionBindingChanged(.init(reason: .runtimeResumed))
            ),
            knownEvent(
                sequence: 10,
                payload: .sendDeliveryUnconfirmed(.init(clientRequestID: "send-1"))
            ),
            .unknown(
                conversationID: conversationID,
                sequence: 11,
                kind: "future_optional_event"
            ),
        ]
    }

    private func knownEvent(
        sequence: UInt64,
        payload: ConversationEventPayload
    ) -> CompatibleConversationEvent {
        .known(ConversationEvent(
            conversationID: conversationID,
            sequence: sequence,
            eventID: "presentation-event-\(sequence)",
            timestamp: Date(timeIntervalSince1970: TimeInterval(sequence)),
            provider: .codex,
            payload: payload
        ))
    }

    private func runID(_ suffix: UInt8) -> RemoteProjectionRunID {
        RemoteProjectionRunID(rawValue: UUID(uuid: (
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, suffix
        )))
    }

    private var conversationID: RemoteConversationID {
        RemoteConversationID(
            rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
    }

    private var bindingID: UUID {
        UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    }

    private var interactionID: RemotePendingInteraction.ID {
        RemotePendingInteraction.ID(rawValue: "interaction-1")
    }
}
