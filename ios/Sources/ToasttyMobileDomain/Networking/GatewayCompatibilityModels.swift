import Foundation
import RemoteProtocol

public enum CompatibleInputUnavailableReason: Equatable, Sendable {
    case known(RemoteInputUnavailableReason)
    case unsupported(rawValue: String)

    public var rawValue: String {
        switch self {
        case .known(let reason): reason.rawValue
        case .unsupported(let rawValue): rawValue
        }
    }
}

public enum CompatibleInputAvailability: Equatable, Sendable {
    case unavailable(reason: CompatibleInputUnavailableReason)
    case openPrompt(epoch: RemoteInputEpoch)
    case pendingInteraction(interactionIDs: [RemotePendingInteraction.ID])
    case localDraft(epoch: RemoteInputEpoch)
    case unsupported(rawKind: String)

    public var allowsRemoteSend: Bool {
        if case .openPrompt = self { return true }
        return false
    }

    public func presentation(
        pendingInteractionPreview: RemotePendingInteractionPreview? = nil
    ) -> MobileInputAvailability {
        switch self {
        case .unavailable(let reason):
            return .unavailable(reason: reason.rawValue)
        case .openPrompt:
            return .openPrompt
        case .pendingInteraction:
            return .pendingInteraction(preview: pendingInteractionPreview?.prompt)
        case .localDraft:
            return .localDraft
        case .unsupported(let rawKind):
            return .unavailable(reason: "unsupported input state: \(rawKind)")
        }
    }
}

public enum CompatibleSessionPresentationStatus: Equatable, Sendable {
    case known(RemoteSessionPresentationStatus)
    case unsupported(rawValue: String)

    public var presentation: MobileSessionStatus {
        switch self {
        case .known(let status):
            .known(status)
        case .unsupported(let rawValue):
            .unsupported(rawValue: rawValue)
        }
    }
}

public struct CompatibleConversationSummary: Equatable, Sendable {
    public var conversationID: RemoteConversationID
    public var provider: AgentKind
    public var title: String
    public var placement: RemoteConversationPlacement
    public var cwd: String?
    public var state: MobileSessionDisplayState
    public var presentationStatus: CompatibleSessionPresentationStatus?
    public var inputAvailability: CompatibleInputAvailability
    public var pendingInteractionPreview: RemotePendingInteractionPreview?
    public var projectionGeneration: UInt64
    public var latestSequence: UInt64
    public var updatedAt: Date

    public init(
        conversationID: RemoteConversationID,
        provider: AgentKind,
        title: String,
        placement: RemoteConversationPlacement,
        cwd: String?,
        state: MobileSessionDisplayState,
        presentationStatus: CompatibleSessionPresentationStatus? = nil,
        inputAvailability: CompatibleInputAvailability,
        pendingInteractionPreview: RemotePendingInteractionPreview? = nil,
        projectionGeneration: UInt64,
        latestSequence: UInt64,
        updatedAt: Date
    ) {
        self.conversationID = conversationID
        self.provider = provider
        self.title = title
        self.placement = placement
        self.cwd = cwd
        self.state = state
        self.presentationStatus = presentationStatus
        self.inputAvailability = inputAvailability
        self.pendingInteractionPreview = pendingInteractionPreview
        self.projectionGeneration = projectionGeneration
        self.latestSequence = latestSequence
        self.updatedAt = updatedAt
    }
}

public struct CompatibleSessionListSnapshot: Equatable, Sendable {
    public var projectionRunID: RemoteProjectionRunID
    public var conversations: [CompatibleConversationSummary]
    public var generatedAt: Date

    public init(
        projectionRunID: RemoteProjectionRunID,
        conversations: [CompatibleConversationSummary],
        generatedAt: Date
    ) {
        self.projectionRunID = projectionRunID
        self.conversations = conversations
        self.generatedAt = generatedAt
    }

    public func presentation(
        hostName: String = "Toastty Mac",
        receivedAtMonotonicTime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> MobileHomeSnapshot {
        let mobileConversations = conversations.map { summary in
            let workspaceID = summary.placement.workspaceID ?? Self.ungroupedWorkspaceID
            let workspaceTitle = summary.placement.workspaceTitle ?? "Ungrouped"
            let path = summary.cwd.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown path"
            let availability = summary.inputAvailability.presentation(
                pendingInteractionPreview: summary.pendingInteractionPreview
            )
            let status = summary.presentationStatus?.presentation
                ?? Self.legacyPresentationStatus(
                    for: summary.state,
                    inputAvailability: summary.inputAvailability
                )
            return MobileConversation(
                id: summary.conversationID.rawValue,
                workspaceID: workspaceID,
                workspaceTitle: workspaceTitle,
                workspacePath: path,
                agent: summary.provider,
                title: summary.title,
                state: status,
                inputAvailability: availability,
                age: Self.relativeAge(from: summary.updatedAt, receivedAt: generatedAt),
                activityAge: MobileActivityAge(
                    secondsAtReceipt: Self.relativeAgeSeconds(
                        from: summary.updatedAt,
                        receivedAt: generatedAt
                    ),
                    receivedAtMonotonicTime: receivedAtMonotonicTime
                ),
                lastActivity: status.bucket == .idle
                    ? "Conversation readable"
                    : availability.inputReason
            )
        }
        let grouped = Dictionary(grouping: mobileConversations, by: \.workspaceID)
        let workspaces: [MobileWorkspace] = grouped.values.map { conversations in
            let first = conversations[0]
            return MobileWorkspace(
                id: first.workspaceID,
                title: first.workspaceTitle,
                path: first.workspacePath,
                conversations: conversations.sorted {
                    let titleOrder = $0.title.localizedCaseInsensitiveCompare($1.title)
                    if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
                    return $0.id.uuidString < $1.id.uuidString
                }
            )
        }.sorted {
            let titleOrder = $0.title.localizedCaseInsensitiveCompare($1.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return $0.id.uuidString < $1.id.uuidString
        }
        return MobileHomeSnapshot(hostName: hostName, workspaces: workspaces)
    }

    private static let ungroupedWorkspaceID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    private static func legacyPresentationStatus(
        for state: MobileSessionDisplayState,
        inputAvailability: CompatibleInputAvailability
    ) -> MobileSessionStatus {
        switch state {
        case .known(let state):
            // Older hosts exposed only lifecycle plus input availability. A
            // pending interaction is the one authoritative legacy fact that
            // distinguishes desktop needs-approval from a completed turn
            // whose prompt is ready again.
            if state == .awaitingInput,
               case .pendingInteraction = inputAvailability {
                return .needsApproval
            }
            return .known(state.presentationStatusFallback)
        case .unsupported(let rawValue):
            return .unsupported(rawValue: rawValue)
        }
    }

    private static func relativeAge(from date: Date, receivedAt: Date) -> String {
        relativeAgeLabel(seconds: relativeAgeSeconds(from: date, receivedAt: receivedAt))
    }

    private static func relativeAgeSeconds(from date: Date, receivedAt: Date) -> Int {
        max(0, Int(receivedAt.timeIntervalSince(date)))
    }

    private static func relativeAgeLabel(seconds: Int) -> String {
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}

public struct CompatibleStatusChangedEvent: Equatable, Sendable {
    public var conversationID: RemoteConversationID
    public var sequence: UInt64
    public var eventID: String
    public var schemaVersion: Int
    public var timestamp: Date
    public var provider: AgentKind
    public var providerIdentity: String?
    public var turnID: String?
    public var state: MobileSessionDisplayState
    public var inputAvailability: CompatibleInputAvailability

    public init(
        conversationID: RemoteConversationID,
        sequence: UInt64,
        eventID: String,
        schemaVersion: Int,
        timestamp: Date,
        provider: AgentKind,
        providerIdentity: String?,
        turnID: String?,
        state: MobileSessionDisplayState,
        inputAvailability: CompatibleInputAvailability
    ) {
        self.conversationID = conversationID
        self.sequence = sequence
        self.eventID = eventID
        self.schemaVersion = schemaVersion
        self.timestamp = timestamp
        self.provider = provider
        self.providerIdentity = providerIdentity
        self.turnID = turnID
        self.state = state
        self.inputAvailability = inputAvailability
    }
}

public enum CompatibleConversationEvent: Equatable, Sendable {
    case known(ConversationEvent)
    case statusChanged(CompatibleStatusChangedEvent)
    case unknown(conversationID: RemoteConversationID, sequence: UInt64, kind: String)

    public var conversationID: RemoteConversationID {
        switch self {
        case .known(let event): event.conversationID
        case .statusChanged(let event): event.conversationID
        case .unknown(let conversationID, _, _): conversationID
        }
    }

    public var sequence: UInt64 {
        switch self {
        case .known(let event): event.sequence
        case .statusChanged(let event): event.sequence
        case .unknown(_, let sequence, _): sequence
        }
    }

    public var kind: String {
        switch self {
        case .known(let event): event.kind.rawValue
        case .statusChanged: ConversationEventKind.statusChanged.rawValue
        case .unknown(_, _, let kind): kind
        }
    }
}

public struct CompatibleConversationEventPage: Equatable, Sendable {
    public var conversationID: RemoteConversationID
    public var projectionRunID: RemoteProjectionRunID
    public var projectionGeneration: UInt64
    public var events: [CompatibleConversationEvent]
    public var latestSequence: UInt64
    public var firstAvailableSequence: UInt64?
    public var historyTruncated: Bool

    public init(
        conversationID: RemoteConversationID,
        projectionRunID: RemoteProjectionRunID,
        projectionGeneration: UInt64,
        events: [CompatibleConversationEvent],
        latestSequence: UInt64,
        firstAvailableSequence: UInt64?,
        historyTruncated: Bool
    ) {
        self.conversationID = conversationID
        self.projectionRunID = projectionRunID
        self.projectionGeneration = projectionGeneration
        self.events = events
        self.latestSequence = latestSequence
        self.firstAvailableSequence = firstAvailableSequence
        self.historyTruncated = historyTruncated
    }

    public var hasMore: Bool {
        guard let sequence = events.last?.sequence else { return false }
        return sequence < latestSequence
    }

    public var continuationCursor: ConversationEventCursor? {
        guard let sequence = events.last?.sequence else { return nil }
        return ConversationEventCursor(
            projectionRunID: projectionRunID,
            projectionGeneration: projectionGeneration,
            afterSequence: sequence
        )
    }
}

public enum CompatibleGatewayEventsResponse: Equatable, Sendable {
    case page(CompatibleConversationEventPage)
    case resnapshotRequired
    case conversationNotFound
}

public enum CompatibleGatewayStreamMessage: Equatable, Sendable {
    case sessionList(CompatibleSessionListSnapshot)
    case conversationEvents(CompatibleConversationEventPage)
    case resnapshotRequired(conversationID: RemoteConversationID)
    case ignoredUnknown(type: String)
}
