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

    /// The compact age session rows use, so both lists read alike.
    static func age(_ updatedAt: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(updatedAt))
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
        return "\(Int(seconds / 86_400))d"
    }

    /// Folder hints for panels that share a title, keyed by panel. Each hint
    /// is the shortest run of trailing folders in the panel's file path that
    /// no other same-titled panel's path ends with, such as `smoke` or
    /// `a/smoke`. Unique titles, panels without a file path, and panels
    /// whose folders match another's in full get no hint.
    static func folderHints(_ panels: [RemoteWorkspacePanel]) -> [UUID: String] {
        var hints: [UUID: String] = [:]
        let byTitle = Dictionary(grouping: panels, by: \.title)
        for group in byTitle.values where group.count > 1 {
            let folders = group.compactMap { panel in
                panel.filePath.map { (panel.panelID, parentFolders(of: $0)) }
            }
            for (panelID, own) in folders where !own.isEmpty {
                let others = folders.filter { $0.0 != panelID }.map(\.1)
                let depth = (1...own.count).first { depth in
                    let suffix = own.suffix(depth)
                    return others.allSatisfy { $0.suffix(depth) != suffix }
                }
                if let depth {
                    hints[panelID] = own.suffix(depth).joined(separator: "/")
                }
            }
        }
        return hints
    }

    private static func parentFolders(of filePath: String) -> [String] {
        // NSString rather than a file URL, which would resolve a relative
        // Mac path against this app's own directory.
        ((filePath as NSString).deletingLastPathComponent as NSString)
            .pathComponents
            .filter { $0 != "/" }
    }
}
