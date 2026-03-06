import Foundation

public extension WorkspaceState {
    /// Returns one terminal panel per leaf in deterministic display order.
    /// The order matches the pane tree traversal (first branch before second branch)
    /// for the single panel hosted in each leaf.
    var terminalPanelIDsInDisplayOrder: [UUID] {
        paneTree.allLeafInfos.compactMap { leaf in
            let panelID = leaf.panelID
            guard panels[panelID] != nil else {
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
}
