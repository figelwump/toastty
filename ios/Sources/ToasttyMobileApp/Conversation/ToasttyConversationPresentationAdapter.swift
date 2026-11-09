import ConversationUI
import Foundation
import RemoteProtocol
import ToasttyMobileDomain

enum ToasttyConversationPresentationAdapter {
    static func makeState(
        events: [CompatibleConversationEvent],
        projectionRunID: RemoteProjectionRunID?,
        projectionGeneration: UInt64?,
        phase: ToasttyConversationPresentationPhase,
        revision: ToasttyTranscriptRevision,
        historyTruncated: Bool,
        sendItems: [ToasttySendPresentationItem] = [],
        hasOlder: Bool = false,
        isLoadingOlder: Bool = false,
        prependAnchorID: ToasttyTranscriptRowID? = nil
    ) -> ToasttyConversationPresentationState {
        let resolutions = interactionResolutions(in: events)
        let responseClosures = interactionResponseClosures(in: events)
        var toolNames: [String: String] = [:]
        let rows = events.compactMap { event -> ToasttyTranscriptRow? in
            switch event {
            case .unknown:
                return nil
            case .statusChanged:
                // Live status belongs in the header and composer, not chat history.
                return nil
            case .known(let value):
                let content: ToasttyTranscriptRow.Content
                switch value.payload {
                case .userMessage(let payload):
                    content = .userMessage(text: payload.text, origin: payload.origin, deliveryMode: payload.deliveryMode)
                case .assistantMessage(let payload):
                    content = .assistantMessage(text: payload.text, phase: payload.phase)
                case .toolStarted(let payload):
                    toolNames[payload.callID] = payload.toolName
                    content = .toolStarted(
                        callID: payload.callID,
                        name: payload.toolName,
                        detail: payload.detail
                    )
                case .toolFinished(let payload):
                    content = .toolFinished(
                        callID: payload.callID,
                        name: payload.toolName ?? toolNames[payload.callID] ?? "Tool",
                        outcome: payload.outcome,
                        detail: payload.detail
                    )
                case .statusChanged:
                    return nil
                case .interactionPresented(var payload):
                    if let resolution = resolutions[payload.id] {
                        payload.state = resolution.resolution
                        payload.answers = resolution.answers
                        payload.responseID = nil
                    } else if responseClosures[payload.id] != nil {
                        payload.responseID = nil
                    }
                    content = .interaction(ToasttyInteractionPresentation(
                        interaction: payload,
                        responseClosedReason: responseClosures[payload.id]
                    ))
                case .interactionResolved(let payload):
                    content = .interactionResolved(
                        interactionID: payload.interactionID,
                        resolution: payload.resolution
                    )
                case .interactionResponseClosed:
                    // The presented card carries the response-channel state.
                    // A second marker would imply that the native question ended.
                    return nil
                case .subagentSummary(let payload):
                    content = .subagentSummary(
                        name: payload.displayName,
                        phase: payload.phase,
                        detail: payload.detail
                    )
                case .sessionBindingChanged(let payload):
                    content = .sessionBindingChanged(reason: payload.reason)
                case .sendDeliveryUnconfirmed:
                    // Delivery receipts render through SendReconciliation so
                    // they stay attached to the optimistic outgoing message.
                    return nil
                }
                return ToasttyTranscriptRow(
                    id: rowID(
                        projectionRunID: projectionRunID,
                        projectionGeneration: projectionGeneration,
                        conversationID: value.conversationID,
                        sequence: value.sequence
                    ),
                    timestamp: value.timestamp,
                    provider: value.provider,
                    content: content
                )
            }
        }

        return ToasttyConversationPresentationState(
            rows: rows,
            sendItems: sendItems,
            phase: phase,
            revision: revision,
            historyTruncated: historyTruncated,
            hasOlder: hasOlder,
            isLoadingOlder: isLoadingOlder,
            prependAnchorID: prependAnchorID
        )
    }

    private static func interactionResolutions(
        in events: [CompatibleConversationEvent]
    ) -> [RemotePendingInteraction.ID: ConversationInteractionResolvedPayload] {
        events.reduce(into: [:]) { resolutions, event in
            guard case .known(let known) = event,
                  case .interactionResolved(let payload) = known.payload else { return }
            if let previous = resolutions[payload.interactionID],
               previous.resolution == .resolved {
                resolutions[payload.interactionID] = ConversationInteractionResolvedPayload(
                    interactionID: payload.interactionID,
                    resolution: .resolved,
                    answers: payload.answers ?? previous.answers
                )
            } else {
                resolutions[payload.interactionID] = ConversationInteractionResolvedPayload(
                    interactionID: payload.interactionID,
                    resolution: payload.resolution,
                    answers: payload.answers ?? resolutions[payload.interactionID]?.answers
                )
            }
        }
    }

    private static func interactionResponseClosures(
        in events: [CompatibleConversationEvent]
    ) -> [RemotePendingInteraction.ID: RemoteQuestionAnswerRejectionReason] {
        events.reduce(into: [:]) { closures, event in
            guard case .known(let known) = event else { return }
            switch known.payload {
            case .interactionResponseClosed(let payload):
                closures[payload.interactionID] = payload.reason
            case .interactionPresented(let payload):
                closures[payload.id] = nil
            case .interactionResolved(let payload):
                closures[payload.interactionID] = nil
            default:
                break
            }
        }
    }

    private static func rowID(
        projectionRunID: RemoteProjectionRunID?,
        projectionGeneration: UInt64?,
        conversationID: RemoteConversationID,
        sequence: UInt64
    ) -> ToasttyTranscriptRowID {
        ToasttyTranscriptRowID(
            projectionRunID: projectionRunID?.rawValue
                ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            projectionGeneration: projectionGeneration ?? 0,
            conversationID: conversationID.rawValue,
            sequence: sequence
        )
    }
}

extension ToasttyTranscriptSessionStatus {
    /// Every distinct host status gets its own epoch, so the transcript sees
    /// each status change.
    init(_ status: MobileSessionStatus) {
        let activity: Activity = switch status.bucket {
        case .ready: .ready
        case .working: .working
        case .error, .needsApproval, .idle: .other
        }
        switch status {
        case .known(let known):
            self.init(activity: activity, epoch: known.rawValue)
        case .unsupported(let rawValue):
            self.init(activity: activity, epoch: "unsupported:\(rawValue)")
        }
    }
}

extension ToasttyTranscriptWorkingIndicator.TurnElapsed {
    init(_ age: MobileActivityAge) {
        self.init(
            secondsAtReceipt: age.secondsAtReceipt,
            receivedAtMonotonicTime: age.receivedAtMonotonicTime
        )
    }
}
