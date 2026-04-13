import Foundation

enum TerminalLocalInterruptKind: Equatable, Sendable {
    case escape
    case controlC
}

enum ManagedSessionStopReason: Equatable, Sendable {
    case explicit
    case ghosttyCommandFinished(exitCode: Int?)
    case idleAtPrompt
    case panelRemovedFromAppState

    var code: String {
        switch self {
        case .explicit:
            return "explicit"
        case .ghosttyCommandFinished:
            return "ghostty_command_finished"
        case .idleAtPrompt:
            return "idle_at_prompt"
        case .panelRemovedFromAppState:
            return "panel_removed_from_app_state"
        }
    }

    var isAutomatic: Bool {
        switch self {
        case .explicit:
            return false
        case .ghosttyCommandFinished, .idleAtPrompt, .panelRemovedFromAppState:
            return true
        }
    }
}

@MainActor
protocol TerminalSessionLifecycleTracking: AnyObject {
    func activeSessionUsesStatusNotifications(panelID: UUID) -> Bool
    @discardableResult
    func refreshManagedSessionStatusFromVisibleTextIfNeeded(
        panelID: UUID,
        visibleText: String,
        promptState: TerminalPromptState,
        at now: Date
    ) -> Bool
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
