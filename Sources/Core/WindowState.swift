import Foundation

public struct WindowState: Codable, Equatable, Identifiable, Sendable {
    public static let defaultSidebarWidthBeforeAgentLaunch: Double = 180
    public static let defaultSidebarWidthAfterAgentLaunch: Double = 280

    public let id: UUID
    public var frame: CGRectCodable
    public var workspaceIDs: [UUID]
    public var selectedWorkspaceID: UUID?
    public var sidebarVisible: Bool

    public init(
        id: UUID,
        frame: CGRectCodable,
        workspaceIDs: [UUID],
        selectedWorkspaceID: UUID?,
        sidebarVisible: Bool = true
    ) {
        self.id = id
        self.frame = frame
        self.workspaceIDs = workspaceIDs
        self.selectedWorkspaceID = selectedWorkspaceID
        self.sidebarVisible = sidebarVisible
    }
}
