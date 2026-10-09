#if DEBUG
import Foundation
import RemoteProtocol

enum ToasttyConversationFixture {
    enum SendEventOrder: String {
        case statusFirst = "status-first"
        case echoFirst = "echo-first"

        func hasWorkingStatus(after updateCount: Int) -> Bool {
            updateCount >= (self == .statusFirst ? 1 : 2) && updateCount < 5
        }

        func hasCanonicalEcho(after updateCount: Int) -> Bool {
            updateCount >= (self == .statusFirst ? 2 : 1)
        }
    }

    static let questionInteractionID = RemotePendingInteraction.ID(
        rawValue: "fixture-question-interaction"
    )
    static let questionResponseID = "fixture-question-response"
    static let questionEpoch = RemoteInputEpoch(
        bindingID: UUID(uuidString: "D1000000-0000-0000-0000-000000000099")!,
        counter: 12
    )
    static let questions = [
        RemoteInteractionQuestion(
            id: "0",
            header: "Approach",
            question: "Which implementation should Claude use?",
            options: [
                .init(
                    id: "0",
                    label: "Small change",
                    detail: "Keep the current data flow",
                    preview: "Controller → semantic request → host"
                ),
                .init(id: "1", label: "Broad refactor", detail: "Replace the surrounding feature"),
            ]
        ),
        RemoteInteractionQuestion(
            id: "1",
            header: "Checks",
            question: "Which checks should run?",
            options: [
                .init(id: "0", label: "Domain tests"),
                .init(id: "1", label: "UI test"),
                .init(id: "2", label: "Remote build"),
            ],
            multiSelect: true
        ),
        RemoteInteractionQuestion(
            id: "2",
            header: "Release note",
            question: "What should the release note say?",
            options: [
                .init(id: "0", label: "Use the standard note"),
                .init(id: "1", label: "Skip the note"),
            ]
        ),
    ]
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
                row(
                    conversationID,
                    7,
                    timestamp,
                    .interaction(ToasttyInteractionPresentation(interaction: resolvedInteraction))
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
                        text: "## Transcript ready\n\nKnown events render in sequence with **stable identity** and read-only interaction choices.\n\nOpen [docs/mobile-preview.md:12](docs/mobile-preview.md:12) or the [HTML sample](site/preview.html).",
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
                row(
                    conversationID,
                    14,
                    timestamp,
                    .interaction(ToasttyInteractionPresentation(interaction: currentInteraction))
                ),
            ],
            phase: phase,
            revision: .initial,
            historyTruncated: false
        )
    }

    static func responseEntryPresentation(
        for conversationID: UUID,
        hasWork: Bool,
        hasLongHistory: Bool
    ) -> ToasttyConversationPresentationState {
        let fixture = presentation(for: conversationID)
        let historyCount: UInt64 = hasLongHistory ? 200 : 0
        var rows: [ToasttyTranscriptRow] = (0 ..< historyCount).map { index in
            row(conversationID, index + 1, Date(timeIntervalSince1970: 1_786_406_400),
                .assistantMessage(text: "Earlier response \(index + 1)", phase: .final))
        }
        for original in fixture.rows {
            if hasWork, original.id.sequence == 13 {
                rows.append(row(conversationID, historyCount + 13, original.timestamp,
                    .toolStarted(callID: "response-check", name: "Read", detail: nil)))
                rows.append(row(conversationID, historyCount + 14, original.timestamp,
                    .toolFinished(callID: "response-check", name: "Read", outcome: .succeeded, detail: nil)))
            }
            rows.append(row(
                conversationID,
                historyCount + original.id.sequence + (hasWork && original.id.sequence >= 13 ? 2 : 0),
                original.timestamp,
                original.content
            ))
        }
        return ToasttyConversationPresentationState(
            rows: rows, phase: .live, revision: .initial, historyTruncated: false
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
        sendItems: [ToasttySendPresentationItem],
        hasShortResponse: Bool = false
    ) -> ToasttyConversationPresentationState {
        let fixture = presentation(for: conversationID)
        return ToasttyConversationPresentationState(
            rows: fixture.rows.filter { $0.id.sequence != 14 }.map { row in
                guard hasShortResponse, row.id.sequence == 13 else { return row }
                return ToasttyTranscriptRow(
                    id: row.id, timestamp: row.timestamp, provider: row.provider,
                    content: .assistantMessage(text: "The latest response is ready.", phase: .final)
                )
            },
            sendItems: sendItems,
            phase: .live,
            revision: sendItems.isEmpty ? .initial : .appended,
            historyTruncated: false
        )
    }

    static func reconciledSendPresentation(
        for conversationID: UUID,
        sendItems: [ToasttySendPresentationItem],
        sentText: String?,
        updateCount: Int,
        order: SendEventOrder
    ) -> ToasttyConversationPresentationState {
        let timestamp = Date(timeIntervalSince1970: 1_786_406_400)
        var rows = [
            row(conversationID, 1, timestamp, .userMessage(text: "Previous request", origin: .local)),
            row(conversationID, 2, timestamp, .assistantMessage(
                text: Array(repeating: "Earlier work details must stay collapsed during the next send.", count: 30)
                    .joined(separator: "\n\n"),
                phase: .commentary
            )),
            row(conversationID, 3, timestamp, .assistantMessage(text: "The previous request is complete.", phase: .final)),
        ]
        if let sentText, order.hasCanonicalEcho(after: updateCount) {
            rows.append(row(conversationID, 4, timestamp, .userMessage(text: sentText, origin: .remote)))
        }
        if updateCount >= 3 {
            rows.append(row(conversationID, 5, timestamp, .assistantMessage(text: "Working on the new request.", phase: .commentary)))
        }
        if updateCount >= 4 {
            rows.append(row(conversationID, 6, timestamp, .assistantMessage(text: "The new answer is ready.", phase: .final)))
        }
        let contentChanged = updateCount == (order == .statusFirst ? 2 : 1)
            || updateCount == 3 || updateCount == 4
        return ToasttyConversationPresentationState(
            rows: rows,
            sendItems: sendItems,
            phase: .live,
            revision: sentText == nil ? .initial : (contentChanged ? .appended : .metadataOnly),
            historyTruncated: false
        )
    }

    static func questionPresentation(
        for conversationID: UUID,
        answers: [RemoteInteractionAnswer]? = nil
    ) -> ToasttyConversationPresentationState {
        let timestamp = Date(timeIntervalSince1970: 1_786_406_400)
        let state: RemotePendingInteraction.State = answers == nil ? .pending : .resolved
        let interaction = RemotePendingInteraction(
            id: questionInteractionID,
            kind: .question,
            providerCallID: "fixture-question-call",
            prompt: "Claude needs your answers before it can continue.",
            inputEpoch: questionEpoch,
            presentedAt: timestamp,
            state: state,
            questions: questions,
            responseID: answers == nil ? questionResponseID : nil,
            responseExpiresAt: Date(timeIntervalSince1970: 1_786_410_000),
            answers: answers
        )
        var rows = [
            row(
                conversationID,
                1,
                timestamp,
                .assistantMessage(text: "I need a few choices before I continue.", phase: .commentary)
            ),
            row(
                conversationID,
                2,
                timestamp,
                .interaction(ToasttyInteractionPresentation(interaction: interaction))
            ),
        ]
        if answers != nil {
            rows.append(row(
                conversationID,
                3,
                timestamp,
                .interactionResolved(interactionID: questionInteractionID, resolution: .resolved)
            ))
        }
        return ToasttyConversationPresentationState(
            rows: rows,
            phase: .live,
            revision: answers == nil ? .initial : .appended,
            historyTruncated: false
        )
    }

    /// A conversation whose middle assistant message is far above the chunking
    /// threshold, exercising chunked rendering and live-edge jumps over a
    /// transcript dominated by one giant message.
    static func longMessagePresentation(
        for conversationID: UUID
    ) -> ToasttyConversationPresentationState {
        let timestamp = Date(timeIntervalSince1970: 1_786_406_400)
        // Big enough to split into several chunks, small enough that XCUITest
        // accessibility snapshots of the transcript stay fast.
        let sections = (1 ... 10).map { index in
            """
            ## Deep dive \(index)

            Chunked rendering keeps giant transcripts scrollable because every \
            slice is measured independently while the markdown stays valid \
            across the seams. Section \(index) repeats enough body text that \
            the message far exceeds a single chunk budget.
            """
        }
        let fence = (["```swift"]
            + (1 ... 30).map { "let fixtureValue\($0) = transcriptFixtureValue(\($0))" }
            + ["```"]).joined(separator: "\n")
        let giantMessage = (sections + [fence]).joined(separator: "\n\n")

        return ToasttyConversationPresentationState(
            rows: [
                row(conversationID, 1, timestamp, .sessionBindingChanged(reason: .runtimeBound)),
                row(
                    conversationID,
                    2,
                    timestamp,
                    .userMessage(text: "Walk me through the whole subsystem in detail.", origin: .local)
                ),
                row(conversationID, 3, timestamp, .assistantMessage(text: giantMessage, phase: .final)),
                row(
                    conversationID,
                    4,
                    timestamp,
                    .assistantMessage(text: "That covers every layer end to end.", phase: .final)
                ),
            ],
            phase: .live,
            revision: .initial,
            historyTruncated: false
        )
    }

    static func tablePresentation(
        for conversationID: UUID
    ) -> ToasttyConversationPresentationState {
        let timestamp = Date(timeIntervalSince1970: 1_786_406_400)
        let markdown = """
        ## Responsibility overview

        | Component | Responsibility |
        | :--- | :--- |
        | Gateway | Routes authenticated requests to the correct workspace. |
        | Mobile | Renders **conversation** updates and `send` results. |

        ## Wide comparison

        | Name | State | Count | Details |
        | :--- | :---: | ---: | :--- |
        | Alpha | Ready | 12 | Final column is readable. |
        | Beta | Waiting | 7 | All cells stay aligned. |
        """
        return ToasttyConversationPresentationState(
            rows: [row(conversationID, 1, timestamp, .assistantMessage(text: markdown, phase: .final))],
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
