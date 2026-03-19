import Foundation

public struct AgentProfile: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let argv: [String]
    /// Single lowercase alphanumeric character used as a keyboard shortcut.
    /// Launch: ⌘⌃<key>.
    public let shortcutKey: Character?

    public init(
        id: String,
        displayName: String,
        argv: [String],
        shortcutKey: Character? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.argv = argv
        self.shortcutKey = shortcutKey
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case argv
        case shortcutKey
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        argv = try container.decode([String].self, forKey: .argv)

        if let rawShortcutKey = try container.decodeIfPresent(String.self, forKey: .shortcutKey) {
            guard rawShortcutKey.count == 1 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .shortcutKey,
                    in: container,
                    debugDescription: "shortcutKey must be a single character"
                )
            }
            shortcutKey = rawShortcutKey.first
        } else {
            shortcutKey = nil
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(argv, forKey: .argv)
        try container.encodeIfPresent(shortcutKey.map(String.init), forKey: .shortcutKey)
    }
}

public struct AgentCatalog: Equatable, Sendable {
    public let profiles: [AgentProfile]

    public init(profiles: [AgentProfile]) {
        self.profiles = profiles
    }

    public static let empty = Self(profiles: [])

    public func profile(id: String) -> AgentProfile? {
        profiles.first(where: { $0.id == id })
    }
}
