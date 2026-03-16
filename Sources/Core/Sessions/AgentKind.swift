import Foundation

public struct AgentKind: RawRepresentable, Codable, Hashable, Equatable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return nil }
        guard normalized == normalized.lowercased() else { return nil }

        let leading = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz")
        guard let firstScalar = normalized.unicodeScalars.first,
              leading.contains(firstScalar) else {
            return nil
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
        guard normalized.unicodeScalars.dropFirst().allSatisfy(allowed.contains) else { return nil }
        self.rawValue = normalized
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let parsed = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid agent ID: \(rawValue)"
            )
        }
        self = parsed
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let claude = Self(rawValue: "claude")!
    public static let codex = Self(rawValue: "codex")!

    public var displayName: String {
        switch self {
        case .claude:
            return "Claude Code"
        case .codex:
            return "Codex"
        default:
            return rawValue
                .split(separator: "-")
                .map { component in
                    component.prefix(1).uppercased() + component.dropFirst()
                }
                .joined(separator: " ")
        }
    }
}
