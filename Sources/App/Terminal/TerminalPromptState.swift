import Foundation

enum TerminalPromptState: Equatable, Sendable {
    case unavailable
    case exited
    case idleAtPrompt
    case busy

    var isIdleAtPrompt: Bool {
        self == .idleAtPrompt
    }
}
