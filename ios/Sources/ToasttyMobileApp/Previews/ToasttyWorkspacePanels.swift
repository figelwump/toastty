import Foundation
import RemoteProtocol

enum ToasttyWorkspacePanels {
    static func sorted(_ panels: [RemoteWorkspacePanel]) -> [RemoteWorkspacePanel] {
        panels.sorted { left, right in
            switch (left.updatedAt, right.updatedAt) {
            case let (leftDate?, rightDate?) where leftDate != rightDate:
                return leftDate > rightDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                break
            }
            return left.panelID.uuidString < right.panelID.uuidString
        }
    }

    static func age(_ updatedAt: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(updatedAt))
        if seconds < 60 { return "Just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }
}
