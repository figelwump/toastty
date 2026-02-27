import Foundation

public struct ToasttyNotification: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var workspaceID: UUID
    public var panelID: UUID?
    public var title: String
    public var body: String
    public var createdAt: Date
    public var isRead: Bool

    public init(
        id: UUID = UUID(),
        workspaceID: UUID,
        panelID: UUID?,
        title: String,
        body: String,
        createdAt: Date,
        isRead: Bool = false
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.panelID = panelID
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.isRead = isRead
    }
}

public struct NotificationDecision: Equatable, Sendable {
    public var stored: Bool
    public var shouldSendSystemNotification: Bool

    public init(stored: Bool, shouldSendSystemNotification: Bool) {
        self.stored = stored
        self.shouldSendSystemNotification = shouldSendSystemNotification
    }
}
