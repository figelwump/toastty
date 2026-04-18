import Foundation

public struct WindowLaunchSeed: Equatable, Sendable {
    public var workspaceTitle: String?
    public var terminalCWD: String?
    public var terminalProfileBinding: TerminalProfileBinding?
    public var windowTerminalFontSizePointsOverride: Double?
    public var windowMarkdownTextScaleOverride: Double?

    public init(
        workspaceTitle: String? = nil,
        terminalCWD: String? = nil,
        terminalProfileBinding: TerminalProfileBinding? = nil,
        windowTerminalFontSizePointsOverride: Double? = nil,
        windowMarkdownTextScaleOverride: Double? = nil
    ) {
        self.workspaceTitle = workspaceTitle
        self.terminalCWD = terminalCWD
        self.terminalProfileBinding = terminalProfileBinding
        self.windowTerminalFontSizePointsOverride = windowTerminalFontSizePointsOverride
        self.windowMarkdownTextScaleOverride = windowMarkdownTextScaleOverride
    }
}
