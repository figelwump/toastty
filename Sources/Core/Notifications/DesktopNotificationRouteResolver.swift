import Foundation

public enum DesktopNotificationUserInfoKey {
    public static let workspaceID = "workspaceID"
    public static let panelID = "panelID"
}

public struct DesktopNotificationSelectionHint: Equatable, Sendable {
    public let workspaceID: UUID?
    public let panelID: UUID?

    public init(workspaceID: UUID? = nil, panelID: UUID? = nil) {
        self.workspaceID = workspaceID
        self.panelID = panelID
    }

    public init(userInfo: [AnyHashable: Any]) {
        workspaceID = Self.uuidValue(for: DesktopNotificationUserInfoKey.workspaceID, in: userInfo)
        panelID = Self.uuidValue(for: DesktopNotificationUserInfoKey.panelID, in: userInfo)
    }

    private static func uuidValue(for key: String, in userInfo: [AnyHashable: Any]) -> UUID? {
        let value = userInfo[key] ?? userInfo[AnyHashable(key as NSString)]

        if let value = value as? UUID {
            return value
        }
        if let rawValue = value as? NSString {
            return UUID(uuidString: rawValue as String)
        }

        guard let rawValue = value as? String else {
            return nil
        }
        return UUID(uuidString: rawValue)
    }
}

public struct DesktopNotificationActivationRoute: Equatable, Sendable {
    public let windowID: UUID
    public let workspaceID: UUID
    public let panelID: UUID?

    public init(windowID: UUID, workspaceID: UUID, panelID: UUID?) {
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.panelID = panelID
    }
}

public enum DesktopNotificationRouteResolver {
    public static func resolve(
        hint: DesktopNotificationSelectionHint,
        state: AppState
    ) -> DesktopNotificationActivationRoute? {
        if let panelID = hint.panelID,
           let location = locatePanel(panelID, in: state) {
            return DesktopNotificationActivationRoute(
                windowID: location.windowID,
                workspaceID: location.workspaceID,
                panelID: panelID
            )
        }

        if let workspaceID = hint.workspaceID,
           let location = locateWorkspace(workspaceID, in: state) {
            return DesktopNotificationActivationRoute(
                windowID: location.windowID,
                workspaceID: workspaceID,
                panelID: nil
            )
        }

        return nil
    }

    private static func locateWorkspace(
        _ workspaceID: UUID,
        in state: AppState
    ) -> (windowID: UUID, workspace: WorkspaceState)? {
        for window in state.windows where window.workspaceIDs.contains(workspaceID) {
            guard let workspace = state.workspacesByID[workspaceID] else {
                continue
            }
            return (window.id, workspace)
        }
        return nil
    }

    private static func locatePanel(
        _ panelID: UUID,
        in state: AppState
    ) -> (windowID: UUID, workspaceID: UUID)? {
        guard let selection = state.workspaceSelection(containingPanelID: panelID) else {
            return nil
        }
        return (selection.windowID, selection.workspaceID)
    }
}
