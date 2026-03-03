import Foundation

public extension WorkspaceState {
    /// Returns one terminal panel per leaf in deterministic display order.
    /// The order matches the pane tree traversal (first branch before second branch)
    /// and resolves the selected tab in each leaf.
    var terminalPanelIDsInDisplayOrder: [UUID] {
        paneTree.allLeafInfos.compactMap { leaf in
            guard let panelID = selectedPanelID(in: leaf) else {
                return nil
            }
            guard case .terminal = panels[panelID] else {
                return nil
            }
            return panelID
        }
    }

    func terminalPanelID(forDisplayShortcutNumber shortcutNumber: Int) -> UUID? {
        guard shortcutNumber > 0 else { return nil }
        let panelIDs = terminalPanelIDsInDisplayOrder
        let index = shortcutNumber - 1
        guard panelIDs.indices.contains(index) else {
            return nil
        }
        return panelIDs[index]
    }

    func terminalShortcutNumbersByPanelID(limit: Int) -> [UUID: Int] {
        guard limit > 0 else { return [:] }
        return Dictionary(
            uniqueKeysWithValues: terminalPanelIDsInDisplayOrder
                .prefix(limit)
                .enumerated()
                .map { offset, panelID in
                    (panelID, offset + 1)
                }
        )
    }

    private func selectedPanelID(in leaf: PaneLeafInfo) -> UUID? {
        if leaf.tabPanelIDs.indices.contains(leaf.selectedIndex) {
            let selectedPanelID = leaf.tabPanelIDs[leaf.selectedIndex]
            if panels[selectedPanelID] != nil {
                return selectedPanelID
            }
        }
        return leaf.tabPanelIDs.first(where: { panels[$0] != nil })
    }
}
