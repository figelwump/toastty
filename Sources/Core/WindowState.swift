import Foundation

/// What a window's sidebar lists: every project card, with its sessions and
/// tasks in Needs you, Running and Idle, or only the rows that need the user.
public enum SidebarSegment: String, Codable, CaseIterable, Sendable {
    case all
    case needsYou

    /// A segment by its name. The names saved before the segments were
    /// renamed still work: `projects` is All and `status` is Needs you.
    public init?(name: String) {
        switch name {
        case Self.all.rawValue, "projects": self = .all
        case Self.needsYou.rawValue, "status": self = .needsYou
        default: return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        guard let segment = Self(name: name) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown sidebar segment \(name)"
            ))
        }
        self = segment
    }
}

public struct WindowState: Codable, Equatable, Identifiable, Sendable {
    public static let defaultSidebarWidth: Double = 280
    public static let minSidebarWidth: Double = 160
    public static let maxSidebarWidth: Double = 480
    public static let sidebarWidthComparisonEpsilon: Double = 0.0001
    /// The coordinator's dock: a column between the sidebar and the
    /// workspace that shows the coordinator's chat.
    public static let defaultCoordinatorDockWidth: Double = 360
    public static let minCoordinatorDockWidth: Double = 300
    public static let maxCoordinatorDockWidth: Double = 480

    public let id: UUID
    public var frame: CGRectCodable
    public var workspaceIDs: [UUID]
    public var selectedWorkspaceID: UUID?
    public var sidebarVisible: Bool
    public var sidebarWidthPointsOverride: Double?
    public var terminalFontSizePointsOverride: Double?
    public var markdownTextScaleOverride: Double?
    public var sidebarSegment: SidebarSegment
    /// The project cards collapsed to their name line in the All segment.
    /// Saved with the window; a workspace that leaves the window drops out
    /// when the window is saved.
    public var collapsedSidebarWorkspaceIDs: Set<UUID>
    /// The user opened the coordinator's dock in this window. It shows only
    /// in the window that holds the coordinator's workspace, and only while
    /// that workspace is not the selected one.
    public var coordinatorDockVisible: Bool
    /// The dock's width after a resize, or `nil` for the default width.
    public var coordinatorDockWidthPointsOverride: Double?
    /// Whether the Tasks view covers the workspace content. Not saved: a
    /// relaunch opens the workspace the window had selected.
    public var showsTasksView: Bool

    public init(
        id: UUID,
        frame: CGRectCodable,
        workspaceIDs: [UUID],
        selectedWorkspaceID: UUID?,
        sidebarVisible: Bool = true,
        sidebarWidthPointsOverride: Double? = nil,
        terminalFontSizePointsOverride: Double? = nil,
        markdownTextScaleOverride: Double? = nil,
        sidebarSegment: SidebarSegment = .all,
        collapsedSidebarWorkspaceIDs: Set<UUID> = [],
        showsTasksView: Bool = false,
        coordinatorDockVisible: Bool = false,
        coordinatorDockWidthPointsOverride: Double? = nil
    ) {
        self.id = id
        self.frame = frame
        self.workspaceIDs = workspaceIDs
        self.selectedWorkspaceID = selectedWorkspaceID
        self.sidebarVisible = sidebarVisible
        self.sidebarWidthPointsOverride = Self.normalizedSidebarWidthOverride(sidebarWidthPointsOverride)
        self.terminalFontSizePointsOverride = terminalFontSizePointsOverride.map(AppState.clampedTerminalFontPoints)
        self.markdownTextScaleOverride = AppState.normalizedMarkdownTextScaleOverride(markdownTextScaleOverride)
        self.sidebarSegment = sidebarSegment
        self.collapsedSidebarWorkspaceIDs = collapsedSidebarWorkspaceIDs
        self.showsTasksView = showsTasksView
        self.coordinatorDockVisible = coordinatorDockVisible
        self.coordinatorDockWidthPointsOverride = Self.normalizedCoordinatorDockWidthOverride(coordinatorDockWidthPointsOverride)
    }

    /// The dock's width within its limits, or `nil` for a width that is not
    /// a number or is the default.
    public static func normalizedCoordinatorDockWidthOverride(_ width: Double?) -> Double? {
        guard let width, width.isFinite else { return nil }
        let clamped = min(max(width, minCoordinatorDockWidth), maxCoordinatorDockWidth)
        guard abs(clamped - defaultCoordinatorDockWidth) >= sidebarWidthComparisonEpsilon else { return nil }
        return clamped
    }

    public var coordinatorDockWidth: Double {
        coordinatorDockWidthPointsOverride ?? Self.defaultCoordinatorDockWidth
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
        case sidebarSegment
        case collapsedSidebarWorkspaceIDs
        case coordinatorDockVisible
        case coordinatorDockWidthPointsOverride
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
        // An unknown segment from a newer version falls back to All.
        sidebarSegment = (try? container.decodeIfPresent(SidebarSegment.self, forKey: .sidebarSegment)) ?? .all
        collapsedSidebarWorkspaceIDs = Set(
            ((try? container.decodeIfPresent([UUID].self, forKey: .collapsedSidebarWorkspaceIDs)) ?? nil) ?? []
        )
        showsTasksView = false
        coordinatorDockVisible = try container.decodeIfPresent(Bool.self, forKey: .coordinatorDockVisible) ?? false
        coordinatorDockWidthPointsOverride = Self.normalizedCoordinatorDockWidthOverride(
            try container.decodeIfPresent(Double.self, forKey: .coordinatorDockWidthPointsOverride)
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
        try container.encode(sidebarSegment, forKey: .sidebarSegment)
        let collapsed = workspaceIDs.filter(collapsedSidebarWorkspaceIDs.contains)
        if collapsed.isEmpty == false {
            try container.encode(collapsed, forKey: .collapsedSidebarWorkspaceIDs)
        }
        try container.encode(coordinatorDockVisible, forKey: .coordinatorDockVisible)
        try container.encodeIfPresent(coordinatorDockWidthPointsOverride, forKey: .coordinatorDockWidthPointsOverride)
    }
}
