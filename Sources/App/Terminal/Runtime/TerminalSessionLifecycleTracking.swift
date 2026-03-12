import Foundation

@MainActor
protocol TerminalSessionLifecycleTracking: AnyObject {
    func stopSessionForPanelIfActive(panelID: UUID, at now: Date) -> Bool
    func stopSessionForPanelIfOlderThan(panelID: UUID, minimumRuntime: TimeInterval, at now: Date) -> Bool
}
