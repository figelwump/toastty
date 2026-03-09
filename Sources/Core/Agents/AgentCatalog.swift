import Foundation

public struct AgentProfile: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let argv: [String]

    public init(id: String, displayName: String, argv: [String]) {
        self.id = id
        self.displayName = displayName
        self.argv = argv
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
