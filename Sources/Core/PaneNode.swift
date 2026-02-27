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
        case .split(let nodeID, let orientation, let ratio, var first, var second):
            if first.replaceLeaf(paneID: paneID, with: replacement) {
                self = .split(nodeID: nodeID, orientation: orientation, ratio: ratio, first: first, second: second)
                return true
            }

            if second.replaceLeaf(paneID: paneID, with: replacement) {
                self = .split(nodeID: nodeID, orientation: orientation, ratio: ratio, first: first, second: second)
                return true
            }

            return false
        }
    }

    mutating func appendPanel(_ panelID: UUID, toPane paneID: UUID, select: Bool) -> Bool {
        switch self {
        case .leaf(let currentPaneID, let tabPanelIDs, let selectedIndex):
            guard currentPaneID == paneID else { return false }
            var tabs = tabPanelIDs
            tabs.append(panelID)
            let nextSelectedIndex = select ? tabs.count - 1 : selectedIndex
            self = .leaf(paneID: currentPaneID, tabPanelIDs: tabs, selectedIndex: nextSelectedIndex)
            return true
        case .split(let nodeID, let orientation, let ratio, var first, var second):
            if first.appendPanel(panelID, toPane: paneID, select: select) {
                self = .split(nodeID: nodeID, orientation: orientation, ratio: ratio, first: first, second: second)
                return true
            }

            if second.appendPanel(panelID, toPane: paneID, select: select) {
                self = .split(nodeID: nodeID, orientation: orientation, ratio: ratio, first: first, second: second)
                return true
            }

            return false
        }
    }
}
