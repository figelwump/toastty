import Foundation

public struct LayoutFrame: Equatable, Sendable {
    public let minX: Double
    public let minY: Double
    public let width: Double
    public let height: Double

    public init(minX: Double, minY: Double, width: Double, height: Double) {
        self.minX = minX
        self.minY = minY
        self.width = width
        self.height = height
    }

    public var maxX: Double { minX + width }
    public var maxY: Double { minY + height }
    public var midX: Double { minX + (width * 0.5) }
    public var midY: Double { minY + (height * 0.5) }
}

public struct LayoutSlotPlacement: Equatable, Identifiable, Sendable {
    public let slotID: UUID
    public let panelID: UUID
    public let frame: LayoutFrame

    public init(slotID: UUID, panelID: UUID, frame: LayoutFrame) {
        self.slotID = slotID
        self.panelID = panelID
        self.frame = frame
    }

    public var id: UUID { slotID }
}

public struct LayoutDividerPlacement: Equatable, Identifiable, Sendable {
    public let nodeID: UUID
    public let orientation: SplitOrientation
    public let frame: LayoutFrame

    public init(nodeID: UUID, orientation: SplitOrientation, frame: LayoutFrame) {
        self.nodeID = nodeID
        self.orientation = orientation
        self.frame = frame
    }

    public var id: UUID { nodeID }
}

public struct LayoutProjection: Equatable, Sendable {
    public let slots: [LayoutSlotPlacement]
    public let dividers: [LayoutDividerPlacement]

    public init(slots: [LayoutSlotPlacement], dividers: [LayoutDividerPlacement]) {
        self.slots = slots
        self.dividers = dividers
    }
}

public extension LayoutNode {
    func projectLayout(
        in frame: LayoutFrame,
        dividerThickness: Double = 1,
        minimumSplitRatio: Double = 0.1,
        maximumSplitRatio: Double = 0.9
    ) -> LayoutProjection {
        var slots: [LayoutSlotPlacement] = []
        var dividers: [LayoutDividerPlacement] = []

        func walk(_ node: LayoutNode, frame: LayoutFrame) {
            switch node {
            case .slot(let slotID, let panelID):
                slots.append(
                    LayoutSlotPlacement(
                        slotID: slotID,
                        panelID: panelID,
                        frame: frame
                    )
                )

            case .split(let nodeID, let orientation, let ratio, let first, let second):
                let clampedRatio = min(max(ratio, minimumSplitRatio), maximumSplitRatio)

                switch orientation {
                case .horizontal:
                    let adjustedWidth = max(frame.width - dividerThickness, 0)
                    let firstWidth = adjustedWidth * clampedRatio
                    let secondWidth = max(adjustedWidth - firstWidth, 0)
                    let firstFrame = LayoutFrame(
                        minX: frame.minX,
                        minY: frame.minY,
                        width: firstWidth,
                        height: frame.height
                    )
                    let dividerFrame = LayoutFrame(
                        minX: firstFrame.maxX,
                        minY: frame.minY,
                        width: dividerThickness,
                        height: frame.height
                    )
                    let secondFrame = LayoutFrame(
                        minX: dividerFrame.maxX,
                        minY: frame.minY,
                        width: secondWidth,
                        height: frame.height
                    )
                    walk(first, frame: firstFrame)
                    walk(second, frame: secondFrame)
                    dividers.append(
                        LayoutDividerPlacement(
                            nodeID: nodeID,
                            orientation: orientation,
                            frame: dividerFrame
                        )
                    )

                case .vertical:
                    let adjustedHeight = max(frame.height - dividerThickness, 0)
                    let firstHeight = adjustedHeight * clampedRatio
                    let secondHeight = max(adjustedHeight - firstHeight, 0)
                    let firstFrame = LayoutFrame(
                        minX: frame.minX,
                        minY: frame.minY,
                        width: frame.width,
                        height: firstHeight
                    )
                    let dividerFrame = LayoutFrame(
                        minX: frame.minX,
                        minY: firstFrame.maxY,
                        width: frame.width,
                        height: dividerThickness
                    )
                    let secondFrame = LayoutFrame(
                        minX: frame.minX,
                        minY: dividerFrame.maxY,
                        width: frame.width,
                        height: secondHeight
                    )
                    walk(first, frame: firstFrame)
                    walk(second, frame: secondFrame)
                    dividers.append(
                        LayoutDividerPlacement(
                            nodeID: nodeID,
                            orientation: orientation,
                            frame: dividerFrame
                        )
                    )
                }
            }
        }

        walk(self, frame: frame)
        return LayoutProjection(slots: slots, dividers: dividers)
    }
}
