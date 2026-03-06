import Foundation

public enum SplitOrientation: String, Codable, Equatable, Sendable {
    case horizontal
    case vertical
}

public struct PaneLeafInfo: Equatable, Sendable {
    public let paneID: UUID
    public let panelID: UUID

    public init(paneID: UUID, panelID: UUID) {
        self.paneID = paneID
        self.panelID = panelID
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
    case leaf(paneID: UUID, panelID: UUID)
    case split(nodeID: UUID, orientation: SplitOrientation, ratio: Double, first: PaneNode, second: PaneNode)
}

extension PaneNode: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case paneID
        case panelID
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
                panelID: try container.decode(UUID.self, forKey: .panelID)
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
        case .leaf(let paneID, let panelID):
            try container.encode(NodeType.leaf, forKey: .type)
            try container.encode(paneID, forKey: .paneID)
            try container.encode(panelID, forKey: .panelID)
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
        case .leaf(let paneID, let panelID):
            return [PaneLeafInfo(paneID: paneID, panelID: panelID)]
        case .split(_, _, _, let first, let second):
            return first.allLeafInfos + second.allLeafInfos
        }
    }

    var allNodeIDs: [UUID] {
        switch self {
        case .leaf(let paneID, _):
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
        case .leaf(let paneID, let currentPanelID):
            guard currentPanelID == panelID else { return nil }
            return PaneLeafInfo(paneID: paneID, panelID: currentPanelID)
        case .split(_, _, _, let first, let second):
            return first.leafContaining(panelID: panelID) ?? second.leafContaining(panelID: panelID)
        }
    }

    func leafNode(paneID: UUID) -> PaneNode? {
        switch self {
        case .leaf(let currentPaneID, _):
            guard currentPaneID == paneID else { return nil }
            return self
        case .split(_, _, _, let first, let second):
            return first.leafNode(paneID: paneID) ?? second.leafNode(paneID: paneID)
        }
    }

    func rightColumnPaneID() -> UUID? {
        switch self {
        case .leaf(let paneID, _):
            return paneID
        case .split(_, let orientation, _, let first, let second):
            if orientation == .horizontal {
                return second.rightColumnPaneID()
            }
            return second.rightColumnPaneID() ?? first.rightColumnPaneID()
        }
    }

    mutating func replaceLeaf(paneID: UUID, with replacement: PaneNode) -> Bool {
        switch self {
        case .leaf(let currentPaneID, _):
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

    func removingPanel(_ panelID: UUID) -> (node: PaneNode?, removed: Bool) {
        switch self {
        case .leaf(_, let currentPanelID):
            guard currentPanelID == panelID else {
                return (self, false)
            }
            return (nil, true)

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
}
