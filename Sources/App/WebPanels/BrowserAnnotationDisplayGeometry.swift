import AppKit
import Foundation

/// Shared mark styling so overlay marks and rendered screenshot marks stay
/// visually identical.
enum BrowserAnnotationMarkStyle {
    static let bubbleDiameter: CGFloat = 22
    static let bubbleRingWidth: CGFloat = 2
    static let rectangleLineWidth: CGFloat = 2
    static let rectangleFillAlpha: CGFloat = 0.08
    static let hoverRingExtraRadius: CGFloat = 4
    static let hoverRingAlpha: CGFloat = 0.3
    static let dragThreshold: CGFloat = 4
    static let numberFontSize: CGFloat = 12
    static let shadowBlurRadius: CGFloat = 3
    static let shadowOffset = CGSize(width: 0, height: -1)

    static var markColor: NSColor {
        NSColor(srgbRed: 0.898, green: 0.282, blue: 0.302, alpha: 1)
    }

    static var ringColor: NSColor { .white }
    static var numberTextColor: NSColor { .white }
    static var shadowColor: NSColor { NSColor.black.withAlphaComponent(0.35) }

    static func numberFont(scale: CGFloat = 1) -> NSFont {
        .systemFont(ofSize: numberFontSize * scale, weight: .bold)
    }
}

/// A draft mark positioned in current overlay coordinates (top-left origin).
struct BrowserAnnotationDisplayMark: Equatable {
    enum Shape: Equatable {
        case point(center: CGPoint)
        case rectangle(CGRect)
    }

    var annotationID: UUID
    var sequenceNumber: Int
    var shape: Shape
    /// Click/hover/popover-anchor target for the numbered bubble.
    var bubbleRect: CGRect
}

enum BrowserAnnotationDisplayGeometry {
    /// Projects all draft annotations into current overlay coordinates by
    /// translating each frozen section with the live scroll offset, so marks
    /// track the page content while the user scrolls.
    ///
    /// Section scroll offsets are stored in CSS pixels; `pageZoom` converts
    /// them into view points. Mark positions inside a section use the
    /// viewport size frozen at capture time, so positions are approximate
    /// after a panel resize.
    static func displayMarks(
        sections: [BrowserAnnotationSection],
        currentScrollOffsetPoints: CGPoint,
        pageZoom: CGFloat,
        overlayBounds: CGRect,
        bubbleDiameter: CGFloat = BrowserAnnotationMarkStyle.bubbleDiameter
    ) -> [BrowserAnnotationDisplayMark] {
        guard overlayBounds.width > 0, overlayBounds.height > 0 else {
            return []
        }
        let zoom = max(pageZoom, 0.01)
        var marks: [BrowserAnnotationDisplayMark] = []

        for section in sections {
            let translation = CGPoint(
                x: section.scrollOffset.x * zoom - currentScrollOffsetPoints.x,
                y: section.scrollOffset.y * zoom - currentScrollOffsetPoints.y
            )
            for annotation in section.annotations {
                switch annotation.kind {
                case .point(let normalized):
                    let center = CGPoint(
                        x: normalized.x * section.viewportSize.width + translation.x,
                        y: normalized.y * section.viewportSize.height + translation.y
                    )
                    let bubble = bubbleRect(center: center, diameter: bubbleDiameter)
                    guard overlayBounds.intersects(bubble) else { continue }
                    marks.append(BrowserAnnotationDisplayMark(
                        annotationID: annotation.id,
                        sequenceNumber: annotation.sequenceNumber,
                        shape: .point(center: center),
                        bubbleRect: bubble
                    ))

                case .rectangle(let normalized):
                    let rect = CGRect(
                        x: normalized.minX * section.viewportSize.width + translation.x,
                        y: normalized.minY * section.viewportSize.height + translation.y,
                        width: normalized.width * section.viewportSize.width,
                        height: normalized.height * section.viewportSize.height
                    )
                    let bubble = bubbleRect(center: rect.origin, diameter: bubbleDiameter)
                    guard overlayBounds.intersects(rect.union(bubble)) else { continue }
                    marks.append(BrowserAnnotationDisplayMark(
                        annotationID: annotation.id,
                        sequenceNumber: annotation.sequenceNumber,
                        shape: .rectangle(rect),
                        bubbleRect: bubble
                    ))
                }
            }
        }

        return marks.sorted { $0.sequenceNumber < $1.sequenceNumber }
    }

    static func bubbleRect(
        center: CGPoint,
        diameter: CGFloat = BrowserAnnotationMarkStyle.bubbleDiameter
    ) -> CGRect {
        CGRect(
            x: center.x - diameter * 0.5,
            y: center.y - diameter * 0.5,
            width: diameter,
            height: diameter
        )
    }

    /// Classifies a finished gesture as a point or rectangle in normalized
    /// section coordinates, rescaling overlay points into the captured
    /// viewport when the two sizes differ.
    static func annotationKind(
        startPoint: CGPoint,
        endPoint: CGPoint,
        overlaySize: CGSize,
        viewportSize: CGSize,
        dragThreshold: CGFloat = BrowserAnnotationMarkStyle.dragThreshold
    ) -> BrowserAnnotationKind {
        let scaledStart = scaledOverlayPoint(
            startPoint,
            overlaySize: overlaySize,
            viewportSize: viewportSize
        )
        let scaledEnd = scaledOverlayPoint(
            endPoint,
            overlaySize: overlaySize,
            viewportSize: viewportSize
        )

        if hypot(scaledStart.x - scaledEnd.x, scaledStart.y - scaledEnd.y) <= dragThreshold {
            return .point(BrowserAnnotationCoordinateMapper.normalizedPoint(
                fromViewportTopLeftPoint: scaledEnd,
                viewportSize: viewportSize
            ))
        }
        return .rectangle(BrowserAnnotationCoordinateMapper.normalizedRectangle(
            fromViewportTopLeftStart: scaledStart,
            end: scaledEnd,
            viewportSize: viewportSize
        ))
    }

    private static func scaledOverlayPoint(
        _ point: CGPoint,
        overlaySize: CGSize,
        viewportSize: CGSize
    ) -> CGPoint {
        guard overlaySize.width > 0, overlaySize.height > 0 else {
            return point
        }
        return CGPoint(
            x: point.x * viewportSize.width / overlaySize.width,
            y: point.y * viewportSize.height / overlaySize.height
        )
    }
}
