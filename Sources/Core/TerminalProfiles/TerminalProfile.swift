import Foundation

public struct TerminalProfile: Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let badgeLabel: String
    public let startupCommand: String
    /// Single lowercase alphanumeric character used as a keyboard shortcut.
    /// Split right: ⌘⌥<key>, split down: ⌘⌥⇧<key>.
    public let shortcutKey: Character?
    /// Command that attaches a second terminal to the multiplexer session this
    /// profile's pane runs in. Toastty offers it to paired remote clients, so
    /// it should attach to an existing session and never create one.
    public let remoteAttachCommand: String?

    public init(
        id: String,
        displayName: String,
        badgeLabel: String,
        startupCommand: String,
        shortcutKey: Character? = nil,
        remoteAttachCommand: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.badgeLabel = badgeLabel
        self.startupCommand = startupCommand
        self.shortcutKey = shortcutKey
        self.remoteAttachCommand = remoteAttachCommand
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
