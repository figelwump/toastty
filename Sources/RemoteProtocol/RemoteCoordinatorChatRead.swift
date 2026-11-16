import Foundation

/// The newest row of the coordinator's chat that the user read, in the
/// Mac's chat or on a paired device. The Mac keeps one read point for both:
/// it sends it with the coordinator's workspace, and a device that shows
/// the chat sends its reads back with `RemoteCoordinatorChatReadRequest`.
///
/// The read point names its row by the row's transcript event
/// (`ConversationEvent.eventID`), which the Mac's chat and every device
/// read from the same conversation. The time does not name a row exactly:
/// the wire keeps milliseconds, so a device's time for a row can be up to
/// a millisecond earlier than the Mac's.
public struct RemoteCoordinatorChatReadPoint: Codable, Equatable, Sendable {
    /// The read row's transcript event. Absent for a row whose identity
    /// does not survive a Mac relaunch (`durableEventID`), and for a read
    /// point that the Mac saved before it named rows by identity.
    public var eventID: String?
    /// The read row's time, as the Mac read it from the transcript. It
    /// orders the rows when a reader does not have the row that `eventID`
    /// names, or when the read point has no `eventID`.
    public var timestamp: Date

    public init(eventID: String?, timestamp: Date) {
        self.eventID = eventID.flatMap(Self.durableEventID)
        self.timestamp = timestamp
    }

    /// `eventID` when it names the same row after a Mac relaunch: an
    /// agent's transcript record. A runtime event's `rt:` identity counts
    /// up again in each run of the Mac's conversation reader, so another
    /// event can have it later.
    public static func durableEventID(_ eventID: String) -> String? {
        eventID.isEmpty || eventID.hasPrefix("rt:") ? nil : eventID
    }

    private enum CodingKeys: String, CodingKey {
        case eventID, timestamp
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            eventID: try container.decodeIfPresent(String.self, forKey: .eventID),
            timestamp: try container.decode(Date.self, forKey: .timestamp)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(eventID, forKey: .eventID)
        try container.encode(timestamp, forKey: .timestamp)
    }
}

/// Wire contract for a read of the coordinator's chat on a paired device.
public enum RemoteCoordinatorChatReadPolicy {
    public static let readPath = "/api/coordinator.chat.read"
    public static let maximumBodyBytes = 2048
    /// The longest event identity a request may carry.
    public static let maximumEventIDLength = 512
}

/// The device showed the coordinator's chat through the row of `eventID`
/// while its app was active. The Mac moves the shared read point to that
/// row unless the read point is already there or later.
public struct RemoteCoordinatorChatReadRequest: Codable, Equatable, Sendable {
    public var protocolVersion: String
    /// The coordinator's conversation, which the coordinator's workspace
    /// names in `coordinatorConversationID`.
    public var conversationID: RemoteConversationID
    /// The transcript event of the newest row the device showed.
    public var eventID: String
    /// The run and generation of the Mac's conversation reader that sent
    /// the row. A runtime event's `rt:` identity names a row only in its
    /// own run, so the Mac takes such a read only from its current run.
    public var projectionRunID: RemoteProjectionRunID
    public var projectionGeneration: UInt64

    public init(
        protocolVersion: String = RemoteGatewayProtocol.version,
        conversationID: RemoteConversationID,
        eventID: String,
        projectionRunID: RemoteProjectionRunID,
        projectionGeneration: UInt64
    ) {
        self.protocolVersion = protocolVersion
        self.conversationID = conversationID
        self.eventID = eventID
        self.projectionRunID = projectionRunID
        self.projectionGeneration = projectionGeneration
    }

    public var isValid: Bool {
        eventID.isEmpty == false && eventID.count <= RemoteCoordinatorChatReadPolicy.maximumEventIDLength
    }
}

public enum RemoteCoordinatorChatReadResult: String, Codable, Equatable, Sendable {
    /// The read point moved to the row.
    case moved
    /// The read point already was at the row or after it.
    case alreadyRead = "already_read"
    /// The conversation has no event with this identity now: the Mac's
    /// reader started again, or the event left its history. Also a runtime
    /// event from an earlier run of the reader.
    case eventNotFound = "event_not_found"
    /// The Mac has no coordinator, or the conversation is not its chat.
    case noCoordinator = "no_coordinator"
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

public struct RemoteCoordinatorChatReadResponse: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var result: RemoteCoordinatorChatReadResult

    public init(
        protocolVersion: String = RemoteGatewayProtocol.version,
        result: RemoteCoordinatorChatReadResult
    ) {
        self.protocolVersion = protocolVersion
        self.result = result
    }
}
