import Foundation

public struct TerminalCloseConfirmationAssessment: Equatable, Sendable {
    public let requiresConfirmation: Bool
    public let runningCommand: String?

    public init(requiresConfirmation: Bool, runningCommand: String? = nil) {
        self.requiresConfirmation = requiresConfirmation
        self.runningCommand = runningCommand
    }
}
