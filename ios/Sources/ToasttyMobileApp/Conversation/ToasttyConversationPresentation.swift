import Foundation
import RemoteProtocol
import ToasttyMobileDomain

struct ToasttyTranscriptRowID: Hashable, Sendable {
    let projectionRunID: UUID
    let projectionGeneration: UInt64
    let conversationID: UUID
    let sequence: UInt64

    var accessibilitySuffix: String { String(sequence) }
}

struct ToasttyTranscriptRow: Identifiable, Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case userMessage(text: String, origin: ConversationMessageOrigin)
        case assistantMessage(text: String, phase: ConversationAssistantMessagePhase)
        case toolStarted(callID: String, name: String, detail: String?)
        case toolFinished(callID: String, name: String, outcome: ConversationToolOutcome, detail: String?)
        case statusChanged(state: String, availability: String)
        case interaction(RemotePendingInteraction)
        case interactionResolved(interactionID: RemotePendingInteraction.ID, resolution: RemotePendingInteraction.State)
        case subagentSummary(name: String, phase: ConversationSubagentPhase, detail: String?)
        case sessionBindingChanged(reason: ConversationBindingChangeReason)
    }

    let id: ToasttyTranscriptRowID
    let timestamp: Date
    let provider: AgentKind
    let content: Content
}

struct ToasttyTranscriptBlock: Identifiable, Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case row(ToasttyTranscriptRow)
        case toolBatch([ToasttyTranscriptRow])
    }

    let id: ToasttyTranscriptRowID
    let content: Content

    static func group(_ rows: [ToasttyTranscriptRow]) -> [ToasttyTranscriptBlock] {
        var blocks: [ToasttyTranscriptBlock] = []
        var toolRows: [ToasttyTranscriptRow] = []

        func flushTools() {
            guard let first = toolRows.first else { return }
            blocks.append(ToasttyTranscriptBlock(id: first.id, content: .toolBatch(toolRows)))
            toolRows.removeAll(keepingCapacity: true)
        }

        for row in rows {
            switch row.content {
            case .toolStarted, .toolFinished:
                toolRows.append(row)
            default:
                flushTools()
                blocks.append(ToasttyTranscriptBlock(id: row.id, content: .row(row)))
            }
        }
        flushTools()
        return blocks
    }
}

enum ToasttyConversationPresentationPhase: Equatable, Sendable {
    case loading
    case live
    case resyncing
    case stale
    case failure(message: String)
}

enum ToasttyTranscriptRevision: Equatable, Sendable {
    case initial
    case appended
    case prepended
    case rebuilt
    case metadataOnly
}

struct ToasttyConversationPresentationState: Equatable, Sendable {
    let rows: [ToasttyTranscriptRow]
    let blocks: [ToasttyTranscriptBlock]
    let phase: ToasttyConversationPresentationPhase
    let revision: ToasttyTranscriptRevision
    let historyTruncated: Bool
    let hasOlder: Bool
    let isLoadingOlder: Bool
    let prependAnchorID: ToasttyTranscriptRowID?

    init(
        rows: [ToasttyTranscriptRow],
        phase: ToasttyConversationPresentationPhase,
        revision: ToasttyTranscriptRevision,
        historyTruncated: Bool,
        hasOlder: Bool = false,
        isLoadingOlder: Bool = false,
        prependAnchorID: ToasttyTranscriptRowID? = nil
    ) {
        self.rows = rows
        blocks = ToasttyTranscriptBlock.group(rows)
        self.phase = phase
        self.revision = revision
        self.historyTruncated = historyTruncated
        self.hasOlder = hasOlder
        self.isLoadingOlder = isLoadingOlder
        self.prependAnchorID = prependAnchorID
    }

    static let loading = ToasttyConversationPresentationState(
        rows: [],
        phase: .loading,
        revision: .initial,
        historyTruncated: false
    )
}

enum ToasttyConversationPresentationAdapter {
    static func makeState(
        events: [CompatibleConversationEvent],
        projectionRunID: RemoteProjectionRunID?,
        projectionGeneration: UInt64?,
        phase: ToasttyConversationPresentationPhase,
        revision: ToasttyTranscriptRevision,
        historyTruncated: Bool,
        hasOlder: Bool = false,
        isLoadingOlder: Bool = false,
        prependAnchorID: ToasttyTranscriptRowID? = nil
    ) -> ToasttyConversationPresentationState {
        let resolutions = interactionResolutions(in: events)
        var toolNames: [String: String] = [:]
        let rows = events.compactMap { event -> ToasttyTranscriptRow? in
            switch event {
            case .unknown:
                return nil
            case .statusChanged(let value):
                return ToasttyTranscriptRow(
                    id: rowID(
                        projectionRunID: projectionRunID,
                        projectionGeneration: projectionGeneration,
                        conversationID: value.conversationID,
                        sequence: value.sequence
                    ),
                    timestamp: value.timestamp,
                    provider: value.provider,
                    content: .statusChanged(
                        state: statusLabel(value.state),
                        availability: availabilityLabel(value.inputAvailability)
                    )
                )
            case .known(let value):
                let content: ToasttyTranscriptRow.Content
                switch value.payload {
                case .userMessage(let payload):
                    content = .userMessage(text: payload.text, origin: payload.origin)
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
                case .statusChanged(let payload):
                    content = .statusChanged(
                        state: statusLabel(.known(payload.state)),
                        availability: availabilityLabel(payload.inputAvailability)
                    )
                case .interactionPresented(var payload):
                    if let resolution = resolutions[payload.id] {
                        payload.state = resolution
                    }
                    content = .interaction(payload)
                case .interactionResolved(let payload):
                    content = .interactionResolved(
                        interactionID: payload.interactionID,
                        resolution: payload.resolution
                    )
                case .subagentSummary(let payload):
                    content = .subagentSummary(
                        name: payload.displayName,
                        phase: payload.phase,
                        detail: payload.detail
                    )
                case .sessionBindingChanged(let payload):
                    content = .sessionBindingChanged(reason: payload.reason)
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
    ) -> [RemotePendingInteraction.ID: RemotePendingInteraction.State] {
        events.reduce(into: [:]) { resolutions, event in
            guard case .known(let known) = event,
                  case .interactionResolved(let payload) = known.payload else { return }
            resolutions[payload.interactionID] = payload.resolution
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

    private static func statusLabel(_ state: MobileSessionDisplayState) -> String {
        switch state {
        case .known(let value):
            switch value {
            case .starting: "session starting"
            case .working: "agent working"
            case .awaitingInput: "waiting for input"
            case .ready: "session ready"
            case .interrupted: "session interrupted"
            case .ended: "session ended"
            case .error: "session error"
            case .offline: "session offline"
            }
        case .unsupported:
            "session status changed"
        }
    }

    private static func availabilityLabel(_ availability: CompatibleInputAvailability) -> String {
        switch availability {
        case .openPrompt: "reply available"
        case .localDraft: "desktop draft in progress"
        case .pendingInteraction: "interaction pending on Mac"
        case .unavailable(let reason): reason.rawValue.replacingOccurrences(of: "_", with: " ")
        case .unsupported: "read-only"
        }
    }

    private static func availabilityLabel(_ availability: RemoteInputAvailability) -> String {
        switch availability {
        case .openPrompt: "reply available"
        case .localDraft: "desktop draft in progress"
        case .pendingInteraction: "interaction pending on Mac"
        case .unavailable(let reason): reason.rawValue.replacingOccurrences(of: "_", with: " ")
        }
    }
}
