import Foundation

public struct TerminalProfile: Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let badgeLabel: String
    public let startupCommand: String

    public init(
        id: String,
        displayName: String,
        badgeLabel: String,
        startupCommand: String
    ) {
        self.id = id
        self.displayName = displayName
        self.badgeLabel = badgeLabel
        self.startupCommand = startupCommand
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
