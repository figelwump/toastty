import Foundation

enum TerminalLocalInterruptKind: Equatable, Sendable {
    case escape
    case controlC
}

enum ManagedSessionStopReason: Equatable, Sendable {
    case explicit
    case ghosttyCommandFinished(exitCode: Int?)
    case idleShellPrompt(recentPromptCommandToken: String?, appearsBusy: Bool)
    case panelRemovedFromAppState

    var code: String {
        switch self {
        case .explicit:
            return "explicit"
        case .ghosttyCommandFinished:
            return "ghostty_command_finished"
        case .idleShellPrompt:
            return "idle_shell_prompt"
        case .panelRemovedFromAppState:
            return "panel_removed_from_app_state"
        }
    }

    var isAutomatic: Bool {
        switch self {
        case .explicit:
            return false
        case .ghosttyCommandFinished, .idleShellPrompt, .panelRemovedFromAppState:
            return true
        }
    }
}

@MainActor
protocol TerminalSessionLifecycleTracking: AnyObject {
    func activeSessionUsesStatusNotifications(panelID: UUID) -> Bool
    func handleLocalInterruptForPanelIfActive(
        panelID: UUID,
        kind: TerminalLocalInterruptKind,
        at now: Date
    ) -> Bool
    func stopSessionForPanelIfActive(panelID: UUID, reason: ManagedSessionStopReason, at now: Date) -> Bool
    func stopSessionForPanelIfOlderThan(
        panelID: UUID,
        minimumRuntime: TimeInterval,
        reason: ManagedSessionStopReason,
        at now: Date
    ) -> Bool
}
