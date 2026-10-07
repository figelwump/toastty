import CoreState
import Foundation

/// Navigation follows the sidebar's model order, including rows in collapsed
/// subspaces. Panels without session rows remain reachable after those rows.
@MainActor
struct SidebarPanelNavigationOrder {
    let forward: [PanelNavigationTarget]
    let wrapped: [PanelNavigationTarget]

    var all: [PanelNavigationTarget] { forward + wrapped }

    init(
        state: AppState,
        sessionRegistry: SessionRegistry?,
        displayedSubspaceOrderByParentID: [UUID: [UUID]],
        windowID: UUID,
        workspaceID: UUID,
        focusedPanelID: UUID?
    ) {
        guard let windowIndex = state.windows.firstIndex(where: { $0.id == windowID }) else {
            forward = []
            wrapped = []
            return
        }

        let current = Self.targets(
            in: state,
            windowID: windowID,
            sessionRegistry: sessionRegistry,
            displayedSubspaceOrderByParentID: displayedSubspaceOrderByParentID
        )
        let focusedIndex = current.targets.firstIndex { $0.panelID == focusedPanelID }
        let hasSessionRows = current.targets.contains {
            $0.workspaceID == workspaceID && current.sessionPanelIDs.contains($0.panelID)
        }
        let splitIndex: Int
        if let focusedIndex,
           !hasSessionRows || focusedPanelID.map(current.sessionPanelIDs.contains) == true {
            splitIndex = focusedIndex + 1
        } else {
            // With no session row selected, the workspace header is the
            // sidebar anchor. An empty session list uses the panel layout.
            let workspaceIndex = current.workspaceIDs.firstIndex(of: workspaceID) ?? 0
            let followingWorkspaceIDs = Set(current.workspaceIDs.dropFirst(workspaceIndex))
            splitIndex = current.targets.firstIndex {
                followingWorkspaceIDs.contains($0.workspaceID)
            } ?? current.targets.count
        }

        var forwardTargets = Array(current.targets.dropFirst(splitIndex))
        let otherWindows = Array(state.windows.dropFirst(windowIndex + 1)) + Array(state.windows.prefix(windowIndex))
        for window in otherWindows {
            forwardTargets += Self.targets(
                in: state,
                windowID: window.id,
                sessionRegistry: sessionRegistry,
                displayedSubspaceOrderByParentID: displayedSubspaceOrderByParentID
            ).targets
        }
        var seenPanelIDs = Set<UUID>()
        forward = forwardTargets.filter { $0.panelID != focusedPanelID && seenPanelIDs.insert($0.panelID).inserted }
        wrapped = current.targets.prefix(splitIndex).filter { $0.panelID != focusedPanelID && seenPanelIDs.insert($0.panelID).inserted }
    }

    private static func targets(
        in state: AppState,
        windowID: UUID,
        sessionRegistry: SessionRegistry?,
        displayedSubspaceOrderByParentID: [UUID: [UUID]]
    ) -> (targets: [PanelNavigationTarget], sessionPanelIDs: Set<UUID>, workspaceIDs: [UUID]) {
        guard let window = state.window(id: windowID) else { return ([], [], []) }
        var workspaceIDs = state.topLevelWorkspaceIDs(in: windowID).flatMap { parentID in
            let subspaceIDs = state.subspaceWorkspaceIDs(of: parentID)
            let displayedIDs = displayedSubspaceOrderByParentID[parentID] ?? []
            let validIDs = Set(subspaceIDs)
            var placedIDs = Set<UUID>()
            let orderedIDs = (displayedIDs + subspaceIDs).filter { validIDs.contains($0) && placedIDs.insert($0).inserted }
            return [parentID] + orderedIDs
        }
        let sidebarWorkspaceIDs = Set(workspaceIDs)
        workspaceIDs += window.workspaceIDs.filter { !sidebarWorkspaceIDs.contains($0) }
        var targets: [PanelNavigationTarget] = []
        var seenPanelIDs = Set<UUID>()
        var sessionPanelIDs = Set<UUID>()

        for workspaceID in workspaceIDs {
            guard let workspace = state.workspacesByID[workspaceID] else { continue }
            let layoutTargets = workspace.tabIDs.flatMap { tabID -> [PanelNavigationTarget] in
                guard let tab = workspace.tabsByID[tabID] else { return [] }
                return tab.layoutTree.allSlotInfos.compactMap { slot in
                    guard tab.panels[slot.panelID] != nil else { return nil }
                    return PanelNavigationTarget(
                        windowID: windowID,
                        workspaceID: workspaceID,
                        tabID: tabID,
                        panelID: slot.panelID
                    )
                }
            }
            let statuses = SidebarSessionPresentation.orderedStatuses(
                sessionRegistry?.workspaceStatuses(for: workspaceID) ?? [],
                panelOrder: workspace.sidebarSessionPanelOrder
            )
            for status in statuses {
                guard let target = layoutTargets.first(where: { $0.panelID == status.panelID }),
                      seenPanelIDs.insert(target.panelID).inserted else { continue }
                targets.append(target)
                sessionPanelIDs.insert(target.panelID)
            }
            for target in layoutTargets where seenPanelIDs.insert(target.panelID).inserted {
                targets.append(target)
            }
        }
        return (targets, sessionPanelIDs, workspaceIDs)
    }
}
