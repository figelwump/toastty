import Foundation

public struct TerminalPanelState: Codable, Equatable, Sendable {
    public var title: String
    public var shell: String
    public var cwd: String
    public var launchWorkingDirectory: String?
    public var profileBinding: TerminalProfileBinding?
    private static let homeDirectory = (NSHomeDirectory() as NSString).standardizingPath

    public init(
        title: String,
        shell: String,
        cwd: String,
        launchWorkingDirectory: String? = nil,
        profileBinding: TerminalProfileBinding? = nil
    ) {
        self.title = title
        self.shell = shell
        self.cwd = cwd
        self.launchWorkingDirectory = Self.normalizedWorkingDirectoryValue(launchWorkingDirectory)
        self.profileBinding = profileBinding
    }

    /// The cwd we should use when launching or re-launching a shell surface.
    /// Prefer authoritative live cwd when available, otherwise fall back to the
    /// persisted launch seed captured from the last known live cwd.
    public var workingDirectorySeed: String {
        Self.normalizedWorkingDirectoryValue(cwd)
            ?? Self.normalizedWorkingDirectoryValue(launchWorkingDirectory)
            ?? Self.homeDirectory
    }

    /// Only treat the live cwd field as a high-confidence process tracking hint.
    /// Restored launch seeds are intentionally excluded so startup restore does
    /// not bind panels to the wrong shell and overwrite live metadata later.
    public var expectedProcessWorkingDirectory: String? {
        Self.normalizedWorkingDirectoryValue(cwd)
    }

    public var displayPanelLabel: String {
        if let customTitle = normalizedCustomTitle {
            return customTitle
        }

        if let directory = directoryLabel {
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
        // Path-like titles are usually shell cwd context, not user intent.
        // Prefer cwd label for these when cwd metadata is available.
        if Self.looksLikePathContextTitle(trimmed), directoryLabel != nil {
            return nil
        }
        return trimmed
    }

    private var directoryLabel: String? {
        guard let normalizedPath = Self.normalizedWorkingDirectoryValue(cwd) else {
            return nil
        }
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

    private static func looksLikePathContextTitle(_ title: String) -> Bool {
        if title.hasPrefix("/") || title.hasPrefix("~") || title.hasPrefix("file://") {
            return true
        }
        // Compact path labels from Ghostty can appear as ".../foo" or "…/foo".
        if title.hasPrefix(".../") || title.hasPrefix("…/") {
            return true
        }
        return false
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
        // Match Ghostty-style path labels by eliding the home root prefix for
        // deeper home-descendant paths (for example: ".../GiantThings/repos/toastty").
        return ".../" + components.suffix(3).joined(separator: "/")
    }

    private static func compactPathLabel(from components: [String]) -> String {
        if components.count <= 2 {
            return components.joined(separator: "/")
        }
        return ".../" + components.suffix(2).joined(separator: "/")
    }

    private static func normalizedWorkingDirectoryValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        let normalizedPath = (trimmed as NSString).standardizingPath
        guard normalizedPath.isEmpty == false else { return nil }
        return normalizedPath
    }
}

public enum PanelState: Equatable, Sendable {
    case terminal(TerminalPanelState)
    case web(WebPanelState)

    public var kind: PanelKind {
        switch self {
        case .terminal:
            return .terminal
        case .web:
            return .web
        }
    }

    public var notificationLabel: String {
        switch self {
        case .terminal(let terminalState):
            return terminalState.displayPanelLabel
        case .web(let webState):
            return webState.displayPanelLabel
        }
    }
}

extension PanelState: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case terminal
        case web
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(PanelKind.self, forKey: .kind)
        switch kind {
        case .terminal:
            self = .terminal(try container.decode(TerminalPanelState.self, forKey: .terminal))
        case .web:
            self = .web(try container.decode(WebPanelState.self, forKey: .web))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .terminal(let value):
            try container.encode(value, forKey: .terminal)
        case .web(let value):
            try container.encode(value, forKey: .web)
        }
    }
}
