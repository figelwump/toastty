import Foundation

public struct WorkspaceRenderIdentity: Hashable, Sendable {
    public let workspaceID: UUID
    public let zoomedSlotID: UUID?

    public init(workspaceID: UUID, zoomedSlotID: UUID?) {
        self.workspaceID = workspaceID
        self.zoomedSlotID = zoomedSlotID
    }
}

public struct WorkspaceRenderedLayout: Equatable, Sendable {
    public let layoutTree: LayoutNode
    public let identity: WorkspaceRenderIdentity

    public init(layoutTree: LayoutNode, identity: WorkspaceRenderIdentity) {
        self.layoutTree = layoutTree
        self.identity = identity
    }

    public func projectLayout(
        in frame: LayoutFrame,
        dividerThickness: Double = 1,
        minimumSplitRatio: Double = 0.1,
        maximumSplitRatio: Double = 0.9
    ) -> LayoutProjection {
        layoutTree.projectLayout(
            in: frame,
            dividerThickness: dividerThickness,
            minimumSplitRatio: minimumSplitRatio,
            maximumSplitRatio: maximumSplitRatio
        )
    }
}

public struct WorkspaceSplitTree: Equatable, Sendable {
    public struct FocusedPanelResolution: Equatable, Sendable {
        public let panelID: UUID
        public let slot: SlotInfo

        public init(panelID: UUID, slot: SlotInfo) {
            self.panelID = panelID
            self.slot = slot
        }
    }

    public var root: LayoutNode

    public init(root: LayoutNode) {
        self.root = root
    }

    public func resolveFocusedPanel(
        preferredFocusedPanelID: UUID?,
        livePanelIDs: Set<UUID>
    ) -> FocusedPanelResolution? {
        if let preferredFocusedPanelID,
           livePanelIDs.contains(preferredFocusedPanelID),
           let focusedSlot = root.slotContaining(panelID: preferredFocusedPanelID) {
            return FocusedPanelResolution(panelID: preferredFocusedPanelID, slot: focusedSlot)
        }

        for slot in root.allSlotInfos where livePanelIDs.contains(slot.panelID) {
            return FocusedPanelResolution(panelID: slot.panelID, slot: slot)
        }

        return nil
    }

    public func panelID(for slotID: UUID, livePanelIDs: Set<UUID>) -> UUID? {
        guard let slotNode = root.slotNode(slotID: slotID),
              case .slot(_, let panelID) = slotNode,
              livePanelIDs.contains(panelID) else {
            return nil
        }
        return panelID
    }

    public func focusTarget(from sourceSlotID: UUID, direction: SlotFocusDirection) -> UUID? {
        let leaves = root.allSlotInfos
        guard let sourceLeafIndex = leaves.firstIndex(where: { $0.slotID == sourceSlotID }) else {
            return nil
        }

        switch direction {
        case .previous:
            guard leaves.count > 1 else { return nil }
            let previousIndex = (sourceLeafIndex - 1 + leaves.count) % leaves.count
            return leaves[previousIndex].slotID

        case .next:
            guard leaves.count > 1 else { return nil }
            let nextIndex = (sourceLeafIndex + 1) % leaves.count
            return leaves[nextIndex].slotID

        case .up, .down, .left, .right:
            let frames = slotFrames()
            guard let sourceFrame = frames.first(where: { $0.slotID == sourceSlotID }) else {
                return nil
            }
            return closestSlotID(to: sourceFrame, direction: direction, frames: frames)
        }
    }

    public func splitting(
        slotID: UUID,
        direction: SlotSplitDirection,
        newPanelID: UUID,
        newSlotID: UUID
    ) -> WorkspaceSplitTree? {
        guard let sourceLeaf = root.slotNode(slotID: slotID),
              case .slot(_, let sourcePanelID) = sourceLeaf else {
            return nil
        }

        let newLeaf = LayoutNode.slot(slotID: newSlotID, panelID: newPanelID)
        let originalLeaf = LayoutNode.slot(slotID: slotID, panelID: sourcePanelID)

        let orientation: SplitOrientation = switch direction {
        case .left, .right:
            .horizontal
        case .up, .down:
            .vertical
        }

        let firstNode: LayoutNode
        let secondNode: LayoutNode
        switch direction {
        case .right, .down:
            firstNode = originalLeaf
            secondNode = newLeaf
        case .left, .up:
            firstNode = newLeaf
            secondNode = originalLeaf
        }

        let split = LayoutNode.split(
            nodeID: UUID(),
            orientation: orientation,
            ratio: 0.5,
            first: firstNode,
            second: secondNode
        )

        var updatedRoot = root
        guard updatedRoot.replaceSlot(slotID: slotID, with: split) else {
            return nil
        }
        return WorkspaceSplitTree(root: updatedRoot)
    }

    public func resized(
        focusedSlotID: UUID,
        direction: SplitResizeDirection,
        amount: Int
    ) -> WorkspaceSplitTree? {
        let delta = splitResizeDelta(direction: direction, amount: amount)
        let result = resizeNearestMatchingSplit(
            in: root,
            focusedSlotID: focusedSlotID,
            direction: direction,
            delta: delta
        )
        guard result.didResize else {
            return nil
        }
        return WorkspaceSplitTree(root: result.node)
    }

    public func equalized() -> WorkspaceSplitTree? {
        let result = equalizeSplitRatios(in: root)
        guard result.didMutate else {
            return nil
        }
        return WorkspaceSplitTree(root: result.node)
    }

    public func renderedLayout(
        workspaceID: UUID,
        focusedPanelModeActive: Bool,
        focusedPanelID: UUID?
    ) -> WorkspaceRenderedLayout {
        let fullLayout = WorkspaceRenderedLayout(
            layoutTree: root,
            identity: WorkspaceRenderIdentity(workspaceID: workspaceID, zoomedSlotID: nil)
        )
        guard focusedPanelModeActive else {
            return fullLayout
        }
        guard let focusedPanelID else {
            return fullLayout
        }
        guard let focusedSlot = root.slotContaining(panelID: focusedPanelID) else {
            assertionFailure("Focused panel mode requires the focused panel to resolve to a live layout slot.")
            return fullLayout
        }

        // Focused-panel mode intentionally renders the focused slot leaf as the
        // workspace root, mirroring Ghostty's zoomed split rendering.
        return WorkspaceRenderedLayout(
            layoutTree: .slot(slotID: focusedSlot.slotID, panelID: focusedSlot.panelID),
            identity: WorkspaceRenderIdentity(workspaceID: workspaceID, zoomedSlotID: focusedSlot.slotID)
        )
    }
}

private extension WorkspaceSplitTree {
    struct SplitResizeResult {
        let node: LayoutNode
        let containsFocusedSlot: Bool
        let didResize: Bool
    }

    struct SplitEqualizeResult {
        let node: LayoutNode
        let didMutate: Bool
    }

    struct SlotFrame {
        let slotID: UUID
        let minX: Double
        let minY: Double
        let maxX: Double
        let maxY: Double

        var centerX: Double { minX + ((maxX - minX) * 0.5) }
        var centerY: Double { minY + ((maxY - minY) * 0.5) }

        func horizontalOverlap(with other: SlotFrame) -> Double {
            max(0, min(maxX, other.maxX) - max(minX, other.minX))
        }

        func verticalOverlap(with other: SlotFrame) -> Double {
            max(0, min(maxY, other.maxY) - max(minY, other.minY))
        }

        func horizontalGap(to other: SlotFrame) -> Double {
            if horizontalOverlap(with: other) > 0 {
                return 0
            }
            if maxX <= other.minX {
                return other.minX - maxX
            }
            if other.maxX <= minX {
                return minX - other.maxX
            }
            return 0
        }

        func verticalGap(to other: SlotFrame) -> Double {
            if verticalOverlap(with: other) > 0 {
                return 0
            }
            if maxY <= other.minY {
                return other.minY - maxY
            }
            if other.maxY <= minY {
                return minY - other.maxY
            }
            return 0
        }
    }

    struct DirectionalFocusCandidate {
        let frame: SlotFrame
        let primaryDistance: Double
        let perpendicularOverlap: Double
        let perpendicularDistance: Double
        let perpendicularCenterDistance: Double

        var isAligned: Bool { perpendicularOverlap > 0 }
    }

    // Suppresses floating-point noise near clamp bounds; this must stay well below the
    // minimum intentional resize step (0.005) so real resizes always apply.
    static let splitRatioChangeEpsilon: Double = 0.0001

    func slotFrames() -> [SlotFrame] {
        root.projectLayout(
            in: LayoutFrame(minX: 0, minY: 0, width: 1, height: 1),
            dividerThickness: 0
        )
        .slots
        .map { placement in
            let frame = placement.frame
            return SlotFrame(
                slotID: placement.slotID,
                minX: frame.minX,
                minY: frame.minY,
                maxX: frame.maxX,
                maxY: frame.maxY
            )
        }
    }

    func closestSlotID(
        to source: SlotFrame,
        direction: SlotFocusDirection,
        frames: [SlotFrame]
    ) -> UUID? {
        let directionalCandidates: [DirectionalFocusCandidate] = frames.compactMap { candidate in
            guard candidate.slotID != source.slotID else {
                return nil
            }

            switch direction {
            case .left:
                guard candidate.maxX <= source.minX else { return nil }
                let overlap = source.verticalOverlap(with: candidate)
                return DirectionalFocusCandidate(
                    frame: candidate,
                    primaryDistance: source.minX - candidate.maxX,
                    perpendicularOverlap: overlap,
                    perpendicularDistance: source.verticalGap(to: candidate),
                    perpendicularCenterDistance: abs(candidate.centerY - source.centerY)
                )

            case .right:
                guard candidate.minX >= source.maxX else { return nil }
                let overlap = source.verticalOverlap(with: candidate)
                return DirectionalFocusCandidate(
                    frame: candidate,
                    primaryDistance: candidate.minX - source.maxX,
                    perpendicularOverlap: overlap,
                    perpendicularDistance: source.verticalGap(to: candidate),
                    perpendicularCenterDistance: abs(candidate.centerY - source.centerY)
                )

            case .up:
                guard candidate.maxY <= source.minY else { return nil }
                let overlap = source.horizontalOverlap(with: candidate)
                return DirectionalFocusCandidate(
                    frame: candidate,
                    primaryDistance: source.minY - candidate.maxY,
                    perpendicularOverlap: overlap,
                    perpendicularDistance: source.horizontalGap(to: candidate),
                    perpendicularCenterDistance: abs(candidate.centerX - source.centerX)
                )

            case .down:
                guard candidate.minY >= source.maxY else { return nil }
                let overlap = source.horizontalOverlap(with: candidate)
                return DirectionalFocusCandidate(
                    frame: candidate,
                    primaryDistance: candidate.minY - source.maxY,
                    perpendicularOverlap: overlap,
                    perpendicularDistance: source.horizontalGap(to: candidate),
                    perpendicularCenterDistance: abs(candidate.centerX - source.centerX)
                )

            case .previous, .next:
                return nil
            }
        }

        let sorted = directionalCandidates.sorted { lhs, rhs in
            if lhs.isAligned != rhs.isAligned {
                return lhs.isAligned && rhs.isAligned == false
            }
            if lhs.primaryDistance != rhs.primaryDistance {
                return lhs.primaryDistance < rhs.primaryDistance
            }
            if lhs.perpendicularOverlap != rhs.perpendicularOverlap {
                return lhs.perpendicularOverlap > rhs.perpendicularOverlap
            }
            if lhs.perpendicularDistance != rhs.perpendicularDistance {
                return lhs.perpendicularDistance < rhs.perpendicularDistance
            }
            if lhs.perpendicularCenterDistance != rhs.perpendicularCenterDistance {
                return lhs.perpendicularCenterDistance < rhs.perpendicularCenterDistance
            }
            return lhs.frame.slotID.uuidString < rhs.frame.slotID.uuidString
        }
        return sorted.first?.frame.slotID
    }

    func splitResizeDelta(direction: SplitResizeDirection, amount: Int) -> Double {
        // Keep headroom for large shortcut-supplied amounts while clamping pathological values.
        let clampedAmount = max(1, min(amount, 60))
        let magnitude = Double(clampedAmount) * 0.005
        switch direction {
        case .left, .up:
            return -magnitude
        case .right, .down:
            return magnitude
        }
    }

    func resizeNearestMatchingSplit(
        in node: LayoutNode,
        focusedSlotID: UUID,
        direction: SplitResizeDirection,
        delta: Double
    ) -> SplitResizeResult {
        switch node {
        case .slot(let slotID, _):
            return SplitResizeResult(node: node, containsFocusedSlot: slotID == focusedSlotID, didResize: false)

        case .split(let nodeID, let orientation, let ratio, let first, let second):
            let firstResult = resizeNearestMatchingSplit(
                in: first,
                focusedSlotID: focusedSlotID,
                direction: direction,
                delta: delta
            )
            if firstResult.containsFocusedSlot {
                if firstResult.didResize {
                    return SplitResizeResult(
                        node: .split(
                            nodeID: nodeID,
                            orientation: orientation,
                            ratio: ratio,
                            first: firstResult.node,
                            second: second
                        ),
                        containsFocusedSlot: true,
                        didResize: true
                    )
                }

                if splitOrientation(contains: direction, orientation: orientation) {
                    let nextRatio = clampedSplitRatio(ratio + delta)
                    if hasMeaningfulSplitRatioChange(from: ratio, to: nextRatio) {
                        return SplitResizeResult(
                            node: .split(
                                nodeID: nodeID,
                                orientation: orientation,
                                ratio: nextRatio,
                                first: firstResult.node,
                                second: second
                            ),
                            containsFocusedSlot: true,
                            didResize: true
                        )
                    }
                }

                return SplitResizeResult(
                    node: .split(
                        nodeID: nodeID,
                        orientation: orientation,
                        ratio: ratio,
                        first: firstResult.node,
                        second: second
                    ),
                    containsFocusedSlot: true,
                    didResize: false
                )
            }

            let secondResult = resizeNearestMatchingSplit(
                in: second,
                focusedSlotID: focusedSlotID,
                direction: direction,
                delta: delta
            )
            if secondResult.containsFocusedSlot {
                if secondResult.didResize {
                    return SplitResizeResult(
                        node: .split(
                            nodeID: nodeID,
                            orientation: orientation,
                            ratio: ratio,
                            first: first,
                            second: secondResult.node
                        ),
                        containsFocusedSlot: true,
                        didResize: true
                    )
                }

                if splitOrientation(contains: direction, orientation: orientation) {
                    let nextRatio = clampedSplitRatio(ratio + delta)
                    if hasMeaningfulSplitRatioChange(from: ratio, to: nextRatio) {
                        return SplitResizeResult(
                            node: .split(
                                nodeID: nodeID,
                                orientation: orientation,
                                ratio: nextRatio,
                                first: first,
                                second: secondResult.node
                            ),
                            containsFocusedSlot: true,
                            didResize: true
                        )
                    }
                }

                return SplitResizeResult(
                    node: .split(
                        nodeID: nodeID,
                        orientation: orientation,
                        ratio: ratio,
                        first: first,
                        second: secondResult.node
                    ),
                    containsFocusedSlot: true,
                    didResize: false
                )
            }

            return SplitResizeResult(node: node, containsFocusedSlot: false, didResize: false)
        }
    }

    func equalizeSplitRatios(in node: LayoutNode) -> SplitEqualizeResult {
        switch node {
        case .slot:
            return SplitEqualizeResult(node: node, didMutate: false)

        case .split(let nodeID, let orientation, let ratio, let first, let second):
            let firstResult = equalizeSplitRatios(in: first)
            let secondResult = equalizeSplitRatios(in: second)
            let firstWeight = equalizeWeight(in: firstResult.node, orientation: orientation)
            let secondWeight = equalizeWeight(in: secondResult.node, orientation: orientation)
            let totalWeight = firstWeight + secondWeight
            let targetRatio = Double(firstWeight) / Double(totalWeight)
            let didMutate = firstResult.didMutate
                || secondResult.didMutate
                || ratio != targetRatio
            guard didMutate else {
                return SplitEqualizeResult(node: node, didMutate: false)
            }

            return SplitEqualizeResult(
                node: .split(
                    nodeID: nodeID,
                    orientation: orientation,
                    ratio: targetRatio,
                    first: firstResult.node,
                    second: secondResult.node
                ),
                didMutate: didMutate
            )
        }
    }

    /// Match Ghostty equalization semantics:
    /// only descendants with the same split orientation contribute recursive weight.
    /// Opposite-orientation subtrees count as a single unit.
    func equalizeWeight(in node: LayoutNode, orientation: SplitOrientation) -> Int {
        switch node {
        case .slot:
            return 1
        case .split(_, let nodeOrientation, _, let first, let second):
            guard nodeOrientation == orientation else { return 1 }
            return equalizeWeight(in: first, orientation: orientation)
                + equalizeWeight(in: second, orientation: orientation)
        }
    }

    func splitOrientation(contains direction: SplitResizeDirection, orientation: SplitOrientation) -> Bool {
        switch (direction, orientation) {
        case (.left, .horizontal), (.right, .horizontal), (.up, .vertical), (.down, .vertical):
            return true
        default:
            return false
        }
    }

    func clampedSplitRatio(_ value: Double) -> Double {
        min(max(value, 0.1), 0.9)
    }

    func hasMeaningfulSplitRatioChange(from oldValue: Double, to newValue: Double) -> Bool {
        abs(newValue - oldValue) > Self.splitRatioChangeEpsilon
    }
}
