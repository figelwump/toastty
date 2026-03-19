import Foundation

enum TerminalLocalInterruptKind: Equatable, Sendable {
    case escape
    case controlC
}

@MainActor
protocol TerminalSessionLifecycleTracking: AnyObject {
    func activeSessionUsesStatusNotifications(panelID: UUID) -> Bool
    func handleLocalInterruptForPanelIfActive(
        panelID: UUID,
        kind: TerminalLocalInterruptKind,
        at now: Date
    ) -> Bool
    func stopSessionForPanelIfActive(panelID: UUID, at now: Date) -> Bool
    func stopSessionForPanelIfOlderThan(panelID: UUID, minimumRuntime: TimeInterval, at now: Date) -> Bool
}
