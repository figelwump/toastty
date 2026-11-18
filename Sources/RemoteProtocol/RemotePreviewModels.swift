import Foundation

public struct RemoteWorkspaceSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var panels: [RemoteWorkspacePanel]
    /// Sorted by key. Omitted from the wire when empty, and absent from older hosts.
    public var annotations: [RemoteWorkspaceAnnotation]
    /// The top-level workspace this one is nested under as a subspace. The
    /// host sends only links its own sidebar honors, one level deep. Absent
    /// for top-level workspaces and from older hosts, which clients show as a
    /// flat list.
    public var parentWorkspaceID: UUID?
    /// The conversation of the session that spawned this subspace, while that
    /// session is still one the host lists.
    public var spawningConversationID: RemoteConversationID?
    /// Key of the annotation that best identifies this workspace; always one
    /// of `annotations`.
    public var primaryAnnotationKey: String?
    /// When this subspace's task was marked done; absent while it is open.
    public var doneAt: Date?
    /// Whether the host takes a done mark for this subspace. False for a
    /// task with an open pull request, which finishes through Merge; the
    /// host refuses the mark then. Sent only when false, so an older host's
    /// subspaces accept it.
    public var acceptsDoneMark: Bool
    /// The coordinator's own workspace: the Mac pins it apart from the
    /// projects, and a client with the task system shows it on its own. Sent
    /// only when true. Absent from older hosts, whose clients list every
    /// workspace as a project.
    public var isCoordinator: Bool
    /// On the coordinator's workspace: the coordinator's own session while
    /// its agent runs. Other sessions can run in the same workspace, and a
    /// listed transcript outlives its agent, so a client takes the
    /// coordinator's session from here. Absent while the coordinator does
    /// not run or is starting.
    public var coordinatorConversationID: RemoteConversationID?
    /// On the coordinator's workspace: the newest row of the coordinator's
    /// chat that the user read, on the Mac or on a device, while the Mac
    /// advertises `coordinatorChatRead`. Absent before the first read.
    public var coordinatorChatRead: RemoteCoordinatorChatReadPoint?
    /// On the coordinator's workspace, while the Mac advertises
    /// `coordinatorQuietDigests`: `RemoteCoordinatorQuietDigests.revision`
    /// of the quiet digests now. A device reads the keys again when it
    /// changes.
    public var coordinatorQuietDigestsRevision: String?
    /// On the coordinator's workspace, while the Mac advertises
    /// `coordinatorQueue`: `RemoteCoordinatorQueue.revision` of the
    /// coordinator's own queue now. A native device reads the queue again
    /// when it changes.
    public var coordinatorQueueRevision: String?
    public init(
        id: UUID, title: String, panels: [RemoteWorkspacePanel],
        annotations: [RemoteWorkspaceAnnotation] = [],
        parentWorkspaceID: UUID? = nil,
        spawningConversationID: RemoteConversationID? = nil,
        primaryAnnotationKey: String? = nil,
        doneAt: Date? = nil,
        acceptsDoneMark: Bool = true,
        isCoordinator: Bool = false,
        coordinatorConversationID: RemoteConversationID? = nil,
        coordinatorChatRead: RemoteCoordinatorChatReadPoint? = nil,
        coordinatorQuietDigestsRevision: String? = nil,
        coordinatorQueueRevision: String? = nil
    ) {
        self.id = id
        self.title = title
        self.panels = panels
        self.annotations = annotations
        self.parentWorkspaceID = parentWorkspaceID
        self.spawningConversationID = spawningConversationID
        self.primaryAnnotationKey = primaryAnnotationKey
        self.doneAt = doneAt
        self.acceptsDoneMark = acceptsDoneMark
        self.isCoordinator = isCoordinator
        self.coordinatorConversationID = coordinatorConversationID
        self.coordinatorChatRead = coordinatorChatRead
        self.coordinatorQuietDigestsRevision = coordinatorQuietDigestsRevision
        self.coordinatorQueueRevision = coordinatorQueueRevision
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(panels, forKey: .panels)
        if !annotations.isEmpty { try container.encode(annotations, forKey: .annotations) }
        try container.encodeIfPresent(parentWorkspaceID, forKey: .parentWorkspaceID)
        try container.encodeIfPresent(spawningConversationID, forKey: .spawningConversationID)
        try container.encodeIfPresent(primaryAnnotationKey, forKey: .primaryAnnotationKey)
        try container.encodeIfPresent(doneAt, forKey: .doneAt)
        if !acceptsDoneMark { try container.encode(false, forKey: .acceptsDoneMark) }
        if isCoordinator { try container.encode(true, forKey: .isCoordinator) }
        try container.encodeIfPresent(coordinatorConversationID, forKey: .coordinatorConversationID)
        try container.encodeIfPresent(coordinatorChatRead, forKey: .coordinatorChatRead)
        try container.encodeIfPresent(coordinatorQuietDigestsRevision, forKey: .coordinatorQuietDigestsRevision)
        try container.encodeIfPresent(coordinatorQueueRevision, forKey: .coordinatorQueueRevision)
    }
    private enum CodingKeys: String, CodingKey {
        case id, title, panels, annotations
        case parentWorkspaceID, spawningConversationID, primaryAnnotationKey, doneAt, acceptsDoneMark, isCoordinator
        case coordinatorConversationID, coordinatorChatRead, coordinatorQuietDigestsRevision, coordinatorQueueRevision
    }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        panels = try container.decode([RemoteWorkspacePanel].self, forKey: .panels)
        annotations = try container.decodeIfPresent([RemoteWorkspaceAnnotation].self, forKey: .annotations) ?? []
        parentWorkspaceID = try container.decodeIfPresent(UUID.self, forKey: .parentWorkspaceID)
        spawningConversationID = try container.decodeIfPresent(
            RemoteConversationID.self, forKey: .spawningConversationID)
        primaryAnnotationKey = try container.decodeIfPresent(String.self, forKey: .primaryAnnotationKey)
        doneAt = try container.decodeIfPresent(Date.self, forKey: .doneAt)
        acceptsDoneMark = try container.decodeIfPresent(Bool.self, forKey: .acceptsDoneMark) ?? true
        isCoordinator = try container.decodeIfPresent(Bool.self, forKey: .isCoordinator) ?? false
        coordinatorConversationID = try container.decodeIfPresent(
            RemoteConversationID.self, forKey: .coordinatorConversationID)
        // A read point this client cannot read is left out: the chat then
        // shows no line, as with an older Mac.
        coordinatorChatRead = try? container.decodeIfPresent(
            RemoteCoordinatorChatReadPoint.self, forKey: .coordinatorChatRead)
        coordinatorQuietDigestsRevision = try? container.decodeIfPresent(
            String.self, forKey: .coordinatorQuietDigestsRevision)
        coordinatorQueueRevision = try? container.decodeIfPresent(
            String.self, forKey: .coordinatorQueueRevision)
    }
}

public struct RemoteWorkspacePanel: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { panelID }
    public var panelID: UUID
    public var auxiliaryTabID: UUID
    public var workspaceTabID: UUID
    public var workspaceTabTitle: String
    /// Open string so future panel kinds do not invalidate the workspace list.
    public var kind: String
    public var title: String
    public var revision: Int?
    /// Most recent known desktop activity or source modification; absent when unknown.
    public var updatedAt: Date?
    /// Current conversation for an exactly linked live Scratchpad session; otherwise absent.
    public var associatedConversationID: RemoteConversationID?
    /// Display metadata only. Workspace and panel identity authorize reads.
    public var filePath: String?
    public var url: URL?
    public init(
        panelID: UUID, auxiliaryTabID: UUID, workspaceTabID: UUID, workspaceTabTitle: String,
        kind: String, title: String, revision: Int? = nil, filePath: String? = nil, url: URL? = nil,
        updatedAt: Date? = nil, associatedConversationID: RemoteConversationID? = nil
    ) {
        self.panelID = panelID
        self.auxiliaryTabID = auxiliaryTabID
        self.workspaceTabID = workspaceTabID
        self.workspaceTabTitle = workspaceTabTitle
        self.kind = kind
        self.title = title
        self.revision = revision
        self.updatedAt = updatedAt
        self.associatedConversationID = associatedConversationID
        self.filePath = filePath
        self.url = url
    }
}

public enum RemotePreviewTarget: Codable, Equatable, Sendable {
    case panel(workspaceID: UUID, panelID: UUID)
    case conversationFile(conversationID: RemoteConversationID, fileReference: String)
}

public struct RemotePreviewRequest: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var target: RemotePreviewTarget
    public init(
        target: RemotePreviewTarget, protocolVersion: String = RemoteGatewayProtocol.version
    ) {
        self.protocolVersion = protocolVersion
        self.target = target
    }
}

public struct RemotePreviewDocument: Codable, Equatable, Sendable {
    public var title: String
    public var sourcePath: String
    public var content: String
    public var format: String
    public var language: String?
    public var formatLabel: String
    public var highlightState: String
    public var highlight: Bool
    public var line: Int?
    public var revision: String
    public init(
        title: String, sourcePath: String, content: String, format: String, language: String? = nil,
        highlight: Bool = true, line: Int? = nil, revision: String,
        formatLabel: String = "Text", highlightState: String = "enabled"
    ) {
        self.title = title
        self.sourcePath = sourcePath
        self.content = content
        self.format = format
        self.formatLabel = formatLabel
        self.highlightState = highlightState
        self.language = language
        self.highlight = highlight
        self.line = line
        self.revision = revision
    }
}

public struct RemotePreviewScratchpad: Codable, Equatable, Sendable {
    public var documentID: UUID
    public var title: String
    public var html: String
    public var revision: Int
    public init(documentID: UUID, title: String, html: String, revision: Int) {
        self.documentID = documentID
        self.title = title
        self.html = html
        self.revision = revision
    }
}

public struct RemotePreviewHTML: Codable, Equatable, Sendable {
    public var title: String
    public var sourcePath: String
    public var html: String
    public var revision: String
    public init(title: String, sourcePath: String, html: String, revision: String) {
        self.title = title
        self.sourcePath = sourcePath
        self.html = html
        self.revision = revision
    }
}

public enum RemotePreviewContent: Codable, Equatable, Sendable {
    case document(RemotePreviewDocument)
    case scratchpad(RemotePreviewScratchpad)
    case html(RemotePreviewHTML)
    case webURL(URL)
}

public enum RemotePreviewError: String, Codable, Error, Equatable, Sendable {
    case missing, denied, tooLarge, unsupported, stale, busy
}

public struct RemotePreviewResponse: Codable, Equatable, Sendable {
    public var protocolVersion: String = RemoteGatewayProtocol.version
    public var content: RemotePreviewContent?
    public var error: RemotePreviewError?
    public init(content: RemotePreviewContent) {
        self.content = content
        self.error = nil
    }
    public init(error: RemotePreviewError) {
        self.content = nil
        self.error = error
    }
    private enum CodingKeys: String, CodingKey { case protocolVersion, content, error }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(String.self, forKey: .protocolVersion)
        content = try container.decodeIfPresent(RemotePreviewContent.self, forKey: .content)
        error = try container.decodeIfPresent(RemotePreviewError.self, forKey: .error)
        guard (content != nil) != (error != nil) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected exactly one preview content or error"))
        }
    }
}

public struct RemoteHTMLResourceRequest: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var target: RemotePreviewTarget
    public var expectedSourcePath: String
    public var relativePath: String
    public init(
        target: RemotePreviewTarget, expectedSourcePath: String, relativePath: String,
        protocolVersion: String = RemoteGatewayProtocol.version
    ) {
        self.protocolVersion = protocolVersion
        self.target = target
        self.expectedSourcePath = expectedSourcePath
        self.relativePath = relativePath
    }
}

public struct RemoteHTMLResourceResponse: Codable, Equatable, Sendable {
    public var protocolVersion: String = RemoteGatewayProtocol.version
    public var mimeType: String?
    /// Codable Data uses base64; credentials never enter the rendered document.
    public var data: Data?
    public var error: RemotePreviewError?
    public init(mimeType: String, data: Data) {
        self.mimeType = mimeType
        self.data = data
        self.error = nil
    }
    public init(error: RemotePreviewError) {
        self.mimeType = nil
        self.data = nil
        self.error = error
    }
    private enum CodingKeys: String, CodingKey { case protocolVersion, mimeType, data, error }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(String.self, forKey: .protocolVersion)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        data = try container.decodeIfPresent(Data.self, forKey: .data)
        error = try container.decodeIfPresent(RemotePreviewError.self, forKey: .error)
        guard
            (error == nil && mimeType != nil && data != nil)
                || (error != nil && mimeType == nil && data == nil)
        else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected complete resource or error"))
        }
    }
}
