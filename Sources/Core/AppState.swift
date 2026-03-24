import Foundation

public struct WindowWorkspaceSelection: Equatable, Sendable {
    public let windowID: UUID
    public let window: WindowState
    public let workspaceID: UUID
    public let workspace: WorkspaceState

    public init(
        windowID: UUID,
        window: WindowState,
        workspaceID: UUID,
        workspace: WorkspaceState
    ) {
        self.windowID = windowID
        self.window = window
        self.workspaceID = workspaceID
        self.workspace = workspace
    }
}

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
    public var defaultTerminalProfileID: String?
    public var globalTerminalFontPoints: Double

    public init(
        windows: [WindowState],
        workspacesByID: [UUID: WorkspaceState],
        selectedWindowID: UUID?,
        configuredTerminalFontPoints: Double? = nil,
        defaultTerminalProfileID: String? = nil,
        globalTerminalFontPoints: Double
    ) {
        self.windows = windows
        self.workspacesByID = workspacesByID
        self.selectedWindowID = selectedWindowID
        self.configuredTerminalFontPoints = configuredTerminalFontPoints
        self.defaultTerminalProfileID = Self.normalizedTerminalProfileID(defaultTerminalProfileID)
        self.globalTerminalFontPoints = globalTerminalFontPoints
    }

    public static func clampedTerminalFontPoints(_ points: Double) -> Double {
        min(max(points, minTerminalFontPoints), maxTerminalFontPoints)
    }

    public static func normalizedTerminalProfileID(_ profileID: String?) -> String? {
        guard let profileID else { return nil }
        let trimmed = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        return trimmed
    }

    public var defaultTerminalProfileBinding: TerminalProfileBinding? {
        guard let defaultTerminalProfileID else { return nil }
        return TerminalProfileBinding(profileID: defaultTerminalProfileID)
    }

    public static func bootstrap(defaultTerminalProfileID: String? = nil) -> AppState {
        let normalizedDefaultTerminalProfileID = normalizedTerminalProfileID(defaultTerminalProfileID)
        let workspace = WorkspaceState.bootstrap(
            initialTerminalProfileBinding: normalizedDefaultTerminalProfileID.map { profileID in
                TerminalProfileBinding(profileID: profileID)
            }
        )
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
            defaultTerminalProfileID: normalizedDefaultTerminalProfileID,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )
    }

    public func window(id windowID: UUID) -> WindowState? {
        windows.first(where: { $0.id == windowID })
    }

    public func selectedWorkspaceID(in windowID: UUID) -> UUID? {
        guard let window = window(id: windowID) else { return nil }
        return window.selectedWorkspaceID ?? window.workspaceIDs.first
    }

    public func workspaceSelection(in windowID: UUID) -> WindowWorkspaceSelection? {
        guard let window = window(id: windowID),
              let workspaceID = selectedWorkspaceID(in: windowID),
              let workspace = workspacesByID[workspaceID] else {
            return nil
        }

        return WindowWorkspaceSelection(
            windowID: windowID,
            window: window,
            workspaceID: workspaceID,
            workspace: workspace
        )
    }

    public func workspaceSelection(containingWorkspaceID workspaceID: UUID) -> WindowWorkspaceSelection? {
        guard let window = windows.first(where: { $0.workspaceIDs.contains(workspaceID) }),
              let workspace = workspacesByID[workspaceID] else {
            return nil
        }

        return WindowWorkspaceSelection(
            windowID: window.id,
            window: window,
            workspaceID: workspaceID,
            workspace: workspace
        )
    }

    public func selectedWorkspaceSelection() -> WindowWorkspaceSelection? {
        guard let selectedWindowID else { return nil }
        return workspaceSelection(in: selectedWindowID)
    }

    public func soleWorkspaceSelection() -> WindowWorkspaceSelection? {
        guard windows.count == 1,
              let windowID = windows.first?.id else {
            return nil
        }
        return workspaceSelection(in: windowID)
    }
}
