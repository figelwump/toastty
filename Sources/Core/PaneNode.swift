import Foundation

public enum SplitOrientation: String, Codable, Equatable, Sendable {
    case horizontal
    case vertical
}

public struct PaneLeafInfo: Equatable, Sendable {
    public let paneID: UUID
    public let tabPanelIDs: [UUID]
    public let selectedIndex: Int

    public init(paneID: UUID, tabPanelIDs: [UUID], selectedIndex: Int) {
        self.paneID = paneID
        self.tabPanelIDs = tabPanelIDs
        self.selectedIndex = selectedIndex
    }
}

public struct PaneSplitInfo: Equatable, Sendable {
    public let nodeID: UUID
    public let orientation: SplitOrientation
    public let ratio: Double

    public init(nodeID: UUID, orientation: SplitOrientation, ratio: Double) {
        self.nodeID = nodeID
        self.orientation = orientation
        self.ratio = ratio
    }
}

public indirect enum PaneNode: Equatable, Sendable {
    case leaf(paneID: UUID, tabPanelIDs: [UUID], selectedIndex: Int)
    case split(nodeID: UUID, orientation: SplitOrientation, ratio: Double, first: PaneNode, second: PaneNode)
}

extension PaneNode: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case paneID
        case tabPanelIDs
        case selectedIndex
        case nodeID
        case orientation
        case ratio
        case first
        case second
    }

    private enum NodeType: String, Codable {
        case leaf
        case split
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(NodeType.self, forKey: .type)

        switch type {
        case .leaf:
            self = .leaf(
                paneID: try container.decode(UUID.self, forKey: .paneID),
                tabPanelIDs: try container.decode([UUID].self, forKey: .tabPanelIDs),
                selectedIndex: try container.decode(Int.self, forKey: .selectedIndex)
            )
        case .split:
            self = .split(
                nodeID: try container.decode(UUID.self, forKey: .nodeID),
                orientation: try container.decode(SplitOrientation.self, forKey: .orientation),
                ratio: try container.decode(Double.self, forKey: .ratio),
                first: try container.decode(PaneNode.self, forKey: .first),
                second: try container.decode(PaneNode.self, forKey: .second)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .leaf(let paneID, let tabPanelIDs, let selectedIndex):
            try container.encode(NodeType.leaf, forKey: .type)
            try container.encode(paneID, forKey: .paneID)
            try container.encode(tabPanelIDs, forKey: .tabPanelIDs)
            try container.encode(selectedIndex, forKey: .selectedIndex)
        case .split(let nodeID, let orientation, let ratio, let first, let second):
            try container.encode(NodeType.split, forKey: .type)
            try container.encode(nodeID, forKey: .nodeID)
            try container.encode(orientation, forKey: .orientation)
            try container.encode(ratio, forKey: .ratio)
            try container.encode(first, forKey: .first)
            try container.encode(second, forKey: .second)
        }
    }
}

public extension PaneNode {
    var allLeafInfos: [PaneLeafInfo] {
        switch self {
        case .leaf(let paneID, let tabPanelIDs, let selectedIndex):
            return [PaneLeafInfo(paneID: paneID, tabPanelIDs: tabPanelIDs, selectedIndex: selectedIndex)]
        case .split(_, _, _, let first, let second):
            return first.allLeafInfos + second.allLeafInfos
        }
    }

    var allNodeIDs: [UUID] {
        switch self {
        case .leaf(let paneID, _, _):
            return [paneID]
        case .split(let nodeID, _, _, let first, let second):
            return [nodeID] + first.allNodeIDs + second.allNodeIDs
        }
    }

    var allSplitInfos: [PaneSplitInfo] {
        switch self {
        case .leaf:
            return []
        case .split(let nodeID, let orientation, let ratio, let first, let second):
            return [PaneSplitInfo(nodeID: nodeID, orientation: orientation, ratio: ratio)] + first.allSplitInfos + second.allSplitInfos
        }
    }

    func leafContaining(panelID: UUID) -> PaneLeafInfo? {
        switch self {
        case .leaf(let paneID, let tabPanelIDs, let selectedIndex):
            guard tabPanelIDs.contains(panelID) else { return nil }
            return PaneLeafInfo(paneID: paneID, tabPanelIDs: tabPanelIDs, selectedIndex: selectedIndex)
        case .split(_, _, _, let first, let second):
            return first.leafContaining(panelID: panelID) ?? second.leafContaining(panelID: panelID)
        }
    }

    mutating func replaceLeaf(paneID: UUID, with replacement: PaneNode) -> Bool {
        switch self {
        case .leaf(let currentPaneID, _, _):
            guard currentPaneID == paneID else { return false }
            self = replacement
            return true
        case .split(let nodeID, let orientation, let ratio, let first, let second):
            var updatedFirst = first
            if updatedFirst.replaceLeaf(paneID: paneID, with: replacement) {
                self = .split(nodeID: nodeID, orientation: orientation, ratio: ratio, first: updatedFirst, second: second)
                return true
            }

            var updatedSecond = second
            if updatedSecond.replaceLeaf(paneID: paneID, with: replacement) {
                self = .split(nodeID: nodeID, orientation: orientation, ratio: ratio, first: first, second: updatedSecond)
                return true
            }

            return false
        }
    }

    mutating func appendPanel(_ panelID: UUID, toPane paneID: UUID, select: Bool) -> Bool {
        insertPanel(panelID, toPane: paneID, at: nil, select: select)
    }

    mutating func insertPanel(_ panelID: UUID, toPane paneID: UUID, at index: Int?, select: Bool) -> Bool {
        switch self {
        case .leaf(let currentPaneID, let tabPanelIDs, let selectedIndex):
            guard currentPaneID == paneID else { return false }
            var tabs = tabPanelIDs
            let insertionIndex = clampedInsertionIndex(index, count: tabs.count)
            tabs.insert(panelID, at: insertionIndex)
            let nextSelectedIndex: Int
            if select {
                nextSelectedIndex = insertionIndex
            } else if insertionIndex <= selectedIndex {
                nextSelectedIndex = selectedIndex + 1
            } else {
                nextSelectedIndex = selectedIndex
            }
            self = .leaf(paneID: currentPaneID, tabPanelIDs: tabs, selectedIndex: nextSelectedIndex)
            return true
        case .split(let nodeID, let orientation, let ratio, let first, let second):
            var updatedFirst = first
            if updatedFirst.insertPanel(panelID, toPane: paneID, at: index, select: select) {
                self = .split(nodeID: nodeID, orientation: orientation, ratio: ratio, first: updatedFirst, second: second)
                return true
            }

            var updatedSecond = second
            if updatedSecond.insertPanel(panelID, toPane: paneID, at: index, select: select) {
                self = .split(nodeID: nodeID, orientation: orientation, ratio: ratio, first: first, second: updatedSecond)
                return true
            }

            return false
        }
    }

    mutating func reorderPanel(_ panelID: UUID, inPane paneID: UUID, toIndex: Int) -> Bool {
        switch self {
        case .leaf(let currentPaneID, let tabPanelIDs, let selectedIndex):
            guard currentPaneID == paneID else { return false }
            guard let currentIndex = tabPanelIDs.firstIndex(of: panelID) else { return false }

            var tabs = tabPanelIDs
            tabs.remove(at: currentIndex)
            let insertionIndex = clampedInsertionIndex(toIndex, count: tabs.count)
            tabs.insert(panelID, at: insertionIndex)

            let focusedIndex: Int
            if selectedIndex == currentIndex {
                focusedIndex = insertionIndex
            } else if selectedIndex > currentIndex && selectedIndex <= insertionIndex {
                focusedIndex = selectedIndex - 1
            } else if selectedIndex < currentIndex && selectedIndex >= insertionIndex {
                focusedIndex = selectedIndex + 1
            } else {
                focusedIndex = selectedIndex
            }

            self = .leaf(paneID: currentPaneID, tabPanelIDs: tabs, selectedIndex: focusedIndex)
            return true

        case .split(let nodeID, let orientation, let ratio, let first, let second):
            var updatedFirst = first
            if updatedFirst.reorderPanel(panelID, inPane: paneID, toIndex: toIndex) {
                self = .split(nodeID: nodeID, orientation: orientation, ratio: ratio, first: updatedFirst, second: second)
                return true
            }

            var updatedSecond = second
            if updatedSecond.reorderPanel(panelID, inPane: paneID, toIndex: toIndex) {
                self = .split(nodeID: nodeID, orientation: orientation, ratio: ratio, first: first, second: updatedSecond)
                return true
            }

            return false
        }
    }

    func removingPanel(_ panelID: UUID) -> (node: PaneNode?, removed: Bool) {
        switch self {
        case .leaf(let paneID, let tabPanelIDs, let selectedIndex):
            guard let index = tabPanelIDs.firstIndex(of: panelID) else {
                return (self, false)
            }

            var tabs = tabPanelIDs
            tabs.remove(at: index)

            guard tabs.isEmpty == false else {
                return (nil, true)
            }

            let nextSelectedIndex: Int
            if selectedIndex >= tabs.count {
                nextSelectedIndex = tabs.count - 1
            } else if index < selectedIndex {
                nextSelectedIndex = selectedIndex - 1
            } else {
                nextSelectedIndex = selectedIndex
            }
            return (.leaf(paneID: paneID, tabPanelIDs: tabs, selectedIndex: nextSelectedIndex), true)

        case .split(let nodeID, let orientation, let ratio, let first, let second):
            let firstResult = first.removingPanel(panelID)
            if firstResult.removed {
                guard let updatedFirst = firstResult.node else {
                    return (second, true)
                }
                return (.split(nodeID: nodeID, orientation: orientation, ratio: ratio, first: updatedFirst, second: second), true)
            }

            let secondResult = second.removingPanel(panelID)
            if secondResult.removed {
                guard let updatedSecond = secondResult.node else {
                    return (first, true)
                }
                return (.split(nodeID: nodeID, orientation: orientation, ratio: ratio, first: first, second: updatedSecond), true)
            }

            return (self, false)
        }
    }

    private func clampedInsertionIndex(_ requestedIndex: Int?, count: Int) -> Int {
        guard let requestedIndex else { return count }
        if requestedIndex < 0 { return 0 }
        if requestedIndex > count { return count }
        return requestedIndex
    }
}
