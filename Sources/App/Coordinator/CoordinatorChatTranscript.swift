import ConversationUI
import CoreState
import Foundation
import RemoteProtocol

/// Turns the coordinator's conversation events into the rows the shared
/// transcript draws.
///
/// The iPhone has its own adapter, over the events it decodes from the
/// gateway. This one differs in three ways: a digest that Toastty typed,
/// and a message that `coordinator send` brought, become one folded line;
/// a quick entry message shows without Toastty's first line; and a message
/// this Mac sent is not marked as sent from another device.
// TODO: Share the event-to-row mapping with the iPhone's
// `ToasttyConversationPresentationAdapter` once the iPhone can take it.
enum CoordinatorChatTranscript {
    static func rows(
        from events: [ConversationEvent],
        projectionRunID: RemoteProjectionRunID,
        projectionGeneration: UInt64,
        isSentFromThisMac: (String) -> Bool,
        timeText: (Date) -> String
    ) -> [ToasttyTranscriptRow] {
        let resolutions = interactionResolutions(in: events)
        var toolNames: [String: String] = [:]
        return events.compactMap { event -> ToasttyTranscriptRow? in
            let content: ToasttyTranscriptRow.Content
            switch event.payload {
            case .userMessage(let payload):
                content = userMessage(payload, at: event.timestamp, isSentFromThisMac: isSentFromThisMac, timeText: timeText)
            case .assistantMessage(let payload):
                content = .assistantMessage(text: payload.text, phase: payload.phase)
            case .toolStarted(let payload):
                toolNames[payload.callID] = payload.toolName
                content = .toolStarted(callID: payload.callID, name: payload.toolName, detail: payload.detail)
            case .toolFinished(let payload):
                content = .toolFinished(
                    callID: payload.callID,
                    name: payload.toolName ?? toolNames[payload.callID] ?? "Tool",
                    outcome: payload.outcome,
                    detail: payload.detail
                )
            case .interactionPresented(var payload):
                if let resolution = resolutions[payload.id] {
                    payload.state = resolution.resolution
                    payload.answers = resolution.answers
                }
                // The chat does not answer questions. The terminal does.
                payload.responseID = nil
                content = .interaction(ToasttyInteractionPresentation(interaction: payload))
            case .interactionResolved(let payload):
                content = .interactionResolved(interactionID: payload.interactionID, resolution: payload.resolution)
            case .subagentSummary(let payload):
                content = .subagentSummary(name: payload.displayName, phase: payload.phase, detail: payload.detail)
            case .sessionBindingChanged(let payload):
                content = .sessionBindingChanged(reason: payload.reason)
            case .statusChanged, .interactionResponseClosed, .sendDeliveryUnconfirmed:
                // The status is in the composer, a closed answer window is a
                // phone's, and a lost send is reported next to the composer.
                return nil
            }
            return ToasttyTranscriptRow(
                id: ToasttyTranscriptRowID(
                    projectionRunID: projectionRunID.rawValue,
                    projectionGeneration: projectionGeneration,
                    conversationID: event.conversationID.rawValue,
                    sequence: event.sequence
                ),
                timestamp: event.timestamp,
                provider: event.provider,
                content: content
            )
        }
    }

    private static func userMessage(
        _ payload: ConversationUserMessagePayload,
        at timestamp: Date,
        isSentFromThisMac: (String) -> Bool,
        timeText: (Date) -> String
    ) -> ToasttyTranscriptRow.Content {
        // Toastty's first line says whose message it is. The line is the
        // only thing read here: text after it cannot change the answer.
        let text: String
        switch CoordinatorMessageHeader.kind(of: payload.text) {
        case .digest(let updateCount):
            return .hostMessage(ToasttyHostMessagePresentation(
                summary: CoordinatorDigestFold.summary(updateCount: updateCount, time: timeText(timestamp)),
                text: payload.text
            ))
        case .fromSender(let sender):
            // Not the user's words: one muted line that names the sender
            // and opens to the text.
            return .hostMessage(ToasttyHostMessagePresentation(
                summary: "From \(sender) · \(timeText(timestamp))",
                text: payload.text
            ))
        case .quickEntry, .plain:
            text = CoordinatorMessageHeader.displayText(of: payload.text)
        }
        // The conversation records every message that Toastty typed as
        // sent from another device. For a message from this Mac that is
        // not so, and the chat says only that it steered a running turn.
        if let clientRequestID = payload.clientRequestID, isSentFromThisMac(clientRequestID) {
            return .userMessage(text: text, origin: .local, deliveryMode: payload.deliveryMode == .steer ? .steer : nil)
        }
        return .userMessage(text: text, origin: payload.origin, deliveryMode: payload.deliveryMode)
    }

    /// The last resolution of each interaction. A later event without
    /// answers keeps the answers of an earlier one.
    private static func interactionResolutions(
        in events: [ConversationEvent]
    ) -> [RemotePendingInteraction.ID: ConversationInteractionResolvedPayload] {
        events.reduce(into: [:]) { resolutions, event in
            guard case .interactionResolved(let payload) = event.payload else { return }
            let previous = resolutions[payload.interactionID]
            resolutions[payload.interactionID] = ConversationInteractionResolvedPayload(
                interactionID: payload.interactionID,
                resolution: previous?.resolution == .resolved ? .resolved : payload.resolution,
                answers: payload.answers ?? previous?.answers
            )
        }
    }
}
