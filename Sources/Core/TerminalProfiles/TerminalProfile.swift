import Foundation

public struct TerminalProfile: Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let badgeLabel: String
    public let startupCommand: String
    /// Single lowercase alphanumeric character used as a keyboard shortcut.
    /// Split right: ⌘⌃<key>, split down: ⌘⌃⇧<key>.
    public let shortcutKey: Character?

    public init(
        id: String,
        displayName: String,
        badgeLabel: String,
        startupCommand: String,
        shortcutKey: Character? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.badgeLabel = badgeLabel
        self.startupCommand = startupCommand
        self.shortcutKey = shortcutKey
    }
}

public struct TerminalProfileCatalog: Equatable, Sendable {
    public let profiles: [TerminalProfile]

    public init(profiles: [TerminalProfile]) {
        self.profiles = profiles
    }

    public func profile(id: String) -> TerminalProfile? {
        profiles.first(where: { $0.id == id })
    }

    public static let empty = TerminalProfileCatalog(profiles: [])
}

public struct TerminalProfileBinding: Codable, Equatable, Sendable {
    public let profileID: String

    public init(profileID: String) {
        self.profileID = profileID
    }
}
