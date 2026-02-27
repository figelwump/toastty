import Foundation

public enum AgentKind: String, Codable, CaseIterable, Equatable, Sendable {
    case claude
    case codex
}
