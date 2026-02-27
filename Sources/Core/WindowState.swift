import Foundation

public struct WindowState: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var frame: CGRectCodable
    public var workspaceIDs: [UUID]
    public var selectedWorkspaceID: UUID?

    public init(id: UUID, frame: CGRectCodable, workspaceIDs: [UUID], selectedWorkspaceID: UUID?) {
        self.id = id
        self.frame = frame
        self.workspaceIDs = workspaceIDs
        self.selectedWorkspaceID = selectedWorkspaceID
    }
}
