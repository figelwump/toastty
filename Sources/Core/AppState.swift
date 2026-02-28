import Foundation

public struct AppState: Codable, Equatable, Sendable {
    public static let defaultTerminalFontPoints: Double = 12
    public static let minTerminalFontPoints: Double = 6
    public static let maxTerminalFontPoints: Double = 24
    public static let terminalFontStepPoints: Double = 1
    public static let terminalFontComparisonEpsilon: Double = 0.0001

    public var windows: [WindowState]
    public var workspacesByID: [UUID: WorkspaceState]
    public var selectedWindowID: UUID?
    public var configuredTerminalFontPoints: Double?
    public var globalTerminalFontPoints: Double

    public init(
        windows: [WindowState],
        workspacesByID: [UUID: WorkspaceState],
        selectedWindowID: UUID?,
        configuredTerminalFontPoints: Double? = nil,
        globalTerminalFontPoints: Double
    ) {
        self.windows = windows
        self.workspacesByID = workspacesByID
        self.selectedWindowID = selectedWindowID
        self.configuredTerminalFontPoints = configuredTerminalFontPoints
        self.globalTerminalFontPoints = globalTerminalFontPoints
    }

    public static func clampedTerminalFontPoints(_ points: Double) -> Double {
        min(max(points, minTerminalFontPoints), maxTerminalFontPoints)
    }

    public static func bootstrap() -> AppState {
        let workspace = WorkspaceState.bootstrap()
        let window = WindowState(
            id: UUID(),
            frame: CGRectCodable(x: 120, y: 120, width: 1280, height: 760),
            workspaceIDs: [workspace.id],
            selectedWorkspaceID: workspace.id
        )

        return AppState(
            windows: [window],
            workspacesByID: [workspace.id: workspace],
            selectedWindowID: window.id,
            configuredTerminalFontPoints: nil,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )
    }
}
