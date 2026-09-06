import Foundation

public struct RemoteWorkspaceSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var panels: [RemoteWorkspacePanel]
    public init(id: UUID, title: String, panels: [RemoteWorkspacePanel]) {
        self.id = id
        self.title = title
        self.panels = panels
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
    /// Display metadata only. Workspace and panel identity authorize reads.
    public var filePath: String?
    public var url: URL?
    public init(
        panelID: UUID, auxiliaryTabID: UUID, workspaceTabID: UUID, workspaceTabTitle: String,
        kind: String, title: String, revision: Int? = nil, filePath: String? = nil, url: URL? = nil
    ) {
        self.panelID = panelID
        self.auxiliaryTabID = auxiliaryTabID
        self.workspaceTabID = workspaceTabID
        self.workspaceTabTitle = workspaceTabTitle
        self.kind = kind
        self.title = title
        self.revision = revision
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
