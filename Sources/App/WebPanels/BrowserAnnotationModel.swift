import AppKit
import Foundation

struct BrowserAnnotationDraftState: Equatable {
    var isAnnotationModeEnabled = false
    var sections: [BrowserAnnotationSection] = []
    var nextSequenceNumber = 1

    var hasDrafts: Bool {
        sections.contains { $0.annotations.isEmpty == false }
    }

    var draftCount: Int {
        sections.reduce(0) { $0 + $1.annotations.count }
    }

    mutating func clear(exitAnnotationMode: Bool) {
        sections.removeAll()
        nextSequenceNumber = 1
        if exitAnnotationMode {
            isAnnotationModeEnabled = false
        }
    }

    mutating func recordAnnotation(
        in capturedSection: BrowserAnnotationCapturedSection,
        kind: BrowserAnnotationKind,
        comment: String,
        createdAt: Date = Date(),
        sectionMatchingEpsilon: CGFloat = BrowserAnnotationSection.defaultMatchingEpsilon
    ) -> BrowserAnnotationItem {
        let item = BrowserAnnotationItem(
            id: UUID(),
            sequenceNumber: nextSequenceNumber,
            kind: kind,
            comment: comment,
            createdAt: createdAt
        )
        nextSequenceNumber += 1

        if let index = sections.firstIndex(where: {
            $0.matches(capturedSection, epsilon: sectionMatchingEpsilon)
        }) {
            sections[index].annotations.append(item)
            return item
        }

        sections.append(BrowserAnnotationSection(
            id: UUID(),
            pngData: capturedSection.pngData,
            url: capturedSection.url,
            title: capturedSection.title,
            scrollOffset: capturedSection.scrollOffset,
            viewportSize: capturedSection.viewportSize,
            capturedAt: capturedSection.capturedAt,
            annotations: [item]
        ))
        return item
    }

    func annotationItem(withID annotationID: UUID) -> BrowserAnnotationItem? {
        for section in sections {
            if let item = section.annotations.first(where: { $0.id == annotationID }) {
                return item
            }
        }
        return nil
    }

    @discardableResult
    mutating func updateAnnotationComment(annotationID: UUID, comment: String) -> Bool {
        for sectionIndex in sections.indices {
            if let itemIndex = sections[sectionIndex].annotations.firstIndex(
                where: { $0.id == annotationID }
            ) {
                sections[sectionIndex].annotations[itemIndex].comment = comment
                return true
            }
        }
        return false
    }

    @discardableResult
    mutating func removeAnnotation(annotationID: UUID) -> Bool {
        var removed = false
        for sectionIndex in sections.indices {
            if let itemIndex = sections[sectionIndex].annotations.firstIndex(
                where: { $0.id == annotationID }
            ) {
                sections[sectionIndex].annotations.remove(at: itemIndex)
                removed = true
                break
            }
        }
        guard removed else { return false }

        sections.removeAll { $0.annotations.isEmpty }
        renumberAnnotations()
        return true
    }

    private mutating func renumberAnnotations() {
        let orderedIDs = sections
            .flatMap(\.annotations)
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
            .map(\.id)
        let numbersByID = Dictionary(
            uniqueKeysWithValues: orderedIDs.enumerated().map { ($0.element, $0.offset + 1) }
        )
        for sectionIndex in sections.indices {
            for itemIndex in sections[sectionIndex].annotations.indices {
                let annotationID = sections[sectionIndex].annotations[itemIndex].id
                if let number = numbersByID[annotationID] {
                    sections[sectionIndex].annotations[itemIndex].sequenceNumber = number
                }
            }
        }
        nextSequenceNumber = orderedIDs.count + 1
    }
}

/// Transient user-facing feedback for the annotation send flow, shown as a
/// toast over the browser body.
struct BrowserAnnotationSendNotice: Equatable, Identifiable {
    let id: UUID
    let message: String
    let isFailure: Bool
}

struct BrowserAnnotationCapturedSection: Equatable {
    var pngData: Data
    var url: String?
    var title: String?
    var scrollOffset: CGPoint
    var viewportSize: CGSize
    var capturedAt: Date
}

struct BrowserAnnotationViewport: Equatable {
    var scrollOffset: CGPoint
    var viewportSize: CGSize
}

struct BrowserAnnotationSection: Identifiable, Equatable {
    static let defaultMatchingEpsilon: CGFloat = 2

    var id: UUID
    var pngData: Data
    var url: String?
    var title: String?
    var scrollOffset: CGPoint
    var viewportSize: CGSize
    var capturedAt: Date
    var annotations: [BrowserAnnotationItem]

    func matches(
        _ capturedSection: BrowserAnnotationCapturedSection,
        epsilon: CGFloat = defaultMatchingEpsilon
    ) -> Bool {
        matches(
            scrollOffset: capturedSection.scrollOffset,
            viewportSize: capturedSection.viewportSize,
            epsilon: epsilon
        )
    }

    func matches(
        scrollOffset: CGPoint,
        viewportSize: CGSize,
        epsilon: CGFloat = defaultMatchingEpsilon
    ) -> Bool {
        abs(self.scrollOffset.x - scrollOffset.x) <= epsilon &&
            abs(self.scrollOffset.y - scrollOffset.y) <= epsilon &&
            abs(self.viewportSize.width - viewportSize.width) <= epsilon &&
            abs(self.viewportSize.height - viewportSize.height) <= epsilon
    }
}

struct BrowserAnnotationItem: Identifiable, Equatable {
    var id: UUID
    var sequenceNumber: Int
    var kind: BrowserAnnotationKind
    var comment: String
    var createdAt: Date
}

enum BrowserAnnotationKind: Equatable {
    case point(CGPoint)
    case rectangle(CGRect)
}

enum BrowserAnnotationCoordinateMapper {
    static func normalizedPoint(
        fromViewportTopLeftPoint point: CGPoint,
        viewportSize: CGSize
    ) -> CGPoint {
        guard viewportSize.width > 0, viewportSize.height > 0 else {
            return .zero
        }
        return CGPoint(
            x: clamped(point.x / viewportSize.width),
            y: clamped(point.y / viewportSize.height)
        )
    }

    static func normalizedRectangle(
        fromViewportTopLeftStart start: CGPoint,
        end: CGPoint,
        viewportSize: CGSize
    ) -> CGRect {
        guard viewportSize.width > 0, viewportSize.height > 0 else {
            return .zero
        }
        let minX = min(start.x, end.x)
        let maxX = max(start.x, end.x)
        let minY = min(start.y, end.y)
        let maxY = max(start.y, end.y)
        return CGRect(
            x: clamped(minX / viewportSize.width),
            y: clamped(minY / viewportSize.height),
            width: clamped((maxX - minX) / viewportSize.width),
            height: clamped((maxY - minY) / viewportSize.height)
        )
    }

    static func drawingPoint(
        forNormalizedTopLeftPoint point: CGPoint,
        imageSize: CGSize
    ) -> CGPoint {
        CGPoint(
            x: clamped(point.x) * imageSize.width,
            y: (1 - clamped(point.y)) * imageSize.height
        )
    }

    static func drawingRect(
        forNormalizedTopLeftRect rect: CGRect,
        imageSize: CGSize
    ) -> CGRect {
        let normalized = rect.standardized
        let minX = clamped(normalized.minX)
        let maxX = clamped(normalized.maxX)
        let minY = clamped(normalized.minY)
        let maxY = clamped(normalized.maxY)

        return CGRect(
            x: minX * imageSize.width,
            y: (1 - maxY) * imageSize.height,
            width: max(0, maxX - minX) * imageSize.width,
            height: max(0, maxY - minY) * imageSize.height
        )
    }

    private static func clamped(_ value: CGFloat) -> CGFloat {
        min(1, max(0, value))
    }
}
