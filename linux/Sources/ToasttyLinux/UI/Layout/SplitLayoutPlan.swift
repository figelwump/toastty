import CoreState
import Foundation

/// Widget-level plan for one workspace tab's split layout: which panel goes
/// in which `GtkPaned` child, with which orientation and ratio. Derived from
/// `WorkspaceSplitTree.renderedLayout`, so zoom (focused panel mode) renders
/// only the zoomed subtree.
public indirect enum SplitLayoutNode: Equatable, Sendable {
    case panel(panelID: UUID, slotID: UUID)
    case split(nodeID: UUID, axis: SplitAxis, ratio: Double, first: SplitLayoutNode, second: SplitLayoutNode)

    /// Shape without ratios: when two plans share it, the renderer keeps the
    /// existing widgets and only moves dividers.
    public var shape: SplitLayoutShape {
        switch self {
        case .panel(let panelID, let slotID):
            return .panel(panelID: panelID, slotID: slotID)
        case .split(let nodeID, let axis, _, let first, let second):
            return .split(nodeID: nodeID, axis: axis, first: first.shape, second: second.shape)
        }
    }

    public var panelIDs: [UUID] {
        switch self {
        case .panel(let panelID, _): return [panelID]
        case .split(_, _, _, let first, let second): return first.panelIDs + second.panelIDs
        }
    }

    public var ratios: [UUID: Double] {
        switch self {
        case .panel: return [:]
        case .split(let nodeID, _, let ratio, let first, let second):
            return first.ratios.merging(second.ratios) { lhs, _ in lhs }.merging([nodeID: ratio]) { lhs, _ in lhs }
        }
    }

    public var depth: Int {
        switch self {
        case .panel: return 0
        case .split(_, _, _, let first, let second): return 1 + max(first.depth, second.depth)
        }
    }
}

public indirect enum SplitLayoutShape: Equatable, Hashable, Sendable {
    case panel(panelID: UUID, slotID: UUID)
    case split(nodeID: UUID, axis: SplitAxis, first: SplitLayoutShape, second: SplitLayoutShape)
}

/// `GtkOrientation` for a split. Toastty's `.horizontal` split puts panels
/// side by side (split right), which is `GTK_ORIENTATION_HORIZONTAL`.
public enum SplitAxis: String, Equatable, Hashable, Sendable {
    case sideBySide
    case stacked

    public init(_ orientation: SplitOrientation) {
        self = orientation == .horizontal ? .sideBySide : .stacked
    }
}

public struct SplitLayoutPlan: Equatable, Sendable {
    public let root: SplitLayoutNode
    public let zoomedNodeID: UUID?
    public let focusedPanelID: UUID?
    /// Panels in the tab that the plan hides (zoomed out of view).
    public let hiddenPanelIDs: [UUID]

    public var isZoomed: Bool { zoomedNodeID != nil }

    public init(root: SplitLayoutNode, zoomedNodeID: UUID?, focusedPanelID: UUID?, hiddenPanelIDs: [UUID]) {
        self.root = root
        self.zoomedNodeID = zoomedNodeID
        self.focusedPanelID = focusedPanelID
        self.hiddenPanelIDs = hiddenPanelIDs
    }

    public static func make(workspaceID: UUID, tab: WorkspaceTabState) -> SplitLayoutPlan {
        let tree = WorkspaceSplitTree(root: tab.layoutTree)
        let focusedPanelID = tab.resolvedFocusedPanelID
        let rendered = tree.renderedLayout(
            workspaceID: workspaceID,
            focusedPanelModeActive: tab.focusedPanelModeActive,
            focusedPanelID: focusedPanelID,
            focusModeRootNodeID: tab.focusModeRootNodeID
        )
        let root = node(from: rendered.layoutTree)
        let visible = Set(root.panelIDs)
        let hidden = tab.layoutTree.allSlotInfos.map(\.panelID).filter { visible.contains($0) == false }
        return SplitLayoutPlan(
            root: root,
            zoomedNodeID: rendered.identity.zoomedNodeID,
            focusedPanelID: focusedPanelID,
            hiddenPanelIDs: hidden
        )
    }

    static func node(from layout: LayoutNode) -> SplitLayoutNode {
        switch layout {
        case .slot(let slotID, let panelID):
            return .panel(panelID: panelID, slotID: slotID)
        case .split(let nodeID, let orientation, let ratio, let first, let second):
            return .split(
                nodeID: nodeID,
                axis: SplitAxis(orientation),
                ratio: ratio,
                first: node(from: first),
                second: node(from: second)
            )
        }
    }

    // MARK: Ratio <-> GtkPaned position

    /// Divider position for `ratio` in a paned whose `max-position` is
    /// `maxPosition` (the start child's largest size).
    public static func position(forRatio ratio: Double, maxPosition: Int32) -> Int32 {
        guard maxPosition > 0, ratio.isFinite else { return 0 }
        let clamped = LayoutNode.clampedSplitRatio(ratio)
        return Int32((Double(maxPosition) * clamped).rounded())
    }

    public static func ratio(forPosition position: Int32, maxPosition: Int32) -> Double? {
        guard maxPosition > 0 else { return nil }
        return LayoutNode.clampedSplitRatio(Double(position) / Double(maxPosition))
    }

    /// Whether a user-dragged ratio differs enough from state to dispatch.
    /// One pixel of rounding must never echo back as an action.
    public static func isMeaningfulDrag(from stateRatio: Double, to draggedRatio: Double, maxPosition: Int32) -> Bool {
        let onePixel = maxPosition > 0 ? 1.0 / Double(maxPosition) : 0.01
        return abs(stateRatio - draggedRatio) > max(onePixel * 1.5, LayoutNode.splitRatioChangeEpsilon)
    }
}
