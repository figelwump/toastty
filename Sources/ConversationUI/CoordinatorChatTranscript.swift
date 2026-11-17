import CryptoKit
import Foundation
import RemoteProtocol

/// Turns an agent conversation's events into the rows the shared transcript
/// draws. Every chat on the iPhone and the Mac's coordinator chat use it.
public enum ToasttyTranscriptRows {
    /// What a chat does with an agent's question or permission request.
    public enum Interactions: Sendable {
        /// The chat answers it. Its card takes an answer until the question
        /// is resolved or the host closes its answer window.
        case answerable
        /// The chat only shows it. The Mac's coordinator chat leaves the
        /// answer to the terminal.
        case shownOnly
    }

    /// The rows for `events`. With `coordinatorMessages`, the messages that
    /// Toastty typed into the coordinator show as the coordinator's chat
    /// shows them; without it, every user message shows as it was typed.
    public static func rows(
        from events: [ConversationEvent],
        projectionRunID: UUID,
        projectionGeneration: UInt64,
        interactions: Interactions,
        coordinatorMessages: CoordinatorChatTranscript.Messages? = nil
    ) -> [ToasttyTranscriptRow] {
        let resolutions = interactionResolutions(in: events)
        let responseClosures: [RemotePendingInteraction.ID: RemoteQuestionAnswerRejectionReason] =
            switch interactions {
            case .answerable: interactionResponseClosures(in: events)
            case .shownOnly: [:]
            }
        var toolNames: [String: String] = [:]
        // The newest row of each agent message so far, by its text as a
        // reply quotes it and by its time as the reply's line writes it: a
        // reply's quote opens the message it answers.
        var assistantRowIDs: [CoordinatorChatTranscript.QuotedMessage: ToasttyTranscriptRowID] = [:]
        // The rows of each agent message by its text alone. The reply's time
        // is the Mac's, written in the Mac's format, which can differ from
        // this device's: then a text that only one message has finds it.
        var assistantRowIDsByText: [String: [ToasttyTranscriptRowID]] = [:]
        return events.compactMap { event -> ToasttyTranscriptRow? in
            let rowID = ToasttyTranscriptRowID(
                projectionRunID: projectionRunID,
                projectionGeneration: projectionGeneration,
                conversationID: event.conversationID.rawValue,
                sequence: event.sequence
            )
            let content: ToasttyTranscriptRow.Content
            switch event.payload {
            case .userMessage(let payload):
                if let coordinatorMessages {
                    content = CoordinatorChatTranscript.userMessage(
                        payload,
                        at: event.timestamp,
                        messages: coordinatorMessages,
                        quotedRowID: { text, time in
                            if let time, let rowID = assistantRowIDs[.init(text: text, time: time)] { return rowID }
                            guard let rows = assistantRowIDsByText[text], rows.count == 1 else { return nil }
                            return rows.first
                        }
                    )
                } else {
                    content = .userMessage(text: payload.text, origin: payload.origin, deliveryMode: payload.deliveryMode)
                }
            case .assistantMessage(let payload):
                if let coordinatorMessages {
                    let time = CoordinatorMessageHeader.replyTime(coordinatorMessages.timeText(event.timestamp))
                    // A reply quotes the message as Toastty typed it, which
                    // can put image names in code spans.
                    let quotes = Set([
                        CoordinatorMessageHeader.quoteText(payload.text),
                        CoordinatorMessageHeader.typedQuoteText(payload.text),
                    ])
                    for quoted in quotes {
                        assistantRowIDs[CoordinatorChatTranscript.QuotedMessage(text: quoted, time: time)] = rowID
                        assistantRowIDsByText[quoted, default: []].append(rowID)
                    }
                }
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
                let resolution = resolutions[payload.id]
                if let resolution {
                    payload.state = resolution.resolution
                    payload.answers = resolution.answers
                }
                switch interactions {
                case .answerable:
                    // A resolved question, or one whose answer window the
                    // host closed, takes no answer.
                    if resolution != nil || responseClosures[payload.id] != nil {
                        payload.responseID = nil
                    }
                    content = .interaction(ToasttyInteractionPresentation(
                        interaction: payload,
                        responseClosedReason: responseClosures[payload.id]
                    ))
                case .shownOnly:
                    payload.responseID = nil
                    content = .interaction(ToasttyInteractionPresentation(interaction: payload))
                }
            case .interactionResolved(let payload):
                content = .interactionResolved(interactionID: payload.interactionID, resolution: payload.resolution)
            case .subagentSummary(let payload):
                content = .subagentSummary(name: payload.displayName, phase: payload.phase, detail: payload.detail)
            case .sessionBindingChanged(let payload):
                content = .sessionBindingChanged(reason: payload.reason)
            case .statusChanged, .interactionResponseClosed, .sendDeliveryUnconfirmed:
                // The status is in the header and the composer. A closed
                // answer window is on the question's card. A lost send shows
                // with the message it concerns.
                return nil
            }
            return ToasttyTranscriptRow(
                id: rowID,
                timestamp: event.timestamp,
                provider: event.provider,
                content: content,
                eventID: event.eventID
            )
        }
    }

    /// The last resolution of each interaction. A later event without
    /// answers keeps the answers of an earlier one, and a resolved
    /// interaction stays resolved.
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

    /// The interactions whose answer window the host closed and that were
    /// not presented or resolved again since.
    private static func interactionResponseClosures(
        in events: [ConversationEvent]
    ) -> [RemotePendingInteraction.ID: RemoteQuestionAnswerRejectionReason] {
        events.reduce(into: [:]) { closures, event in
            switch event.payload {
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
}

/// How the coordinator's chat shows the messages that Toastty typed into
/// the coordinator, on the Mac and on the iPhone.
///
/// - A digest that Toastty typed becomes one folded line.
/// - A message that `coordinator send` brought shows its sender and body in
///   a card.
/// - A quick entry message shows without Toastty's first line, with the
///   user's choices and the files.
/// - A reply shows the line that names the coordinator's message it
///   answers.
///
/// Only the Mac knows which turns are quiet and which messages it sent
/// itself, and only on the Mac are the attached files at hand. The Mac's
/// chat passes those through `Messages`.
public enum CoordinatorChatTranscript {
    /// An agent message as a reply names it.
    public struct QuotedMessage: Hashable, Sendable {
        public let text: String
        public let time: String

        public init(text: String, time: String) {
            self.text = text
            self.time = time
        }
    }

    /// What the chat's host knows about the messages that Toastty typed.
    public struct Messages {
        /// How a user's bubble shows the files attached to the message.
        public enum AttachedFiles: Sendable {
            /// Each file by itself, an image as a thumbnail. The files are
            /// on this Mac.
            case apart
            /// The name of each file, in the text. The files stay on the
            /// Mac, so this device cannot show them.
            case byName
        }

        /// A time as the chat shows it, such as "14:05". A reply's first
        /// line names the quoted message by such a time.
        public var timeText: (Date) -> String
        public var attachedFiles: AttachedFiles
        /// Whether this device sent the message with this
        /// `clientRequestID`.
        public var isSentFromThisDevice: (String) -> Bool
        /// Whether the turn that this digest started was a quiet one, which
        /// its line then folds too.
        public var isQuietDigest: (String) -> Bool

        public init(
            timeText: @escaping (Date) -> String,
            attachedFiles: AttachedFiles,
            isSentFromThisDevice: @escaping (String) -> Bool = { _ in false },
            isQuietDigest: @escaping (String) -> Bool = { _ in false }
        ) {
            self.timeText = timeText
            self.attachedFiles = attachedFiles
            self.isSentFromThisDevice = isSentFromThisDevice
            self.isQuietDigest = isQuietDigest
        }
    }

    /// The Mac's coordinator chat: it shows questions without answering
    /// them, the attached files apart, and its own messages as its own.
    public static func rows(
        from events: [ConversationEvent],
        projectionRunID: RemoteProjectionRunID,
        projectionGeneration: UInt64,
        isSentFromThisMac: @escaping (String) -> Bool,
        isQuietDigest: @escaping (String) -> Bool = { _ in false },
        timeText: @escaping (Date) -> String
    ) -> [ToasttyTranscriptRow] {
        ToasttyTranscriptRows.rows(
            from: events,
            projectionRunID: projectionRunID.rawValue,
            projectionGeneration: projectionGeneration,
            interactions: .shownOnly,
            coordinatorMessages: Messages(
                timeText: timeText,
                attachedFiles: .apart,
                isSentFromThisDevice: isSentFromThisMac,
                isQuietDigest: isQuietDigest
            )
        )
    }

    /// Names a digest by its text, as the Mac's `CoordinatorWakeState.digestKey`
    /// does: the SHA-256, in hex, of the text without leading and trailing
    /// white space. A device that shows the coordinator's chat gets the
    /// digest's text from the Mac's conversation reader and finds the key of
    /// a quiet turn the Mac shares (`RemoteCoordinatorQuietDigests`). The Mac's
    /// copy lives in Core, which the phone does not link, and RemoteProtocol
    /// stays Foundation-only; `CoordinatorChatSendPathTests` checks that the
    /// two agree on the text the gateway sends.
    public static func digestKey(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SHA256.hash(data: Data(trimmed.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The quote that a reply's bubble shows while the message waits or
    /// sends, from the text as Toastty types it. It does not open its
    /// message: the chat's rows may not hold it.
    public static func quote(of text: String) -> ToasttyMessageQuote? {
        guard case .reply(let quote, let time, _, _) = CoordinatorMessageHeader.kind(of: text) else { return nil }
        return ToasttyMessageQuote(text: quote, timeText: time)
    }

    static func userMessage(
        _ payload: ConversationUserMessagePayload,
        at timestamp: Date,
        messages: Messages,
        quotedRowID: (_ text: String, _ time: String?) -> ToasttyTranscriptRowID?
    ) -> ToasttyTranscriptRow.Content {
        // Toastty's first line says whose message it is. The line is the
        // only thing read here: text after it cannot change the answer.
        var quote: ToasttyMessageQuote?
        switch CoordinatorMessageHeader.kind(of: payload.text) {
        case .digest(let updateCount):
            return .hostMessage(ToasttyHostMessagePresentation(
                summary: CoordinatorDigestFold.summary(updateCount: updateCount, time: messages.timeText(timestamp)),
                text: payload.text,
                foldsTurn: messages.isQuietDigest(payload.text)
            ))
        case .fromSender(let sender):
            // Only Toastty's first line identifies the sender. The body
            // stays third-party text, even when it imitates another header.
            let body = payload.text.split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                .dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let time = messages.timeText(timestamp)
            return .hostMessage(ToasttyHostMessagePresentation(
                summary: "From \(sender) · \(time)",
                text: body,
                style: .sender(name: sender, timeText: time)
            ))
        case .reply(let quoted, let time, _, _):
            quote = ToasttyMessageQuote(text: quoted, timeText: time, sourceRowID: quotedRowID(quoted, time))
        case .quickEntry, .plain:
            break
        }
        let text: String
        let attachments: [URL]
        switch messages.attachedFiles {
        case .apart:
            // The bubble shows each attached file by itself, an image as a
            // thumbnail, rather than its name in the text.
            let parts = CoordinatorMessageHeader.displayParts(of: payload.text)
            text = parts.text
            attachments = parts.attachmentPaths.map { URL(fileURLWithPath: $0) }
        case .byName:
            text = CoordinatorMessageHeader.displayText(of: payload.text)
            attachments = []
        }
        // The conversation records every message that Toastty typed as
        // sent from another device. For a message from this device that is
        // not so, and the chat says only that it steered a running turn.
        if let clientRequestID = payload.clientRequestID, messages.isSentFromThisDevice(clientRequestID) {
            return .userMessage(
                text: text, origin: .local, deliveryMode: payload.deliveryMode == .steer ? .steer : nil, quote: quote,
                attachments: attachments
            )
        }
        return .userMessage(
            text: text, origin: payload.origin, deliveryMode: payload.deliveryMode, quote: quote, attachments: attachments
        )
    }
}
