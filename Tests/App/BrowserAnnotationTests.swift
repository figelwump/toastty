@testable import ToasttyApp
import AppKit
import WebKit
import XCTest

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

    private static func blankPNGData(width: Int, height: Int) -> Data {
        BrowserAnnotationTestImage.pngData(width: width, height: height)
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
final class BrowserAnnotationRuntimeTests: XCTestCase {
    func testAnnotationScrollOffsetParsesStringDictionaryWithoutRecursing() {
        let value: [String: Any] = [
            "x": 12.5,
            "y": NSNumber(value: 44),
        ]

        XCTAssertEqual(
            BrowserPanelRuntime.annotationScrollOffset(from: value),
            CGPoint(x: 12.5, y: 44)
        )
    }

    func testAnnotationScrollOffsetParsesHashableDictionaryWithoutRecursing() {
        let value: [AnyHashable: Any] = [
            "x": NSNumber(value: 7),
            "y": 9.25,
        ]

        XCTAssertEqual(
            BrowserPanelRuntime.annotationScrollOffset(from: value),
            CGPoint(x: 7, y: 9.25)
        )
    }

    func testAnnotationScrollOffsetParsesNSDictionaryFromWebKitBridge() {
        let value = NSDictionary(dictionary: [
            "x": NSNumber(value: 3),
            "y": NSNumber(value: 4),
        ])

        XCTAssertEqual(
            BrowserPanelRuntime.annotationScrollOffset(from: value),
            CGPoint(x: 3, y: 4)
        )
    }

    func testDidCommitClearsDraftsAndExitsAnnotationMode() throws {
        let runtime = BrowserPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        runtime.attachHost(to: container, attachment: PanelHostAttachmentToken.next())
        let webView = try XCTUnwrap(container.subviews.first as? WKWebView)

        runtime.setAnnotationModeEnabled(true)
        runtime.recordAnnotation(
            in: BrowserAnnotationCapturedSection(
                pngData: BrowserAnnotationTestImage.pngData(width: 20, height: 20),
                url: nil,
                title: nil,
                scrollOffset: .zero,
                viewportSize: CGSize(width: 320, height: 240),
                capturedAt: Date()
            ),
            kind: .point(.zero),
            comment: "Draft"
        )

        runtime.webView(webView, didCommit: nil)

        XCTAssertFalse(runtime.annotationState.isAnnotationModeEnabled)
        XCTAssertFalse(runtime.annotationState.hasDrafts)
        XCTAssertEqual(runtime.annotationState.nextSequenceNumber, 1)
    }
}

@MainActor
final class BrowserAnnotatedScreenshotRendererTests: XCTestCase {
    func testRendererDrawsNumberedPointOntoPNG() throws {
        let section = BrowserAnnotationSection(
            id: UUID(),
            pngData: BrowserAnnotationTestImage.pngData(width: 100, height: 80),
            url: nil,
            title: nil,
            scrollOffset: .zero,
            viewportSize: CGSize(width: 100, height: 80),
            capturedAt: Date(timeIntervalSince1970: 1),
            annotations: [
                BrowserAnnotationItem(
                    id: UUID(),
                    sequenceNumber: 1,
                    kind: .point(CGPoint(x: 0.5, y: 0.5)),
                    comment: "Center",
                    createdAt: Date(timeIntervalSince1970: 2)
                ),
            ]
        )

        let renderedData = try BrowserAnnotatedScreenshotRenderer.render(section: section)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: renderedData))

        var redPixelCount = 0
        for x in 0 ..< bitmap.pixelsWide {
            for y in 0 ..< bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                if color.redComponent > 0.75,
                   color.greenComponent < 0.5,
                   color.blueComponent < 0.5 {
                    redPixelCount += 1
                }
            }
        }

        XCTAssertGreaterThan(redPixelCount, 120)
    }
}

final class BrowserAnnotationPayloadBuilderTests: XCTestCase {
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
            Browser annotations

            Screenshot 1: /tmp/toastty-browser-annotations/example.png
            Page: Example Page
            URL: https://example.com/page
            Viewport: x=0, y=500, w=900, h=700
            1. First note
            2. Second note
            """
        )
    }
}

@MainActor
final class BrowserAnnotationScreenshotWriterTests: XCTestCase {
    func testWriterUsesUniquePathsForRepeatedSendsAtSameTimestamp() throws {
        let fileManager = FileManager.default

        let section = BrowserAnnotationSection(
            id: UUID(),
            pngData: BrowserAnnotationTestImage.pngData(width: 40, height: 40),
            url: "https://example.com/page",
            title: "Example",
            scrollOffset: .zero,
            viewportSize: CGSize(width: 40, height: 40),
            capturedAt: Date(timeIntervalSince1970: 1),
            annotations: [
                BrowserAnnotationItem(
                    id: UUID(),
                    sequenceNumber: 1,
                    kind: .point(CGPoint(x: 0.5, y: 0.5)),
                    comment: "Point",
                    createdAt: Date(timeIntervalSince1970: 2)
                ),
            ]
        )
        let date = Date(timeIntervalSince1970: 100)

        let first = try BrowserAnnotationScreenshotWriter.writeRenderedSections(
            from: [section],
            date: date,
            fileManager: fileManager
        )
        let second = try BrowserAnnotationScreenshotWriter.writeRenderedSections(
            from: [section],
            date: date,
            fileManager: fileManager
        )

        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1)
        XCTAssertNotEqual(first[0].fileURL, second[0].fileURL)
        XCTAssertTrue(fileManager.fileExists(atPath: first[0].fileURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: second[0].fileURL.path))

        try? fileManager.removeItem(at: first[0].fileURL)
        try? fileManager.removeItem(at: second[0].fileURL)
    }
}

enum BrowserAnnotationTestImage {
    static func pngData(width: Int, height: Int) -> Data {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: width, height: height)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])!
    }
}
