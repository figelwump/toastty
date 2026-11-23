import CoreState
import Foundation

enum TerminalLocalInputKind: String {
    case key
    case controlC
    case paste
    case programmatic
}

enum TerminalLocalInterruptKind: Equatable, Sendable {
    case escape
    case controlC
}

enum ManagedSessionStopReason: Equatable, Sendable {
    case explicit
    case ghosttyCommandFinished(exitCode: Int?)
    case idleAtPrompt
    case panelRemovedFromAppState
    case replacedByNewSession

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
        case .replacedByNewSession:
            return "replaced_by_new_session"
        }
    }

    var isAutomatic: Bool {
        switch self {
        case .explicit:
            return false
        case .ghosttyCommandFinished, .idleAtPrompt, .panelRemovedFromAppState, .replacedByNewSession:
            return true
        }
    }
}

@MainActor
protocol TerminalSessionLifecycleTracking: AnyObject {
    func handleProgramStatusEvent(_ event: TerminalProgramStatusEvent, panelID: UUID)
    func activeSessionUsesStatusNotifications(panelID: UUID) -> Bool
    func noteLocalInputForActiveSession(panelID: UUID)
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
    func handleCommandFinished(panelID: UUID, exitCode: Int?, at now: Date) -> Bool
    func stopSessionForPanelIfActive(panelID: UUID, reason: ManagedSessionStopReason, at now: Date) -> Bool
    func stopSessionForPanelIfOlderThan(
        panelID: UUID,
        minimumRuntime: TimeInterval,
        reason: ManagedSessionStopReason,
        at now: Date
    ) -> Bool
    /// Toastty typed the launch command for `sessionID` into its panel's
    /// shell. `shellWasAtPrompt` is false when the command was typed without
    /// a check that the shell showed its prompt, as a restored launch does.
    func noteManagedLaunchCommandSubmitted(sessionID: String, shellWasAtPrompt: Bool, at now: Date)
    /// The shell in `panelID` is at its prompt. True while the panel's active
    /// session still waits for the shell to start a typed launch command, so
    /// the prompt does not yet mean that the agent has ended.
    func isAwaitingManagedLaunchCommandStart(panelID: UUID, at now: Date) -> Bool
    /// The shell in `panelID` runs a command or has exited.
    func noteShellLeftPrompt(panelID: UUID, at now: Date)
}

extension TerminalSessionLifecycleTracking {
    func handleProgramStatusEvent(_ event: TerminalProgramStatusEvent, panelID: UUID) {}
    func noteManagedLaunchCommandSubmitted(sessionID: String, shellWasAtPrompt: Bool, at now: Date) {}
    func isAwaitingManagedLaunchCommandStart(panelID: UUID, at now: Date) -> Bool { false }
    func noteShellLeftPrompt(panelID: UUID, at now: Date) {}
}
