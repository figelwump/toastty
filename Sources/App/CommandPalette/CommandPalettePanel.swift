import AppKit

@MainActor
final class CommandPalettePanel: NSPanel {
    static let defaultFrame = NSRect(x: 0, y: 0, width: 580, height: 252)
    static let cornerRadius: CGFloat = 12

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: Self.defaultFrame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )

        isFloatingPanel = true
        level = .floating
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.moveToActiveSpace, .transient]
        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    }

    func position(relativeTo originWindow: NSWindow) {
        let targetRect = resolvedTargetRect(for: originWindow)
        let frame = Self.positionedFrame(
            panelSize: self.frame.size,
            relativeTo: targetRect,
            visibleFrames: NSScreen.screens.map(\.visibleFrame)
        )
        setFrame(frame, display: false)
    }

    static func positionedFrame(
        panelSize: CGSize = defaultFrame.size,
        relativeTo originFrame: CGRect,
        visibleFrames: [CGRect]
    ) -> CGRect {
        var frame = CGRect(
            x: originFrame.midX - (panelSize.width / 2),
            y: originFrame.midY - (panelSize.height / 2),
            width: panelSize.width,
            height: panelSize.height
        )

        let validVisibleFrames = visibleFrames.filter { $0.isEmpty == false && $0.isNull == false }
        guard let visibleFrame = bestVisibleFrame(for: originFrame, visibleFrames: validVisibleFrames) else {
            return frame.integral
        }

        frame.origin.x = min(
            max(frame.origin.x, visibleFrame.minX),
            visibleFrame.maxX - frame.width
        )
        frame.origin.y = min(
            max(frame.origin.y, visibleFrame.minY),
            visibleFrame.maxY - frame.height
        )
        return frame.integral
    }

    private func resolvedTargetRect(for originWindow: NSWindow) -> CGRect {
        guard let contentView = originWindow.contentView else {
            return originWindow.frame
        }

        let contentRectInWindow = contentView.convert(contentView.bounds, to: nil)
        return originWindow.convertToScreen(contentRectInWindow)
    }

    private static func bestVisibleFrame(for frame: CGRect, visibleFrames: [CGRect]) -> CGRect? {
        let frameCenter = CGPoint(x: frame.midX, y: frame.midY)
        return visibleFrames.max { lhs, rhs in
            let lhsIntersectionArea = intersectionArea(between: frame, and: lhs)
            let rhsIntersectionArea = intersectionArea(between: frame, and: rhs)
            if abs(lhsIntersectionArea - rhsIntersectionArea) >= 0.5 {
                return lhsIntersectionArea < rhsIntersectionArea
            }

            let lhsDistance = squaredDistance(from: frameCenter, to: lhs)
            let rhsDistance = squaredDistance(from: frameCenter, to: rhs)
            if abs(lhsDistance - rhsDistance) >= 0.5 {
                return lhsDistance > rhsDistance
            }

            let lhsArea = lhs.width * lhs.height
            let rhsArea = rhs.width * rhs.height
            return lhsArea < rhsArea
        }
    }

    private static func intersectionArea(between lhs: CGRect, and rhs: CGRect) -> Double {
        let intersection = lhs.intersection(rhs)
        guard intersection.isNull == false, intersection.isEmpty == false else {
            return 0
        }
        return intersection.width * intersection.height
    }

    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> Double {
        let closestX = min(max(point.x, rect.minX), rect.maxX)
        let closestY = min(max(point.y, rect.minY), rect.maxY)
        let deltaX = point.x - closestX
        let deltaY = point.y - closestY
        return deltaX * deltaX + deltaY * deltaY
    }
}
