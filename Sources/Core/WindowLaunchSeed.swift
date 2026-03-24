import Foundation

public struct WindowLaunchSeed: Equatable, Sendable {
    public var workspaceTitle: String?
    public var terminalCWD: String?
    public var terminalProfileBinding: TerminalProfileBinding?

    public init(
        workspaceTitle: String? = nil,
        terminalCWD: String? = nil,
        terminalProfileBinding: TerminalProfileBinding? = nil
    ) {
        self.workspaceTitle = workspaceTitle
        self.terminalCWD = terminalCWD
        self.terminalProfileBinding = terminalProfileBinding
    }
}
