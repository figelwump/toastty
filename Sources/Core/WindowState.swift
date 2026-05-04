import Foundation

public struct WindowState: Codable, Equatable, Identifiable, Sendable {
    public static let defaultSidebarWidthBeforeAgentLaunch: Double = 180
    public static let defaultSidebarWidthAfterAgentLaunch: Double = 280
    public static let minSidebarWidth: Double = 160
    public static let maxSidebarWidth: Double = 480
    public static let sidebarWidthComparisonEpsilon: Double = 0.0001

    public let id: UUID
    public var frame: CGRectCodable
    public var workspaceIDs: [UUID]
    public var selectedWorkspaceID: UUID?
    public var sidebarVisible: Bool
    public var sidebarWidthPointsOverride: Double?
    public var terminalFontSizePointsOverride: Double?
    public var markdownTextScaleOverride: Double?

    public init(
        id: UUID,
        frame: CGRectCodable,
        workspaceIDs: [UUID],
        selectedWorkspaceID: UUID?,
        sidebarVisible: Bool = true,
        sidebarWidthPointsOverride: Double? = nil,
        terminalFontSizePointsOverride: Double? = nil,
        markdownTextScaleOverride: Double? = nil
    ) {
        self.id = id
        self.frame = frame
        self.workspaceIDs = workspaceIDs
        self.selectedWorkspaceID = selectedWorkspaceID
        self.sidebarVisible = sidebarVisible
        self.sidebarWidthPointsOverride = Self.normalizedSidebarWidthOverride(sidebarWidthPointsOverride)
        self.terminalFontSizePointsOverride = terminalFontSizePointsOverride.map(AppState.clampedTerminalFontPoints)
        self.markdownTextScaleOverride = AppState.normalizedMarkdownTextScaleOverride(markdownTextScaleOverride)
    }

    public static func clampedSidebarWidth(_ width: Double) -> Double {
        min(max(width, minSidebarWidth), maxSidebarWidth)
    }

    public static func normalizedSidebarWidthOverride(_ width: Double?) -> Double? {
        guard let width, width.isFinite else { return nil }
        return clampedSidebarWidth(width)
    }

    public static func normalizedSidebarWidthOverride(_ width: Double?, defaultWidth: Double) -> Double? {
        guard let width,
              width.isFinite,
              defaultWidth.isFinite else {
            return nil
        }

        let clampedWidth = clampedSidebarWidth(width)
        let clampedDefaultWidth = clampedSidebarWidth(defaultWidth)
        guard abs(clampedWidth - clampedDefaultWidth) >= sidebarWidthComparisonEpsilon else {
            return nil
        }
        return clampedWidth
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case frame
        case workspaceIDs
        case selectedWorkspaceID
        case sidebarVisible
        case sidebarWidthPointsOverride
        case terminalFontSizePointsOverride
        case markdownTextScaleOverride
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        frame = try container.decode(CGRectCodable.self, forKey: .frame)
        workspaceIDs = try container.decode([UUID].self, forKey: .workspaceIDs)
        selectedWorkspaceID = try container.decodeIfPresent(UUID.self, forKey: .selectedWorkspaceID)
        sidebarVisible = try container.decodeIfPresent(Bool.self, forKey: .sidebarVisible) ?? true
        sidebarWidthPointsOverride = Self.normalizedSidebarWidthOverride(
            try container.decodeIfPresent(
                Double.self,
                forKey: .sidebarWidthPointsOverride
            )
        )
        terminalFontSizePointsOverride = try container.decodeIfPresent(
            Double.self,
            forKey: .terminalFontSizePointsOverride
        ).map(AppState.clampedTerminalFontPoints)
        markdownTextScaleOverride = AppState.normalizedMarkdownTextScaleOverride(
            try container.decodeIfPresent(
                Double.self,
                forKey: .markdownTextScaleOverride
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(frame, forKey: .frame)
        try container.encode(workspaceIDs, forKey: .workspaceIDs)
        try container.encodeIfPresent(selectedWorkspaceID, forKey: .selectedWorkspaceID)
        try container.encode(sidebarVisible, forKey: .sidebarVisible)
        try container.encodeIfPresent(sidebarWidthPointsOverride, forKey: .sidebarWidthPointsOverride)
        try container.encodeIfPresent(terminalFontSizePointsOverride, forKey: .terminalFontSizePointsOverride)
        try container.encodeIfPresent(markdownTextScaleOverride, forKey: .markdownTextScaleOverride)
    }
}
