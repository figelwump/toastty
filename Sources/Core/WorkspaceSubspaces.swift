import Foundation

/// Subspaces are workspaces nested one level under a top-level workspace in
/// the same window, typically task worktrees an agent spawned from there.
/// The link lives on the child (`WorkspaceState.parentWorkspaceID`); these
/// helpers derive the tree from it and keep it well formed.
extension AppState {
    /// Workspaces of a window that are not nested under another, in window
    /// order. This is the list the sidebar shows as cards and that the
    /// workspace switch shortcuts count.
    public func topLevelWorkspaceIDs(in windowID: UUID) -> [UUID] {
        guard let window = windows.first(where: { $0.id == windowID }) else { return [] }
        return window.workspaceIDs.filter { workspaceID in
            guard let workspace = workspacesByID[workspaceID] else { return false }
            return isValidParentLink(from: workspace, in: window) == false
        }
    }

    /// Subspaces nested under `parentWorkspaceID`, in window order.
    public func subspaceWorkspaceIDs(of parentWorkspaceID: UUID) -> [UUID] {
        guard let window = windows.first(where: { $0.workspaceIDs.contains(parentWorkspaceID) }) else {
            return []
        }
        return window.workspaceIDs.filter { workspaceID in
            guard workspaceID != parentWorkspaceID,
                  let workspace = workspacesByID[workspaceID],
                  workspace.parentWorkspaceID == parentWorkspaceID else {
                return false
            }
            return isValidParentLink(from: workspace, in: window)
        }
    }

    /// The parent that nesting `workspaceID` under `requestedParentID` would
    /// resolve to, or `nil` when the request is invalid. A requested parent
    /// that is itself a subspace resolves to its root so nesting stays one
    /// level deep; a parent in another window, the workspace itself, or a
    /// link that would form a cycle is rejected.
    public func resolvedParentWorkspaceID(
        forNesting workspaceID: UUID,
        under requestedParentID: UUID
    ) -> UUID? {
        guard workspaceID != requestedParentID,
              let window = windows.first(where: { $0.workspaceIDs.contains(workspaceID) }),
              window.workspaceIDs.contains(requestedParentID),
              workspacesByID[requestedParentID] != nil,
              let rootID = rootWorkspaceID(of: requestedParentID, in: window),
              rootID != workspaceID else {
            return nil
        }
        return rootID
    }

    /// Workspaces of a window in the order the sidebar shows them: each
    /// top-level workspace followed by its subspaces.
    public func sidebarOrderedWorkspaceIDs(in windowID: UUID) -> [UUID] {
        topLevelWorkspaceIDs(in: windowID).flatMap { workspaceID in
            [workspaceID] + subspaceWorkspaceIDs(of: workspaceID)
        }
    }

    /// The parent a workspace created in `windowID` would nest under when it
    /// asks for `requestedParentID`: that workspace's root, or `nil` when it
    /// is not in the window.
    public func resolvedParentWorkspaceID(
        forNewWorkspaceIn windowID: UUID,
        under requestedParentID: UUID
    ) -> UUID? {
        guard let window = windows.first(where: { $0.id == windowID }),
              window.workspaceIDs.contains(requestedParentID),
              workspacesByID[requestedParentID] != nil else {
            return nil
        }
        return rootWorkspaceID(of: requestedParentID, in: window)
    }

    /// Drops parent links that no longer resolve and flattens deeper nesting
    /// to one level. Restored layout files are user-editable, and windows can
    /// lose workspaces without visiting every link, so this runs after a
    /// restore rather than trusting persisted links.
    public mutating func normalizeWorkspaceParentLinks() {
        for window in windows {
            for workspaceID in window.workspaceIDs {
                guard let workspace = workspacesByID[workspaceID],
                      let parentID = workspace.parentWorkspaceID else {
                    continue
                }
                let resolvedParentID = resolvedParentWorkspaceID(forNesting: workspaceID, under: parentID)
                if resolvedParentID != parentID {
                    workspacesByID[workspaceID]?.parentWorkspaceID = resolvedParentID
                    if resolvedParentID == nil {
                        workspacesByID[workspaceID]?.spawningSessionID = nil
                    }
                }
            }
        }
        // Links whose parent was dropped above (or lives in a window that
        // no longer exists) must not survive as dangling references, and a
        // spawner only means something for a nested workspace.
        for (workspaceID, workspace) in workspacesByID {
            guard let parentID = workspace.parentWorkspaceID else {
                if workspace.spawningSessionID != nil {
                    workspacesByID[workspaceID]?.spawningSessionID = nil
                }
                continue
            }
            let isValid = windows.contains { window in
                window.workspaceIDs.contains(workspaceID)
                    && window.workspaceIDs.contains(parentID)
                    && workspacesByID[parentID]?.parentWorkspaceID == nil
            }
            if isValid == false {
                workspacesByID[workspaceID]?.parentWorkspaceID = nil
                workspacesByID[workspaceID]?.spawningSessionID = nil
            }
        }
    }

    private func isValidParentLink(from workspace: WorkspaceState, in window: WindowState) -> Bool {
        guard let parentID = workspace.parentWorkspaceID,
              parentID != workspace.id,
              window.workspaceIDs.contains(parentID),
              let parent = workspacesByID[parentID] else {
            return false
        }
        // Only a top-level parent counts; a deeper link is flattened by the
        // reducer and by `normalizeWorkspaceParentLinks`.
        return parent.parentWorkspaceID == nil
    }

    /// Follows parent links from `workspaceID` to a workspace with no parent.
    /// Returns `nil` when a link leaves the window, points at a missing
    /// workspace, or loops.
    private func rootWorkspaceID(of workspaceID: UUID, in window: WindowState) -> UUID? {
        var visited: Set<UUID> = [workspaceID]
        var currentID = workspaceID
        while let parentID = workspacesByID[currentID]?.parentWorkspaceID {
            guard window.workspaceIDs.contains(parentID),
                  workspacesByID[parentID] != nil,
                  visited.insert(parentID).inserted else {
                return nil
            }
            currentID = parentID
        }
        return currentID
    }
}
