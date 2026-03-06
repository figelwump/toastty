import Foundation

public enum SplitOrientation: String, Codable, Equatable, Sendable {
    case horizontal
    case vertical
}

public struct SlotInfo: Equatable, Sendable {
    public let slotID: UUID
    public let panelID: UUID

    public init(slotID: UUID, panelID: UUID) {
        self.slotID = slotID
        self.panelID = panelID
    }
}

public struct LayoutSplitInfo: Equatable, Sendable {
    public let nodeID: UUID
    public let orientation: SplitOrientation
    public let ratio: Double

    public init(nodeID: UUID, orientation: SplitOrientation, ratio: Double) {
        self.nodeID = nodeID
        self.orientation = orientation
        self.ratio = ratio
    }
}

/// Derived render identity for layout topology.
/// This intentionally ignores split ratios and panel content so only topology
/// and stable slot placement force split-subtree remounts.
public indirect enum LayoutStructuralIdentity: Equatable, Hashable, Sendable {
    case slot(slotID: UUID)
    case split(
        orientation: SplitOrientation,
        first: LayoutStructuralIdentity,
        second: LayoutStructuralIdentity
    )
}

public indirect enum LayoutNode: Equatable, Sendable {
    case slot(slotID: UUID, panelID: UUID)
    case split(nodeID: UUID, orientation: SplitOrientation, ratio: Double, first: LayoutNode, second: LayoutNode)
}

extension LayoutNode: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case slotID
        case panelID
        case nodeID
        case orientation
        case ratio
        case first
        case second
    }

    private enum NodeType: String, Codable {
        case slot
        case split
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(NodeType.self, forKey: .type)

        switch type {
        case .slot:
            self = .slot(
                slotID: try container.decode(UUID.self, forKey: .slotID),
                panelID: try container.decode(UUID.self, forKey: .panelID)
            )
        case .split:
            self = .split(
                nodeID: try container.decode(UUID.self, forKey: .nodeID),
                orientation: try container.decode(SplitOrientation.self, forKey: .orientation),
                ratio: try container.decode(Double.self, forKey: .ratio),
                first: try container.decode(LayoutNode.self, forKey: .first),
                second: try container.decode(LayoutNode.self, forKey: .second)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .slot(let slotID, let panelID):
            try container.encode(NodeType.slot, forKey: .type)
            try container.encode(slotID, forKey: .slotID)
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

public extension LayoutNode {
    var structuralIdentity: LayoutStructuralIdentity {
        switch self {
        case .slot(let slotID, _):
            return .slot(slotID: slotID)
        case .split(_, let orientation, _, let first, let second):
            return .split(
                orientation: orientation,
                first: first.structuralIdentity,
                second: second.structuralIdentity
            )
        }
    }

    var allSlotInfos: [SlotInfo] {
        switch self {
        case .slot(let slotID, let panelID):
            return [SlotInfo(slotID: slotID, panelID: panelID)]
        case .split(_, _, _, let first, let second):
            return first.allSlotInfos + second.allSlotInfos
        }
    }

    var allNodeIDs: [UUID] {
        switch self {
        case .slot(let slotID, _):
            return [slotID]
        case .split(let nodeID, _, _, let first, let second):
            return [nodeID] + first.allNodeIDs + second.allNodeIDs
        }
    }

    var allSplitInfos: [LayoutSplitInfo] {
        switch self {
        case .slot:
            return []
        case .split(let nodeID, let orientation, let ratio, let first, let second):
            return [LayoutSplitInfo(nodeID: nodeID, orientation: orientation, ratio: ratio)] + first.allSplitInfos + second.allSplitInfos
        }
    }

    func slotContaining(panelID: UUID) -> SlotInfo? {
        switch self {
        case .slot(let slotID, let currentPanelID):
            guard currentPanelID == panelID else { return nil }
            return SlotInfo(slotID: slotID, panelID: currentPanelID)
        case .split(_, _, _, let first, let second):
            return first.slotContaining(panelID: panelID) ?? second.slotContaining(panelID: panelID)
        }
    }

    func slotNode(slotID: UUID) -> LayoutNode? {
        switch self {
        case .slot(let currentSlotID, _):
            guard currentSlotID == slotID else { return nil }
            return self
        case .split(_, _, _, let first, let second):
            return first.slotNode(slotID: slotID) ?? second.slotNode(slotID: slotID)
        }
    }

    func rightColumnSlotID() -> UUID? {
        switch self {
        case .slot(let slotID, _):
            return slotID
        case .split(_, let orientation, _, let first, let second):
            if orientation == .horizontal {
                return second.rightColumnSlotID()
            }
            return second.rightColumnSlotID() ?? first.rightColumnSlotID()
        }
    }

    mutating func replaceSlot(slotID: UUID, with replacement: LayoutNode) -> Bool {
        switch self {
        case .slot(let currentSlotID, _):
            guard currentSlotID == slotID else { return false }
            self = replacement
            return true
        case .split(let nodeID, let orientation, let ratio, let first, let second):
            var updatedFirst = first
            if updatedFirst.replaceSlot(slotID: slotID, with: replacement) {
                self = .split(nodeID: nodeID, orientation: orientation, ratio: ratio, first: updatedFirst, second: second)
                return true
            }

            var updatedSecond = second
            if updatedSecond.replaceSlot(slotID: slotID, with: replacement) {
                self = .split(nodeID: nodeID, orientation: orientation, ratio: ratio, first: first, second: updatedSecond)
                return true
            }

            return false
        }
    }

    func removingPanel(_ panelID: UUID) -> (node: LayoutNode?, removed: Bool) {
        switch self {
        case .slot(_, let currentPanelID):
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
