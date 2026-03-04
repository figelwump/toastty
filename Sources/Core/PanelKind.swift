import Foundation

public enum PanelKind: String, Codable, CaseIterable, Hashable, Sendable {
    case terminal
    case diff
    case markdown
    case scratchpad
    case screenshots
}
