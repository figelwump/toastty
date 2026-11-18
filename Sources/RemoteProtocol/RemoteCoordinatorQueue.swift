import Foundation

/// The coordinator's own waiting messages, as the Mac shares them with a
/// paired device.
///
/// The coordinator has two queues. Its conversation's send queue holds what
/// a device's chat queued (`RemoteConversationInputControl.queuedMessages`).
/// The coordinator's own queue holds the other messages for it: the Mac
/// chat's, quick entry's from the Mac and from a device, and those that
/// `coordinator send` brought. This is that second queue. A Stop holds the
/// messages that wait in both queues, and `heldSetToken` names that Stop.
///
/// The messages hold text the user has not sent yet, so they stay off the
/// session list, which browsers also read. The coordinator's workspace
/// carries only `RemoteWorkspaceSummary.coordinatorQueueRevision`, and a
/// native device reads the messages from `RemoteCoordinatorQueuePolicy.path`
/// when the revision is new. The Mac sends display text only: the names of
/// attached files, never their paths.
public struct RemoteCoordinatorQueue: Codable, Equatable, Sendable {
    public var protocolVersion: String
    /// Names this queue: the Mac makes it from `conversationID`,
    /// `heldSetToken` and each entry's ID and hold. The coordinator's
    /// workspace carries the same value.
    public var revision: String
    /// The coordinator's live conversation, which the actions name. `nil`
    /// while no agent of the coordinator runs: the messages then wait for
    /// one.
    public var conversationID: RemoteConversationID?
    /// Names the newest Stop while it holds messages in either queue. A
    /// device's Resume presents it, so a Resume that comes late cannot let
    /// a later Stop's messages go. `nil` while nothing is held.
    public var heldSetToken: String?
    /// The coordinator's queue, held entries first, each group in the order
    /// it is typed. At most `CoordinatorController.maximumQueuedEntries`.
    public var entries: [RemoteCoordinatorQueueEntry]

    public init(
        protocolVersion: String = RemoteGatewayProtocol.version,
        revision: String,
        conversationID: RemoteConversationID? = nil,
        heldSetToken: String? = nil,
        entries: [RemoteCoordinatorQueueEntry] = []
    ) {
        self.protocolVersion = protocolVersion
        self.revision = revision
        self.conversationID = conversationID
        self.heldSetToken = heldSetToken
        self.entries = entries
    }

    public var heldEntries: [RemoteCoordinatorQueueEntry] { entries.filter(\.isHeld) }
    public var waitingEntries: [RemoteCoordinatorQueueEntry] { entries.filter { $0.isHeld == false } }
}

/// One message in the coordinator's own queue, as a chat's waiting bubble
/// shows it.
public struct RemoteCoordinatorQueueEntry: Codable, Equatable, Sendable {
    /// Names the entry for `RemoteConversationQueueAction.coordinatorRemove`.
    public var id: String
    /// The text as the Mac's chat shows it in the waiting bubble: without
    /// Toastty's first line and the folders of attached files. At most
    /// `RemoteCoordinatorQueuePolicy.maximumTextLength` characters.
    public var text: String
    /// The Mac cut `text` to its limit.
    public var isTextShortened: Bool
    /// Who sent a message that `coordinator send` brought, short: "task Fix
    /// the unread dot". `nil` for the user's own messages.
    public var sender: String?
    /// The coordinator's message that a reply answers. At most
    /// `RemoteCoordinatorQueuePolicy.maximumQuoteLength` characters.
    public var quote: String?
    /// The time of the quoted message, as the reply's first line wrote it.
    public var quoteTime: String?
    /// The names of the attached files. The files stay on the Mac.
    public var fileNames: [String]
    /// A Stop holds it until Resume.
    public var isHeld: Bool

    public init(
        id: String,
        text: String,
        isTextShortened: Bool = false,
        sender: String? = nil,
        quote: String? = nil,
        quoteTime: String? = nil,
        fileNames: [String] = [],
        isHeld: Bool = false
    ) {
        self.id = id
        self.text = text
        self.isTextShortened = isTextShortened
        self.sender = sender
        self.quote = quote
        self.quoteTime = quoteTime
        self.fileNames = fileNames
        self.isHeld = isHeld
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, isTextShortened, sender, quote, quoteTime, fileNames, isHeld
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        isTextShortened = try container.decodeIfPresent(Bool.self, forKey: .isTextShortened) ?? false
        sender = try container.decodeIfPresent(String.self, forKey: .sender)
        quote = try container.decodeIfPresent(String.self, forKey: .quote)
        quoteTime = try container.decodeIfPresent(String.self, forKey: .quoteTime)
        fileNames = try container.decodeIfPresent([String].self, forKey: .fileNames) ?? []
        isHeld = try container.decodeIfPresent(Bool.self, forKey: .isHeld) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        if isTextShortened { try container.encode(true, forKey: .isTextShortened) }
        try container.encodeIfPresent(sender, forKey: .sender)
        try container.encodeIfPresent(quote, forKey: .quote)
        try container.encodeIfPresent(quoteTime, forKey: .quoteTime)
        if fileNames.isEmpty == false { try container.encode(fileNames, forKey: .fileNames) }
        if isHeld { try container.encode(true, forKey: .isHeld) }
    }
}

/// Wire contract for reading the coordinator's own queue.
public enum RemoteCoordinatorQueuePolicy {
    public static let path = "/api/coordinator.queue"
    /// Keeps a read of 50 entries small. Without Edit on a device, the
    /// whole text is not needed there.
    public static let maximumTextLength = 2_000
    public static let maximumQuoteLength = 500
}
