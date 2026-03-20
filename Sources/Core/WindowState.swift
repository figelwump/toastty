import Foundation

public struct WindowState: Codable, Equatable, Identifiable, Sendable {
    public static let defaultSidebarWidthBeforeAgentLaunch: Double = 180
    public static let defaultSidebarWidthAfterAgentLaunch: Double = 280
    public static let minimumSidebarWidthOverride: Double = defaultSidebarWidthBeforeAgentLaunch
    public static let maximumSidebarWidthOverride: Double = 420

    public let id: UUID
    public var frame: CGRectCodable
    public var workspaceIDs: [UUID]
    public var selectedWorkspaceID: UUID?
    public var sidebarVisible: Bool
    /// When nil, the window uses the app-wide default chosen by the agent-launch milestone.
    public var sidebarWidthOverride: Double?

    private enum CodingKeys: String, CodingKey {
        case id
        case frame
        case workspaceIDs
        case selectedWorkspaceID
        case sidebarVisible
        case sidebarWidthOverride
    }

    public init(
        id: UUID,
        frame: CGRectCodable,
        workspaceIDs: [UUID],
        selectedWorkspaceID: UUID?,
        sidebarVisible: Bool = true,
        sidebarWidthOverride: Double? = nil
    ) {
        self.id = id
        self.frame = frame
        self.workspaceIDs = workspaceIDs
        self.selectedWorkspaceID = selectedWorkspaceID
        self.sidebarVisible = sidebarVisible
        self.sidebarWidthOverride = sidebarWidthOverride.map(Self.clampedSidebarWidthOverride)
    }

    public static func clampedSidebarWidthOverride(_ width: Double) -> Double {
        min(max(width, minimumSidebarWidthOverride), maximumSidebarWidthOverride)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        frame = try container.decode(CGRectCodable.self, forKey: .frame)
        workspaceIDs = try container.decode([UUID].self, forKey: .workspaceIDs)
        selectedWorkspaceID = try container.decodeIfPresent(UUID.self, forKey: .selectedWorkspaceID)
        sidebarVisible = try container.decode(Bool.self, forKey: .sidebarVisible)
        sidebarWidthOverride = try container.decodeIfPresent(Double.self, forKey: .sidebarWidthOverride)
            .map(Self.clampedSidebarWidthOverride)
    }
}
