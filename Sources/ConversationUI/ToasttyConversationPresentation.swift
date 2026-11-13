import Foundation
import RemoteProtocol

public struct ToasttyTranscriptRowID: Hashable, Sendable {
    public let projectionRunID: UUID
    public let projectionGeneration: UInt64
    public let conversationID: UUID
    public let sequence: UInt64

    public init(projectionRunID: UUID, projectionGeneration: UInt64, conversationID: UUID, sequence: UInt64) {
        self.projectionRunID = projectionRunID
        self.projectionGeneration = projectionGeneration
        self.conversationID = conversationID
        self.sequence = sequence
    }

    public var accessibilitySuffix: String { String(sequence) }
}

public struct ToasttyTranscriptRow: Identifiable, Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        /// `quote` is the agent's message that this message answers.
        /// `attachments` are the local files sent with the message, which
        /// the bubble shows apart from `text`: an image as a thumbnail.
        case userMessage(
            text: String,
            origin: ConversationMessageOrigin,
            deliveryMode: RemoteMessageDeliveryMode? = nil,
            quote: ToasttyMessageQuote? = nil,
            attachments: [URL] = []
        )
        /// A message the host typed for the agent. It starts a turn as a
        /// user message does.
        case hostMessage(ToasttyHostMessagePresentation)
        case assistantMessage(text: String, phase: ConversationAssistantMessagePhase)
        case toolStarted(callID: String, name: String, detail: String?)
        case toolFinished(callID: String, name: String, outcome: ConversationToolOutcome, detail: String?)
        case interaction(ToasttyInteractionPresentation)
        case interactionResolved(interactionID: RemotePendingInteraction.ID, resolution: RemotePendingInteraction.State)
        case subagentSummary(name: String, phase: ConversationSubagentPhase, detail: String?)
        case sessionBindingChanged(reason: ConversationBindingChangeReason)
    }

    public let id: ToasttyTranscriptRowID
    public let timestamp: Date
    public let provider: AgentKind
    public let content: Content

    public init(id: ToasttyTranscriptRowID, timestamp: Date, provider: AgentKind, content: Content) {
        self.id = id
        self.timestamp = timestamp
        self.provider = provider
        self.content = content
    }

    /// The row is a message to the agent, which starts a turn.
    var startsTurn: Bool {
        switch content {
        case .userMessage, .hostMessage: true
        default: false
        }
    }
}

public struct ToasttyInteractionPresentation: Equatable, Sendable {
    public var interaction: RemotePendingInteraction
    public var responseClosedReason: RemoteQuestionAnswerRejectionReason?

    public init(
        interaction: RemotePendingInteraction,
        responseClosedReason: RemoteQuestionAnswerRejectionReason? = nil
    ) {
        self.interaction = interaction
        self.responseClosedReason = responseClosedReason
    }
}

/// Identity of one rendered transcript block. Long assistant messages split
/// into several blocks sharing a row ID and counting up `chunkIndex`, so each
/// chunk is an independently laid-out `LazyVStack` cell with stable identity.
public struct ToasttyTranscriptBlockID: Hashable, Sendable {
    public let rowID: ToasttyTranscriptRowID
    public let chunkIndex: Int

    public init(rowID: ToasttyTranscriptRowID, chunkIndex: Int = 0) {
        self.rowID = rowID
        self.chunkIndex = chunkIndex
    }

    public var accessibilitySuffix: String {
        chunkIndex == 0
            ? rowID.accessibilitySuffix
            : "\(rowID.accessibilitySuffix)-c\(chunkIndex)"
    }
}

/// One slice of a chunked assistant message.
public struct ToasttyTranscriptMessageChunk: Equatable, Sendable {
    public let row: ToasttyTranscriptRow
    public let blocks: [ToasttyMarkdownBlock]
    public let index: Int
    public let isLast: Bool

    public var isFirst: Bool { index == 0 }
}

public struct ToasttyTranscriptBlock: Identifiable, Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case row(ToasttyTranscriptRow)
        case messageChunk(ToasttyTranscriptMessageChunk)
        case toolBatch([ToasttyTranscriptRow])
    }

    public let id: ToasttyTranscriptBlockID
    public let content: Content

    public static func group(_ rows: [ToasttyTranscriptRow]) -> [ToasttyTranscriptBlock] {
        var blocks: [ToasttyTranscriptBlock] = []
        var toolRows: [ToasttyTranscriptRow] = []

        func flushTools() {
            guard let first = toolRows.first else { return }
            blocks.append(ToasttyTranscriptBlock(
                id: ToasttyTranscriptBlockID(rowID: first.id),
                content: .toolBatch(toolRows)
            ))
            toolRows.removeAll(keepingCapacity: true)
        }

        func appendChunked(_ row: ToasttyTranscriptRow, text: String) {
            // A short table can still be tall enough to need separate cells.
            // The parser decides whether a pipe belongs to an actual table.
            guard text.count > ToasttyMarkdownChunking.chunkThreshold || text.contains("|") else {
                blocks.append(ToasttyTranscriptBlock(
                    id: ToasttyTranscriptBlockID(rowID: row.id),
                    content: .row(row)
                ))
                return
            }
            let chunks = ToasttyMarkdownChunking.split(text)
            guard chunks.count > 1 else {
                blocks.append(ToasttyTranscriptBlock(
                    id: ToasttyTranscriptBlockID(rowID: row.id),
                    content: .row(row)
                ))
                return
            }
            for (index, chunk) in chunks.enumerated() {
                blocks.append(ToasttyTranscriptBlock(
                    id: ToasttyTranscriptBlockID(rowID: row.id, chunkIndex: index),
                    content: .messageChunk(ToasttyTranscriptMessageChunk(
                        row: row,
                        blocks: chunk.blocks,
                        index: index,
                        isLast: index == chunks.count - 1
                    ))
                ))
            }
        }

        for row in rows {
            switch row.content {
            case .toolStarted, .toolFinished:
                toolRows.append(row)
            case .assistantMessage(let text, _):
                flushTools()
                appendChunked(row, text: text)
            default:
                flushTools()
                blocks.append(ToasttyTranscriptBlock(
                    id: ToasttyTranscriptBlockID(rowID: row.id),
                    content: .row(row)
                ))
            }
        }
        flushTools()
        return blocks
    }
}

/// One user turn: the user message anchor plus the work (tool batches,
/// commentary) between it and its first final response.
/// Interaction cards are never part of a turn's foldable work — they stay
/// visible so pending prompts cannot hide.
///
/// A host message that folds its turn (`ToasttyHostMessagePresentation.foldsTurn`)
/// makes every later block of the turn foldable, its responses too, and the
/// message's own line stands in for the work strip.
public struct ToasttyTranscriptTurn: Equatable, Sendable {
    public let id: ToasttyTranscriptRowID
    public let workBlockIDs: [ToasttyTranscriptBlockID]
    public let toolCallCount: Int
    public let noteCount: Int
    /// True once a final assistant message follows the work, which is what
    /// makes the work section foldable.
    public let hasResponse: Bool
    /// The anchor is a host message that folds the whole turn.
    public let foldsWholeTurn: Bool

    public init(
        id: ToasttyTranscriptRowID,
        workBlockIDs: [ToasttyTranscriptBlockID],
        toolCallCount: Int,
        noteCount: Int,
        hasResponse: Bool,
        foldsWholeTurn: Bool = false
    ) {
        self.id = id
        self.workBlockIDs = workBlockIDs
        self.toolCallCount = toolCallCount
        self.noteCount = noteCount
        self.hasResponse = hasResponse
        self.foldsWholeTurn = foldsWholeTurn
    }

    /// Includes user turns before their first work block arrives, so the
    /// previous completed turn cannot be mistaken for the current one.
    public static func turns(for blocks: [ToasttyTranscriptBlock]) -> [ToasttyTranscriptTurn] {
        var turns: [ToasttyTranscriptTurn] = []
        var currentID: ToasttyTranscriptRowID?
        var workBlockIDs: [ToasttyTranscriptBlockID] = []
        var toolCallIDs: Set<String> = []
        var noteRowIDs: Set<ToasttyTranscriptRowID> = []
        var hasResponse = false
        var foldsWholeTurn = false

        func flushTurn() {
            guard let id = currentID else { return }
            turns.append(ToasttyTranscriptTurn(
                id: id,
                workBlockIDs: workBlockIDs,
                toolCallCount: toolCallIDs.count,
                noteCount: noteRowIDs.count,
                hasResponse: hasResponse,
                foldsWholeTurn: foldsWholeTurn
            ))
            currentID = nil
            workBlockIDs.removeAll(keepingCapacity: true)
            toolCallIDs.removeAll(keepingCapacity: true)
            noteRowIDs.removeAll(keepingCapacity: true)
            hasResponse = false
            foldsWholeTurn = false
        }

        /// Whether the block belongs to the current turn's foldable work:
        /// before the turn's response, or anywhere in a turn that folds
        /// whole.
        var foldsAsWork: Bool {
            currentID != nil && (hasResponse == false || foldsWholeTurn)
        }

        for block in blocks {
            switch block.content {
            case .row(let row):
                switch row.content {
                case .userMessage:
                    flushTurn()
                    currentID = row.id
                case .hostMessage(let message):
                    flushTurn()
                    currentID = row.id
                    foldsWholeTurn = message.foldsTurn
                case .assistantMessage(_, let phase):
                    // Only explicit commentary folds as work. Codex transcripts
                    // deliver responses with an unknown phase, so anything not
                    // marked commentary must count as the turn's response or
                    // the turn never settles.
                    if phase == .commentary {
                        if foldsAsWork {
                            workBlockIDs.append(block.id)
                            noteRowIDs.insert(row.id)
                        }
                    } else if currentID != nil {
                        hasResponse = true
                        if foldsWholeTurn { workBlockIDs.append(block.id) }
                    }
                case .subagentSummary, .interactionResolved,
                     .sessionBindingChanged:
                    if foldsAsWork {
                        workBlockIDs.append(block.id)
                    }
                case .interaction, .toolStarted, .toolFinished:
                    break
                }
            case .messageChunk(let chunk):
                guard case .assistantMessage(_, let phase) = chunk.row.content else { break }
                if phase == .commentary {
                    if foldsAsWork {
                        workBlockIDs.append(block.id)
                        noteRowIDs.insert(chunk.row.id)
                    }
                } else if currentID != nil {
                    hasResponse = true
                    if foldsWholeTurn { workBlockIDs.append(block.id) }
                }
            case .toolBatch(let rows):
                if foldsAsWork {
                    workBlockIDs.append(block.id)
                    for row in rows {
                        switch row.content {
                        case .toolStarted(let callID, _, _), .toolFinished(let callID, _, _, _):
                            toolCallIDs.insert(callID)
                        default:
                            break
                        }
                    }
                }
            }
        }
        flushTurn()
        return turns
    }
}

public enum ToasttyConversationPresentationPhase: Equatable, Sendable {
    case loading
    case live
    case resyncing
    case stale
    case failure(message: String)
}

public enum ToasttyTranscriptRevision: Equatable, Sendable {
    case initial
    case appended
    case prepended
    case rebuilt
    case metadataOnly
}

/// Prepared transcript content is immutable and shared by metadata-only updates.
public final class ToasttyPreparedTranscript: Equatable, Sendable {
    public let rows: [ToasttyTranscriptRow]
    public let blocks: [ToasttyTranscriptBlock]
    public let turns: [ToasttyTranscriptTurn]

    public init(rows: [ToasttyTranscriptRow]) {
        self.rows = rows
        blocks = ToasttyTranscriptBlock.group(rows)
        turns = ToasttyTranscriptTurn.turns(for: blocks)
    }

    public static func == (lhs: ToasttyPreparedTranscript, rhs: ToasttyPreparedTranscript) -> Bool {
        lhs === rhs || (lhs.rows == rhs.rows && lhs.blocks == rhs.blocks && lhs.turns == rhs.turns)
    }
}

public struct ToasttyConversationPresentationState: Equatable, Sendable {
    public let preparedTranscript: ToasttyPreparedTranscript
    public var rows: [ToasttyTranscriptRow] { preparedTranscript.rows }
    public var blocks: [ToasttyTranscriptBlock] { preparedTranscript.blocks }
    public var turns: [ToasttyTranscriptTurn] { preparedTranscript.turns }
    public private(set) var sendItems: [ToasttySendPresentationItem]
    public private(set) var phase: ToasttyConversationPresentationPhase
    public private(set) var revision: ToasttyTranscriptRevision
    public private(set) var historyTruncated: Bool
    public private(set) var hasOlder: Bool
    public private(set) var isLoadingOlder: Bool
    public private(set) var prependAnchorID: ToasttyTranscriptRowID?

    public init(
        rows: [ToasttyTranscriptRow],
        sendItems: [ToasttySendPresentationItem] = [],
        phase: ToasttyConversationPresentationPhase,
        revision: ToasttyTranscriptRevision,
        historyTruncated: Bool,
        hasOlder: Bool = false,
        isLoadingOlder: Bool = false,
        prependAnchorID: ToasttyTranscriptRowID? = nil
    ) {
        preparedTranscript = ToasttyPreparedTranscript(rows: rows)
        self.sendItems = sendItems
        self.phase = phase
        self.revision = revision
        self.historyTruncated = historyTruncated
        self.hasOlder = hasOlder
        self.isLoadingOlder = isLoadingOlder
        self.prependAnchorID = prependAnchorID
    }

    public func settledTurnIDs(isSessionWorking: Bool, isSubmitting: Bool = false) -> Set<ToasttyTranscriptRowID> {
        var settled = Set(turns.filter(\.hasResponse).map(\.id))
        let hasPendingSend = isSubmitting || sendItems.contains { item in
            if case .optimistic = item.content { return true }
            return false
        }
        // A send starts a new turn before its canonical user row arrives.
        // Keep the completed predecessor settled through that handoff, while
        // retaining work expansion for a response still streaming in its turn.
        if let last = turns.last, isSessionWorking, hasPendingSend == false {
            settled.remove(last.id)
        }
        return settled
    }

    public func updatingMetadata(
        sendItems: [ToasttySendPresentationItem],
        phase: ToasttyConversationPresentationPhase,
        revision: ToasttyTranscriptRevision,
        historyTruncated: Bool,
        hasOlder: Bool,
        isLoadingOlder: Bool,
        prependAnchorID: ToasttyTranscriptRowID?
    ) -> Self {
        var updated = self
        updated.sendItems = sendItems
        updated.phase = phase
        updated.revision = revision
        updated.historyTruncated = historyTruncated
        updated.hasOlder = hasOlder
        updated.isLoadingOlder = isLoadingOlder
        updated.prependAnchorID = prependAnchorID
        return updated
    }

    public static let loading = ToasttyConversationPresentationState(
        rows: [],
        phase: .loading,
        revision: .initial,
        historyTruncated: false
    )
}
