import Foundation

public struct NotificationStore: Codable, Equatable, Sendable {
    public private(set) var notifications: [ToasttyNotification]

    public init(notifications: [ToasttyNotification] = []) {
        self.notifications = notifications
    }

    public mutating func record(
        workspaceID: UUID,
        panelID: UUID?,
        title: String,
        body: String,
        appIsFocused: Bool,
        sourcePanelIsFocused: Bool,
        at now: Date
    ) -> NotificationDecision {
        if appIsFocused && sourcePanelIsFocused {
            return NotificationDecision(stored: false, shouldSendSystemNotification: false)
        }

        if let panelID {
            notifications.removeAll { $0.panelID == panelID && $0.isRead == false }
        }

        notifications.append(
            ToasttyNotification(
                workspaceID: workspaceID,
                panelID: panelID,
                title: title,
                body: body,
                createdAt: now,
                isRead: false
            )
        )

        let shouldSendSystem = appIsFocused == false || sourcePanelIsFocused == false
        return NotificationDecision(stored: true, shouldSendSystemNotification: shouldSendSystem)
    }

    public mutating func markRead(workspaceID: UUID, panelID: UUID? = nil) {
        for index in notifications.indices {
            if notifications[index].workspaceID != workspaceID {
                continue
            }

            if let panelID, notifications[index].panelID != panelID {
                continue
            }

            notifications[index].isRead = true
        }
    }

    public var unreadCount: Int {
        notifications.reduce(0) { $0 + ($1.isRead ? 0 : 1) }
    }

    public func unreadCount(for workspaceID: UUID) -> Int {
        notifications.reduce(0) { partial, notification in
            guard notification.workspaceID == workspaceID, notification.isRead == false else {
                return partial
            }
            return partial + 1
        }
    }
}
