@testable import ToasttyApp
import AppKit
import CoreState
import Foundation
import XCTest

// Platform-neutral annotation model, geometry, session, and payload tests
// (split from BrowserAnnotationTests.swift so the Linux build runs them too).
// `BrowserAnnotationTestImage` comes from BrowserAnnotationTests.swift on
// macOS and from linux/Tests/ToasttyAppLogicTests on Linux.

final class BrowserAnnotationSendGateTests: XCTestCase {
    func testAgentSessionsAreSendableUnlessApprovalOrErrorBlocksThem() {
        XCTAssertEqual(BrowserAnnotationSendGate.availability(for: .idle), .available)
        XCTAssertEqual(BrowserAnnotationSendGate.availability(for: .working), .available)
        XCTAssertEqual(BrowserAnnotationSendGate.availability(for: .ready), .available)
        XCTAssertEqual(
            BrowserAnnotationSendGate.availability(for: .needsApproval),
            .blocked(reason: "awaiting approval")
        )
        XCTAssertEqual(
            BrowserAnnotationSendGate.availability(for: .error),
            .blocked(reason: "in an error state")
        )
        XCTAssertEqual(
            BrowserAnnotationSendGate.availability(for: nil),
            .blocked(reason: "unavailable")
        )
    }
}

final class BrowserAnnotationDraftStateTests: XCTestCase {
    func testRecordAnnotationReusesMatchingSectionAndIncrementsNumbers() {
        let pngData = Self.blankPNGData(width: 80, height: 60)
        var state = BrowserAnnotationDraftState()
        let firstSection = BrowserAnnotationCapturedSection(
            pngData: pngData,
            url: "https://example.com/a",
            title: "Example",
            scrollOffset: CGPoint(x: 0, y: 100),
            viewportSize: CGSize(width: 800, height: 600),
            capturedAt: Date(timeIntervalSince1970: 10)
        )
        let matchingSection = BrowserAnnotationCapturedSection(
            pngData: pngData,
            url: "https://example.com/a",
            title: "Example",
            scrollOffset: CGPoint(x: 1, y: 101),
            viewportSize: CGSize(width: 801, height: 600),
            capturedAt: Date(timeIntervalSince1970: 20)
        )

        let firstItem = state.recordAnnotation(
            in: firstSection,
            kind: .point(CGPoint(x: 0.25, y: 0.5)),
            comment: "First",
            createdAt: Date(timeIntervalSince1970: 11)
        )
        let secondItem = state.recordAnnotation(
            in: matchingSection,
            kind: .rectangle(CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)),
            comment: "Second",
            createdAt: Date(timeIntervalSince1970: 21)
        )

        XCTAssertEqual(state.sections.count, 1)
        XCTAssertEqual(state.sections[0].annotations.map(\.comment), ["First", "Second"])
        XCTAssertEqual([firstItem.sequenceNumber, secondItem.sequenceNumber], [1, 2])
        XCTAssertEqual(state.nextSequenceNumber, 3)
        XCTAssertTrue(state.hasDrafts)
    }

    func testRecordAnnotationCreatesSeparateSectionOutsideEpsilon() {
        let pngData = Self.blankPNGData(width: 80, height: 60)
        var state = BrowserAnnotationDraftState()

        state.recordAnnotation(
            in: BrowserAnnotationCapturedSection(
                pngData: pngData,
                url: nil,
                title: nil,
                scrollOffset: CGPoint(x: 0, y: 0),
                viewportSize: CGSize(width: 800, height: 600),
                capturedAt: Date(timeIntervalSince1970: 10)
            ),
            kind: .point(.zero),
            comment: "Top"
        )
        state.recordAnnotation(
            in: BrowserAnnotationCapturedSection(
                pngData: pngData,
                url: nil,
                title: nil,
                scrollOffset: CGPoint(x: 0, y: 20),
                viewportSize: CGSize(width: 800, height: 600),
                capturedAt: Date(timeIntervalSince1970: 11)
            ),
            kind: .point(.zero),
            comment: "Lower"
        )

        XCTAssertEqual(state.sections.count, 2)
        XCTAssertEqual(state.sections.flatMap(\.annotations).map(\.sequenceNumber), [1, 2])
    }

    func testClearCanExitAnnotationMode() {
        var state = BrowserAnnotationDraftState(isAnnotationModeEnabled: true)
        state.recordAnnotation(
            in: BrowserAnnotationCapturedSection(
                pngData: Self.blankPNGData(width: 20, height: 20),
                url: nil,
                title: nil,
                scrollOffset: .zero,
                viewportSize: CGSize(width: 20, height: 20),
                capturedAt: Date()
            ),
            kind: .point(.zero),
            comment: "Draft"
        )

        state.clear(exitAnnotationMode: true)

        XCTAssertFalse(state.isAnnotationModeEnabled)
        XCTAssertEqual(state.sections, [])
        XCTAssertEqual(state.nextSequenceNumber, 1)
    }

    func testRemoveAnnotationRenumbersAndPrunesEmptySections() {
        let pngData = Self.blankPNGData(width: 80, height: 60)
        var state = BrowserAnnotationDraftState()
        let topSection = BrowserAnnotationCapturedSection(
            pngData: pngData,
            url: nil,
            title: nil,
            scrollOffset: .zero,
            viewportSize: CGSize(width: 800, height: 600),
            capturedAt: Date(timeIntervalSince1970: 10)
        )
        let lowerSection = BrowserAnnotationCapturedSection(
            pngData: pngData,
            url: nil,
            title: nil,
            scrollOffset: CGPoint(x: 0, y: 600),
            viewportSize: CGSize(width: 800, height: 600),
            capturedAt: Date(timeIntervalSince1970: 11)
        )

        let first = state.recordAnnotation(in: topSection, kind: .point(.zero), comment: "First")
        state.recordAnnotation(in: lowerSection, kind: .point(.zero), comment: "Second")
        state.recordAnnotation(in: lowerSection, kind: .point(.zero), comment: "Third")

        XCTAssertTrue(state.removeAnnotation(annotationID: first.id))

        XCTAssertEqual(state.sections.count, 1)
        XCTAssertEqual(state.sections[0].annotations.map(\.comment), ["Second", "Third"])
        XCTAssertEqual(state.sections[0].annotations.map(\.sequenceNumber), [1, 2])
        XCTAssertEqual(state.nextSequenceNumber, 3)
        XCTAssertFalse(state.removeAnnotation(annotationID: first.id))
    }

    func testUpdateAnnotationCommentEditsInPlace() {
        var state = BrowserAnnotationDraftState()
        let item = state.recordAnnotation(
            in: BrowserAnnotationCapturedSection(
                pngData: Self.blankPNGData(width: 20, height: 20),
                url: nil,
                title: nil,
                scrollOffset: .zero,
                viewportSize: CGSize(width: 20, height: 20),
                capturedAt: Date()
            ),
            kind: .point(.zero),
            comment: "Original"
        )

        XCTAssertTrue(state.updateAnnotationComment(annotationID: item.id, comment: "Edited"))

        let updated = state.annotationItem(withID: item.id)
        XCTAssertEqual(updated?.comment, "Edited")
        XCTAssertEqual(updated?.sequenceNumber, 1)
        XCTAssertFalse(state.updateAnnotationComment(annotationID: UUID(), comment: "Missing"))
    }

    private static func blankPNGData(width: Int, height: Int) -> Data {
        BrowserAnnotationTestImage.pngData(width: width, height: height)
    }
}

final class BrowserAnnotationDisplayGeometryTests: XCTestCase {
    private func section(
        scrollOffset: CGPoint,
        viewportSize: CGSize = CGSize(width: 800, height: 600),
        annotations: [BrowserAnnotationItem]
    ) -> BrowserAnnotationSection {
        BrowserAnnotationSection(
            id: UUID(),
            pngData: BrowserAnnotationTestImage.pngData(width: 8, height: 6),
            url: nil,
            title: nil,
            scrollOffset: scrollOffset,
            viewportSize: viewportSize,
            capturedAt: Date(timeIntervalSince1970: 1),
            annotations: annotations
        )
    }

    private func pointItem(_ point: CGPoint, sequenceNumber: Int = 1) -> BrowserAnnotationItem {
        BrowserAnnotationItem(
            id: UUID(),
            sequenceNumber: sequenceNumber,
            kind: .point(point),
            comment: "Point",
            createdAt: Date(timeIntervalSince1970: 2)
        )
    }

    func testDisplayMarksTranslatePointsWithScrollDelta() {
        let marks = BrowserAnnotationDisplayGeometry.displayMarks(
            sections: [section(
                scrollOffset: CGPoint(x: 0, y: 100),
                annotations: [pointItem(CGPoint(x: 0.5, y: 0.5))]
            )],
            currentScrollOffsetPoints: CGPoint(x: 0, y: 150),
            pageZoom: 1,
            overlayBounds: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        XCTAssertEqual(marks.count, 1)
        XCTAssertEqual(marks[0].shape, .point(center: CGPoint(x: 400, y: 250)))
        XCTAssertEqual(marks[0].bubbleRect.midX, 400)
        XCTAssertEqual(marks[0].bubbleRect.midY, 250)
    }

    func testDisplayMarksConvertScrollOffsetsThroughPageZoom() {
        let marks = BrowserAnnotationDisplayGeometry.displayMarks(
            sections: [section(
                scrollOffset: CGPoint(x: 0, y: 100),
                annotations: [pointItem(CGPoint(x: 0.5, y: 0.5))]
            )],
            currentScrollOffsetPoints: CGPoint(x: 0, y: 200),
            pageZoom: 2,
            overlayBounds: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        XCTAssertEqual(marks[0].shape, .point(center: CGPoint(x: 400, y: 300)))
    }

    func testDisplayMarksCullMarksOutsideOverlayBounds() {
        let marks = BrowserAnnotationDisplayGeometry.displayMarks(
            sections: [section(
                scrollOffset: CGPoint(x: 0, y: 100),
                annotations: [pointItem(CGPoint(x: 0.5, y: 0.5))]
            )],
            currentScrollOffsetPoints: CGPoint(x: 0, y: 900),
            pageZoom: 1,
            overlayBounds: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        XCTAssertEqual(marks, [])
    }

    func testDisplayMarksAnchorRectangleBubbleOnTopLeftCorner() {
        let item = BrowserAnnotationItem(
            id: UUID(),
            sequenceNumber: 1,
            kind: .rectangle(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)),
            comment: "Region",
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let marks = BrowserAnnotationDisplayGeometry.displayMarks(
            sections: [section(scrollOffset: .zero, annotations: [item])],
            currentScrollOffsetPoints: .zero,
            pageZoom: 1,
            overlayBounds: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        XCTAssertEqual(marks[0].shape, .rectangle(CGRect(x: 200, y: 150, width: 400, height: 300)))
        XCTAssertEqual(marks[0].bubbleRect.midX, 200)
        XCTAssertEqual(marks[0].bubbleRect.midY, 150)
    }

    func testAnnotationKindClassifiesClickAsPointAndDragAsRectangle() {
        let point = BrowserAnnotationDisplayGeometry.annotationKind(
            startPoint: CGPoint(x: 100, y: 100),
            endPoint: CGPoint(x: 102, y: 102),
            overlaySize: CGSize(width: 800, height: 600),
            viewportSize: CGSize(width: 800, height: 600)
        )
        XCTAssertEqual(point, .point(CGPoint(x: 102.0 / 800.0, y: 102.0 / 600.0)))

        let rectangle = BrowserAnnotationDisplayGeometry.annotationKind(
            startPoint: CGPoint(x: 100, y: 100),
            endPoint: CGPoint(x: 300, y: 250),
            overlaySize: CGSize(width: 800, height: 600),
            viewportSize: CGSize(width: 800, height: 600)
        )
        XCTAssertEqual(
            rectangle,
            .rectangle(CGRect(
                x: 100.0 / 800.0,
                y: 100.0 / 600.0,
                width: 200.0 / 800.0,
                height: 150.0 / 600.0
            ))
        )
    }
}

final class BrowserAnnotationCoordinateMapperTests: XCTestCase {
    func testViewportPointNormalizesFromTopLeftCoordinates() {
        XCTAssertEqual(
            BrowserAnnotationCoordinateMapper.normalizedPoint(
                fromViewportTopLeftPoint: CGPoint(x: 200, y: 150),
                viewportSize: CGSize(width: 800, height: 600)
            ),
            CGPoint(x: 0.25, y: 0.25)
        )
    }

    func testViewportRectangleNormalizesReversedDragFromTopLeftCoordinates() {
        XCTAssertEqual(
            BrowserAnnotationCoordinateMapper.normalizedRectangle(
                fromViewportTopLeftStart: CGPoint(x: 600, y: 450),
                end: CGPoint(x: 200, y: 150),
                viewportSize: CGSize(width: 800, height: 600)
            ),
            CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        )
    }

    func testNormalizedRectMapsToBottomLeftDrawingCoordinates() {
        XCTAssertEqual(
            BrowserAnnotationCoordinateMapper.drawingRect(
                forNormalizedTopLeftRect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
                imageSize: CGSize(width: 800, height: 600)
            ),
            CGRect(x: 200, y: 150, width: 400, height: 300)
        )
    }
}

@MainActor
final class WebPanelAnnotationSessionTests: XCTestCase {
    func testContentChangeInvalidatesPendingCapturesAndResetsEditorAndDrafts() {
        let session = WebPanelAnnotationSession()
        session.setAnnotationModeEnabled(true)
        session.setAnnotationEditorActive(true)
        session.postAnnotationSendNotice(message: "Old content", isFailure: false)
        session.recordAnnotation(
            in: BrowserAnnotationCapturedSection(
                pngData: Data(),
                url: nil,
                title: "Scratchpad",
                scrollOffset: .zero,
                viewportSize: CGSize(width: 320, height: 240),
                capturedAt: Date()
            ),
            kind: .point(.zero),
            comment: "Change this"
        )
        let generation = session.contentGeneration

        session.invalidateForContentChange()

        XCTAssertNotEqual(session.contentGeneration, generation)
        XCTAssertFalse(session.annotationState.hasDrafts)
        XCTAssertFalse(session.annotationState.isAnnotationModeEnabled)
        XCTAssertFalse(session.isAnnotationEditorActive)
        XCTAssertNil(session.annotationSendNotice)
        XCTAssertEqual(session.annotationState.nextSequenceNumber, 1)
    }

    func testContentChangeInvalidatesCaptureEvenBeforeDraftAppears() {
        let session = WebPanelAnnotationSession()
        let generation = session.contentGeneration

        session.invalidateForContentChange()

        XCTAssertNotEqual(session.contentGeneration, generation)
    }
}

final class BrowserAnnotationPayloadBuilderTests: XCTestCase {
    func testPayloadIdentifiesScratchpadSourceWhileBrowserRemainsDefault() {
        XCTAssertTrue(
            BrowserAnnotationPayloadBuilder.payload(renderedSections: [], source: .scratchpad)
                .hasPrefix("Scratchpad annotation feedback from Toastty.")
        )
        XCTAssertTrue(
            BrowserAnnotationPayloadBuilder.payload(renderedSections: [])
                .hasPrefix("Browser annotation feedback from Toastty.")
        )
    }

    func testPayloadGroupsCommentsUnderRenderedScreenshots() {
        let section = BrowserAnnotationSection(
            id: UUID(),
            pngData: BrowserAnnotationTestImage.pngData(width: 20, height: 20),
            url: "https://example.com/page",
            title: "Example Page",
            scrollOffset: CGPoint(x: 0, y: 500),
            viewportSize: CGSize(width: 900, height: 700),
            capturedAt: Date(timeIntervalSince1970: 1),
            annotations: [
                BrowserAnnotationItem(
                    id: UUID(),
                    sequenceNumber: 2,
                    kind: .point(CGPoint(x: 0.2, y: 0.3)),
                    comment: "Second note",
                    createdAt: Date(timeIntervalSince1970: 2)
                ),
                BrowserAnnotationItem(
                    id: UUID(),
                    sequenceNumber: 1,
                    kind: .point(CGPoint(x: 0.1, y: 0.1)),
                    comment: "First note",
                    createdAt: Date(timeIntervalSince1970: 3)
                ),
            ]
        )

        let payload = BrowserAnnotationPayloadBuilder.payload(renderedSections: [
            BrowserAnnotationRenderedSection(
                section: section,
                fileURL: URL(fileURLWithPath: "/tmp/toastty-browser-annotations/example.png")
            ),
        ])

        XCTAssertEqual(
            payload,
            """
            Browser annotation feedback from Toastty.
            Each numbered comment refers to the matching numbered mark drawn in the screenshot listed above it. Read each screenshot and address the comments.
            For small/medium scope changes, go ahead with implementation. Only ask the user for plan review for large changes.

            Screenshot 1: /tmp/toastty-browser-annotations/example.png
            Page: Example Page
            URL: https://example.com/page
            Viewport: x=0, y=500, w=900, h=700
            1. First note
            2. Second note
            """
        )
    }

    func testPayloadIndentsMultilineCommentContinuationLines() {
        let section = BrowserAnnotationSection(
            id: UUID(),
            pngData: BrowserAnnotationTestImage.pngData(width: 20, height: 20),
            url: nil,
            title: nil,
            scrollOffset: .zero,
            viewportSize: CGSize(width: 900, height: 700),
            capturedAt: Date(timeIntervalSince1970: 1),
            annotations: [
                BrowserAnnotationItem(
                    id: UUID(),
                    sequenceNumber: 1,
                    kind: .point(CGPoint(x: 0.1, y: 0.1)),
                    comment: "First line\nsecond line",
                    createdAt: Date(timeIntervalSince1970: 2)
                ),
                BrowserAnnotationItem(
                    id: UUID(),
                    sequenceNumber: 2,
                    kind: .point(CGPoint(x: 0.2, y: 0.2)),
                    comment: "Single line",
                    createdAt: Date(timeIntervalSince1970: 3)
                ),
            ]
        )

        let payload = BrowserAnnotationPayloadBuilder.payload(renderedSections: [
            BrowserAnnotationRenderedSection(
                section: section,
                fileURL: URL(fileURLWithPath: "/tmp/toastty-browser-annotations/example.png")
            ),
        ])

        XCTAssertEqual(
            payload,
            """
            Browser annotation feedback from Toastty.
            Each numbered comment refers to the matching numbered mark drawn in the screenshot listed above it. Read each screenshot and address the comments.
            For small/medium scope changes, go ahead with implementation. Only ask the user for plan review for large changes.

            Screenshot 1: /tmp/toastty-browser-annotations/example.png
            Viewport: x=0, y=0, w=900, h=700
            1. First line
               second line
            2. Single line
            """
        )
    }
}
