import Foundation

public enum DiffBindingMode: String, Codable, Equatable, Sendable {
    case followFocusedTerminal
}

public enum DiffLoadingState: Equatable, Sendable {
    case idle
    case computing
    case error(String)
}

extension DiffLoadingState: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case message
    }

    private enum Kind: String, Codable {
        case idle
        case computing
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .idle:
            self = .idle
        case .computing:
            self = .computing
        case .error:
            self = .error(try container.decode(String.self, forKey: .message))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .idle:
            try container.encode(Kind.idle, forKey: .kind)
        case .computing:
            try container.encode(Kind.computing, forKey: .kind)
        case .error(let message):
            try container.encode(Kind.error, forKey: .kind)
            try container.encode(message, forKey: .message)
        }
    }
}

public struct TerminalPanelState: Codable, Equatable, Sendable {
    public var title: String
    public var shell: String
    public var cwd: String

    public init(title: String, shell: String, cwd: String) {
        self.title = title
        self.shell = shell
        self.cwd = cwd
    }
}

public struct DiffPanelState: Codable, Equatable, Sendable {
    public var showStaged: Bool
    public var mode: DiffBindingMode
    public var loadingState: DiffLoadingState

    public init(showStaged: Bool = false, mode: DiffBindingMode = .followFocusedTerminal, loadingState: DiffLoadingState = .idle) {
        self.showStaged = showStaged
        self.mode = mode
        self.loadingState = loadingState
    }
}

public struct MarkdownPanelState: Codable, Equatable, Sendable {
    public var sourcePanelID: UUID?
    public var filePath: String?
    public var rawMarkdown: String?

    public init(sourcePanelID: UUID? = nil, filePath: String? = nil, rawMarkdown: String? = nil) {
        self.sourcePanelID = sourcePanelID
        self.filePath = filePath
        self.rawMarkdown = rawMarkdown
    }
}

public struct ScratchpadPanelState: Codable, Equatable, Sendable {
    public var documentID: UUID

    public init(documentID: UUID = UUID()) {
        self.documentID = documentID
    }
}

public enum PanelState: Equatable, Sendable {
    case terminal(TerminalPanelState)
    case diff(DiffPanelState)
    case markdown(MarkdownPanelState)
    case scratchpad(ScratchpadPanelState)

    public var kind: PanelKind {
        switch self {
        case .terminal:
            return .terminal
        case .diff:
            return .diff
        case .markdown:
            return .markdown
        case .scratchpad:
            return .scratchpad
        }
    }
}

extension PanelState: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case terminal
        case diff
        case markdown
        case scratchpad
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(PanelKind.self, forKey: .kind)
        switch kind {
        case .terminal:
            self = .terminal(try container.decode(TerminalPanelState.self, forKey: .terminal))
        case .diff:
            self = .diff(try container.decode(DiffPanelState.self, forKey: .diff))
        case .markdown:
            self = .markdown(try container.decode(MarkdownPanelState.self, forKey: .markdown))
        case .scratchpad:
            self = .scratchpad(try container.decode(ScratchpadPanelState.self, forKey: .scratchpad))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .terminal(let value):
            try container.encode(value, forKey: .terminal)
        case .diff(let value):
            try container.encode(value, forKey: .diff)
        case .markdown(let value):
            try container.encode(value, forKey: .markdown)
        case .scratchpad(let value):
            try container.encode(value, forKey: .scratchpad)
        }
    }
}
