import Foundation

/// Where the coordinator lives in the app state.
public struct CoordinatorLocation: Equatable, Sendable {
    public var windowID: UUID
    public var workspaceID: UUID
    /// The terminal panel the coordinator's agent runs in, or `nil` when
    /// that panel has closed while the workspace stayed open.
    public var panelID: UUID?

    public init(windowID: UUID, workspaceID: UUID, panelID: UUID?) {
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.panelID = panelID
    }
}

/// The coordinator is one long-lived agent session in its own top-level
/// workspace. `WorkspaceState.isCoordinator` marks that workspace, so the
/// mark is saved with the layout and leaves with the workspace. These
/// helpers are the one place that answers which workspace and panel it is.
extension AppState {
    public static let coordinatorWorkspaceTitle = "Coordinator"

    /// The coordinator's workspace and terminal panel, or `nil` when there
    /// is no coordinator.
    public var coordinator: CoordinatorLocation? {
        for window in windows {
            for workspaceID in window.workspaceIDs {
                guard let workspace = workspacesByID[workspaceID], workspace.isCoordinator else { continue }
                let panelID = workspace.coordinatorPanelID.flatMap { panelID -> UUID? in
                    guard case .terminal? = workspace.panelState(for: panelID) else { return nil }
                    return panelID
                }
                return CoordinatorLocation(windowID: window.id, workspaceID: workspaceID, panelID: panelID)
            }
        }
        return nil
    }

    public var coordinatorWorkspaceID: UUID? {
        coordinator?.workspaceID
    }

    public func isCoordinatorWorkspace(_ workspaceID: UUID) -> Bool {
        workspacesByID[workspaceID]?.isCoordinator == true
    }

    /// Keeps at most one coordinator workspace, and keeps it a top-level
    /// workspace that is not a task space. Restored layout files are
    /// user-editable, so this runs after a restore rather than trusting the
    /// saved marks. A mark that cannot hold is dropped, which leaves an
    /// ordinary workspace; it never fails the restore.
    public mutating func normalizeCoordinatorWorkspace() {
        var keptWorkspaceID: UUID?
        for window in windows {
            for workspaceID in window.workspaceIDs {
                guard let workspace = workspacesByID[workspaceID], workspace.isCoordinator else { continue }
                if keptWorkspaceID == nil, workspace.taskID == nil {
                    keptWorkspaceID = workspaceID
                }
            }
        }
        for (workspaceID, workspace) in workspacesByID {
            if workspaceID == keptWorkspaceID {
                // The coordinator is top-level whatever the file says.
                workspacesByID[workspaceID]?.parentWorkspaceID = nil
                workspacesByID[workspaceID]?.spawningSessionID = nil
                workspacesByID[workspaceID]?.doneAt = nil
                if let panelID = workspace.coordinatorPanelID {
                    if case .terminal? = workspace.panelState(for: panelID) {} else {
                        workspacesByID[workspaceID]?.coordinatorPanelID = nil
                    }
                }
            } else if workspace.isCoordinator || workspace.coordinatorPanelID != nil {
                workspacesByID[workspaceID]?.isCoordinator = false
                workspacesByID[workspaceID]?.coordinatorPanelID = nil
            }
        }
    }
}
