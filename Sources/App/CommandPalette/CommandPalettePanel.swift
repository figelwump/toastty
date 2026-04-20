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
            // The SwiftUI palette view is pinned to defaultFrame, so use that stable
            // size instead of the panel's transient AppKit frame during first layout.
            panelSize: Self.defaultFrame.size,
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
        let validVisibleFrames = visibleFrames.filter(Self.isUsableFrame(_:))
        let visibleFrame = resolvedVisibleFrame(for: originFrame, visibleFrames: validVisibleFrames)
        let sourceFrame = isUsableFrame(originFrame) ? originFrame : (visibleFrame ?? originFrame)
        var frame = anchoredFrame(panelSize: panelSize, relativeTo: sourceFrame)

        guard let visibleFrame else {
            return roundedOriginFrame(frame)
        }

        frame.origin.x = clampedOrigin(
            frame.origin.x,
            minimum: visibleFrame.minX,
            maximum: visibleFrame.maxX - frame.width
        )
        frame.origin.y = clampedOrigin(
            frame.origin.y,
            minimum: visibleFrame.minY,
            maximum: visibleFrame.maxY - frame.height
        )
        return roundedOriginFrame(frame)
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

    private static func largestVisibleFrame(from visibleFrames: [CGRect]) -> CGRect? {
        visibleFrames.max { lhs, rhs in
            (lhs.width * lhs.height) < (rhs.width * rhs.height)
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

    private static func anchoredFrame(panelSize: CGSize, relativeTo originFrame: CGRect) -> CGRect {
        // Anchor the palette's midpoint one-third down from the top edge of the
        // origin content rect so it opens above the visual center of the window.
        let centerY = originFrame.maxY - (originFrame.height / 3)
        return CGRect(
            x: originFrame.midX - (panelSize.width / 2),
            y: centerY - (panelSize.height / 2),
            width: panelSize.width,
            height: panelSize.height
        )
    }

    private static func roundedOriginFrame(_ frame: CGRect) -> CGRect {
        CGRect(
            x: frame.origin.x.rounded(),
            y: frame.origin.y.rounded(),
            width: frame.width,
            height: frame.height
        )
    }

    private static func clampedOrigin(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        minimum <= maximum ? min(max(value, minimum), maximum) : minimum
    }

    private static func isUsableFrame(_ frame: CGRect) -> Bool {
        frame.isNull == false && frame.width > 0 && frame.height > 0
    }

    private static func resolvedVisibleFrame(for frame: CGRect, visibleFrames: [CGRect]) -> CGRect? {
        guard visibleFrames.isEmpty == false else {
            return nil
        }

        guard isUsableFrame(frame) else {
            return largestVisibleFrame(from: visibleFrames)
        }

        return bestVisibleFrame(for: frame, visibleFrames: visibleFrames)
    }
}
