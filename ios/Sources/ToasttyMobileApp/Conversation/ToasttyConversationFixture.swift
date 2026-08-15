#if DEBUG
import Foundation
import RemoteProtocol

enum ToasttyConversationFixture {
    private static let projectionRunID = UUID(
        uuidString: "D2000000-0000-0000-0000-000000000001"
    )!
    private static let projectionGeneration: UInt64 = 1

    static func presentation(
        for conversationID: UUID,
        phase: ToasttyConversationPresentationPhase = .live
    ) -> ToasttyConversationPresentationState {
        let timestamp = Date(timeIntervalSince1970: 1_786_406_400)
        let interactionID = RemotePendingInteraction.ID(rawValue: "fixture-interaction")
        let interaction = RemotePendingInteraction(
            id: interactionID,
            kind: .structuredChoice,
            providerCallID: "fixture-call",
            prompt: "Choose the safe rollout strategy on your Mac",
            options: [
                .init(id: "canary", label: "Canary", detail: "Roll out to one workspace first"),
                .init(id: "all", label: "All workspaces", detail: "Apply the change everywhere"),
            ],
            inputEpoch: RemoteInputEpoch(
                bindingID: UUID(uuidString: "D1000000-0000-0000-0000-000000000001")!,
                counter: 7
            ),
            presentedAt: timestamp,
            state: .pending
        )
        var resolvedInteraction = interaction
        resolvedInteraction.state = .resolved
        var currentInteraction = interaction
        currentInteraction.id = RemotePendingInteraction.ID(rawValue: "fixture-interaction-current")
        let longMessage = Array(
            repeating: "This deliberately long transcript fixture validates full rendering and dynamic layout.",
            count: 23
        ).joined(separator: " ") + " Full transcript tail remains visible."

        return ToasttyConversationPresentationState(
            rows: [
                row(conversationID, 1, timestamp, .sessionBindingChanged(reason: .runtimeBound)),
                row(
                    conversationID,
                    2,
                    timestamp,
                    .userMessage(
                        text: "Extract the gateway protocol and keep the mobile interaction surface read-only.",
                        origin: .local
                    )
                ),
                row(
                    conversationID,
                    3,
                    timestamp,
                    .assistantMessage(
                        text: "I’ll inspect the shared contract, then implement the transcript against stable journal sequences.",
                        phase: .commentary
                    )
                ),
                row(
                    conversationID,
                    4,
                    timestamp,
                    .toolStarted(
                        callID: "fixture-tool-1",
                        name: "Read",
                        detail: "Sources/RemoteProtocol/ConversationEvent.swift"
                    )
                ),
                row(
                    conversationID,
                    5,
                    timestamp,
                    .toolFinished(
                        callID: "fixture-tool-1",
                        name: "Read",
                        outcome: .succeeded,
                        detail: "Loaded 357 lines"
                    )
                ),
                row(
                    conversationID,
                    6,
                    timestamp,
                    .subagentSummary(
                        name: "Transcript QA",
                        phase: .updated,
                        detail: "Exercising every event kind and large Dynamic Type."
                    )
                ),
                row(conversationID, 7, timestamp, .interaction(resolvedInteraction)),
                row(
                    conversationID,
                    8,
                    timestamp,
                    .statusChanged(
                        state: "waiting for input",
                        availability: "interaction pending on Mac"
                    )
                ),
                row(
                    conversationID,
                    9,
                    timestamp,
                    .interactionResolved(interactionID: interactionID, resolution: .resolved)
                ),
                row(conversationID, 10, timestamp, .sessionBindingChanged(reason: .runtimeResumed)),
                row(
                    conversationID,
                    11,
                    timestamp,
                    .assistantMessage(
                        text: "## Transcript ready\n\nKnown events render in sequence with **stable identity** and read-only interaction choices.",
                        phase: .final
                    )
                ),
                row(
                    conversationID,
                    12,
                    timestamp,
                    .userMessage(text: "This message came from a paired mobile device.", origin: .remote)
                ),
                row(
                    conversationID,
                    13,
                    timestamp,
                    .assistantMessage(text: longMessage, phase: .final)
                ),
                row(conversationID, 14, timestamp, .interaction(currentInteraction)),
            ],
            phase: phase,
            revision: .initial,
            historyTruncated: false
        )
    }

    static func performancePresentation(
        for conversationID: UUID
    ) -> ToasttyConversationPresentationState {
        let timestamp = Date(timeIntervalSince1970: 1_786_406_400)
        let rows = (1 ... 5_000).map { sequence in
            row(
                conversationID,
                UInt64(sequence),
                timestamp,
                sequence.isMultiple(of: 3)
                    ? .userMessage(text: "Fixture user message \(sequence)", origin: .local)
                    : .assistantMessage(text: "Fixture assistant response \(sequence)", phase: .final)
            )
        }
        return ToasttyConversationPresentationState(
            rows: rows,
            phase: .live,
            revision: .initial,
            historyTruncated: false
        )
    }

    static func gatedSendPresentation(
        for conversationID: UUID,
        sendItems: [ToasttySendPresentationItem]
    ) -> ToasttyConversationPresentationState {
        let fixture = presentation(for: conversationID)
        return ToasttyConversationPresentationState(
            rows: fixture.rows.filter { $0.id.sequence != 14 },
            sendItems: sendItems,
            phase: .live,
            revision: .initial,
            historyTruncated: false
        )
    }

    static func toolActivityPresentation(
        for conversationID: UUID
    ) -> ToasttyConversationPresentationState {
        let fixture = presentation(for: conversationID)
        return ToasttyConversationPresentationState(
            rows: fixture.rows.filter { [4, 5].contains($0.id.sequence) },
            phase: .live,
            revision: .initial,
            historyTruncated: false
        )
    }

    static func truncatedPresentation(
        for conversationID: UUID
    ) -> ToasttyConversationPresentationState {
        let fixture = presentation(for: conversationID)
        return ToasttyConversationPresentationState(
            rows: fixture.rows,
            phase: fixture.phase,
            revision: fixture.revision,
            historyTruncated: true
        )
    }

    static func pagedPresentation(
        for conversationID: UUID,
        hasLoadedOlder: Bool
    ) -> ToasttyConversationPresentationState {
        let fixture = presentation(for: conversationID)
        let tailRows = Array(fixture.rows.suffix(6))
        return ToasttyConversationPresentationState(
            rows: hasLoadedOlder ? fixture.rows : tailRows,
            phase: fixture.phase,
            revision: hasLoadedOlder ? .prepended : .initial,
            historyTruncated: false,
            hasOlder: hasLoadedOlder == false,
            prependAnchorID: hasLoadedOlder ? tailRows.first?.id : nil
        )
    }

    private static func row(
        _ conversationID: UUID,
        _ sequence: UInt64,
        _ timestamp: Date,
        _ content: ToasttyTranscriptRow.Content
    ) -> ToasttyTranscriptRow {
        ToasttyTranscriptRow(
            id: ToasttyTranscriptRowID(
                projectionRunID: projectionRunID,
                projectionGeneration: projectionGeneration,
                conversationID: conversationID,
                sequence: sequence
            ),
            timestamp: timestamp.addingTimeInterval(TimeInterval(sequence)),
            provider: .codex,
            content: content
        )
    }
}
#endif
