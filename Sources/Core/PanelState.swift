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
    private static let homeDirectory = (NSHomeDirectory() as NSString).standardizingPath

    public init(title: String, shell: String, cwd: String) {
        self.title = title
        self.shell = shell
        self.cwd = cwd
    }

    public var displayPanelLabel: String {
        if let customTitle = normalizedCustomTitle {
            if let directory = directoryLabel,
               directory.caseInsensitiveCompare(customTitle) != .orderedSame {
                return "\(customTitle) · \(directory)"
            }
            return customTitle
        }

        if let directory = directoryLabel {
            if let shell = shellName {
                return "\(directory) · \(shell)"
            }
            return directory
        }

        if let shell = shellName {
            return shell
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? "Terminal" : trimmedTitle
    }

    private var normalizedCustomTitle: String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        guard Self.isDefaultTerminalTitle(trimmed) == false else { return nil }
        return trimmed
    }

    private var directoryLabel: String? {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        let normalizedPath = (trimmed as NSString).standardizingPath
        guard normalizedPath.isEmpty == false else { return nil }

        if normalizedPath == "/" {
            return "/"
        }
        if normalizedPath == Self.homeDirectory {
            return "~"
        }
        let homePrefix = Self.homeDirectory + "/"
        if normalizedPath.hasPrefix(homePrefix) {
            let relativePath = String(normalizedPath.dropFirst(homePrefix.count))
            return Self.homeRelativeLabel(for: relativePath)
        }

        let components = normalizedPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if components.isEmpty {
            return normalizedPath
        }
        return Self.compactPathLabel(from: components)
    }

    private var shellName: String? {
        let trimmed = shell.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        let lastComponent = URL(fileURLWithPath: trimmed).lastPathComponent
        if lastComponent.isEmpty == false {
            return lastComponent
        }
        return trimmed
    }

    private static func isDefaultTerminalTitle(_ title: String) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "terminal" {
            return true
        }
        let components = normalized.split(separator: " ", omittingEmptySubsequences: true)
        guard components.count == 2 else { return false }
        guard components[0] == "terminal" else { return false }
        return Int(components[1]) != nil
    }

    private static func homeRelativeLabel(for relativePath: String) -> String {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.isEmpty == false else { return "~" }
        if components.count <= 2 {
            return "~/" + components.joined(separator: "/")
        }
        return "~/.../" + components.suffix(2).joined(separator: "/")
    }

    private static func compactPathLabel(from components: [String]) -> String {
        if components.count <= 2 {
            return components.joined(separator: "/")
        }
        return ".../" + components.suffix(2).joined(separator: "/")
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

    public var notificationLabel: String {
        switch self {
        case .terminal(let terminalState):
            return terminalState.displayPanelLabel
        case .diff:
            return "Diff"
        case .markdown:
            return "Markdown"
        case .scratchpad:
            return "Scratchpad"
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
