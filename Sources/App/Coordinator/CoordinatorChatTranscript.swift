import ConversationUI
import CoreState
import Foundation
import RemoteProtocol

/// Turns the coordinator's conversation events into the rows the shared
/// transcript draws.
///
/// The iPhone has its own adapter, over the events it decodes from the
/// gateway. This one differs in five ways: a digest that Toastty typed
/// becomes one folded line; a message that `coordinator send` brought shows
/// its sender and body in a card;
/// a digest whose turn the coordinator marked quiet folds the whole turn
/// under that line; a quick entry message shows without Toastty's first
/// line; and a message this Mac sent is not marked as sent from another
/// device.
// TODO: Share the event-to-row mapping with the iPhone's
// `ToasttyConversationPresentationAdapter` once the iPhone can take it.
enum CoordinatorChatTranscript {
    /// An agent message as a reply names it.
    struct QuotedMessage: Hashable {
        let text: String
        let time: String
    }

    static func rows(
        from events: [ConversationEvent],
        projectionRunID: RemoteProjectionRunID,
        projectionGeneration: UInt64,
        isSentFromThisMac: (String) -> Bool,
        isQuietDigest: (String) -> Bool = { _ in false },
        timeText: (Date) -> String
    ) -> [ToasttyTranscriptRow] {
        let resolutions = interactionResolutions(in: events)
        var toolNames: [String: String] = [:]
        // The newest row of each agent message so far, by its text as a
        // reply quotes it and by its time as the reply's line writes it: a
        // reply's quote opens the message it answers.
        var assistantRowIDs: [QuotedMessage: ToasttyTranscriptRowID] = [:]
        return events.compactMap { event -> ToasttyTranscriptRow? in
            let rowID = ToasttyTranscriptRowID(
                projectionRunID: projectionRunID.rawValue,
                projectionGeneration: projectionGeneration,
                conversationID: event.conversationID.rawValue,
                sequence: event.sequence
            )
            let content: ToasttyTranscriptRow.Content
            switch event.payload {
            case .userMessage(let payload):
                content = userMessage(
                    payload,
                    at: event.timestamp,
                    isSentFromThisMac: isSentFromThisMac,
                    isQuietDigest: isQuietDigest,
                    timeText: timeText,
                    quotedRowID: { assistantRowIDs[$0] }
                )
            case .assistantMessage(let payload):
                assistantRowIDs[QuotedMessage(
                    text: CoordinatorMessageHeader.quoteText(payload.text),
                    time: CoordinatorMessageHeader.replyTime(timeText(event.timestamp))
                )] = rowID
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
                id: rowID,
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
        isQuietDigest: (String) -> Bool,
        timeText: (Date) -> String,
        quotedRowID: (QuotedMessage) -> ToasttyTranscriptRowID?
    ) -> ToasttyTranscriptRow.Content {
        // Toastty's first line says whose message it is. The line is the
        // only thing read here: text after it cannot change the answer.
        let text: String
        var quote: ToasttyMessageQuote?
        switch CoordinatorMessageHeader.kind(of: payload.text) {
        case .digest(let updateCount):
            return .hostMessage(ToasttyHostMessagePresentation(
                summary: CoordinatorDigestFold.summary(updateCount: updateCount, time: timeText(timestamp)),
                text: payload.text,
                foldsTurn: isQuietDigest(payload.text)
            ))
        case .fromSender(let sender):
            // Only Toastty's first line identifies the sender. The body
            // stays third-party text, even when it imitates another header.
            let body = payload.text.split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                .dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return .hostMessage(ToasttyHostMessagePresentation(
                summary: "From \(sender) · \(timeText(timestamp))",
                text: body,
                style: .sender(name: sender, timeText: timeText(timestamp))
            ))
        case .reply(let quoted, let time, _, _):
            text = CoordinatorMessageHeader.displayText(of: payload.text)
            let source = time.flatMap { quotedRowID(QuotedMessage(text: quoted, time: $0)) }
            quote = ToasttyMessageQuote(text: quoted, timeText: time, sourceRowID: source)
        case .quickEntry, .plain:
            text = CoordinatorMessageHeader.displayText(of: payload.text)
        }
        // The conversation records every message that Toastty typed as
        // sent from another device. For a message from this Mac that is
        // not so, and the chat says only that it steered a running turn.
        if let clientRequestID = payload.clientRequestID, isSentFromThisMac(clientRequestID) {
            return .userMessage(
                text: text, origin: .local, deliveryMode: payload.deliveryMode == .steer ? .steer : nil, quote: quote
            )
        }
        return .userMessage(text: text, origin: payload.origin, deliveryMode: payload.deliveryMode, quote: quote)
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
