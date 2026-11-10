@testable import ToasttyApp
import AppKit
import Combine
import CoreState
import WebKit
import XCTest

@MainActor
final class BrowserAnnotationPopoverSessionTests: XCTestCase {
    func testCreateEditAndDetailPopoversAllowNativeDragging() throws {
        let annotationID = UUID()
        for purpose in [
            BrowserAnnotationPopoverSession.Purpose.create,
            .edit(annotationID: annotationID),
            .view(annotationID: annotationID),
        ] {
            let session = BrowserAnnotationPopoverSession(purpose: purpose)
            let delegate = try XCTUnwrap(session.popover.delegate)

            XCTAssertEqual(delegate.popoverShouldDetach?(session.popover), true)
            // AppKit must reuse the content instead of asking us to build a
            // second editor whose text and selection could diverge.
            XCTAssertNil(delegate.detachableWindow?(for: session.popover))
        }
    }
}

@MainActor
final class BrowserAnnotationSendFlowTests: XCTestCase {
    func testSendKeepsInFlightSetUntilQueuedSendRunsAndBlocksReentry() async {
        let runtime = BrowserPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        runtime.setAnnotationModeEnabled(true)
        runtime.recordAnnotation(
            in: BrowserAnnotationCapturedSection(
                pngData: BrowserAnnotationTestImage.pngData(width: 20, height: 20),
                url: "https://example.com",
                title: "Example",
                scrollOffset: .zero,
                viewportSize: CGSize(width: 20, height: 20),
                capturedAt: Date()
            ),
            kind: .point(CGPoint(x: 0.5, y: 0.5)),
            comment: "Draft"
        )

        let candidate = BrowserScreenshotSendCandidate(
            sessionID: "session-1",
            agent: .codex,
            panelID: UUID(),
            label: "Codex"
        )
        var sendAttempts = 0
        let sendFinished = expectation(description: "queued annotation send finished")

        BrowserAnnotationSendFlow.send(
            runtime: runtime,
            candidate: candidate,
            availability: { _ in .available },
            sendPayload: { _, _ in
                sendAttempts += 1
                sendFinished.fulfill()
                return false
            }
        )
        BrowserAnnotationSendFlow.send(
            runtime: runtime,
            candidate: candidate,
            availability: { _ in .available },
            sendPayload: { _, _ in
                XCTFail("Reentrant send should be ignored while the first send is in flight")
                return false
            }
        )

        XCTAssertTrue(runtime.isAnnotationSendInFlight)
        XCTAssertEqual(sendAttempts, 0)

        await fulfillment(of: [sendFinished], timeout: 10)

        XCTAssertFalse(runtime.isAnnotationSendInFlight)
        XCTAssertEqual(sendAttempts, 1)
        XCTAssertTrue(runtime.annotationState.hasDrafts)
    }
}

@MainActor
final class BrowserAnnotationRuntimeTests: XCTestCase {
    func testRuntimePublishesSharedSessionChanges() {
        let runtime = BrowserPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        var publicationCount = 0
        let observation = runtime.objectWillChange.sink { publicationCount += 1 }

        runtime.annotationSession.setAnnotationModeEnabled(true)
        XCTAssertGreaterThan(publicationCount, 0)
        XCTAssertTrue(runtime.annotationState.isAnnotationModeEnabled)

        let countBeforeNotice = publicationCount
        runtime.annotationSession.postAnnotationSendNotice(message: "Sent", isFailure: false)
        XCTAssertGreaterThan(publicationCount, countBeforeNotice)
        XCTAssertEqual(runtime.annotationSendNotice?.message, "Sent")
        withExtendedLifetime(observation) {}
    }

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
        recordDraft(in: runtime)

        runtime.webView(webView, didCommit: nil)

        XCTAssertFalse(runtime.annotationState.isAnnotationModeEnabled)
        XCTAssertFalse(runtime.annotationState.hasDrafts)
        XCTAssertEqual(runtime.annotationState.nextSequenceNumber, 1)
    }

    func testClearAnnotationsInvalidatesPendingDraftGeneration() {
        let runtime = BrowserPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )

        runtime.setAnnotationModeEnabled(true)
        recordDraft(in: runtime)
        let generationBeforeClear = runtime.currentAnnotationPageGeneration()

        runtime.clearAnnotations(exitAnnotationMode: false)

        XCTAssertNotEqual(runtime.currentAnnotationPageGeneration(), generationBeforeClear)
        XCTAssertTrue(runtime.annotationState.isAnnotationModeEnabled)
        XCTAssertFalse(runtime.annotationState.hasDrafts)
        XCTAssertEqual(runtime.annotationState.nextSequenceNumber, 1)
    }

    func testClearAnnotationsInvalidatesEvenWithoutVisibleDraftState() {
        let runtime = BrowserPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let generationBeforeClear = runtime.currentAnnotationPageGeneration()

        runtime.clearAnnotations()

        XCTAssertNotEqual(runtime.currentAnnotationPageGeneration(), generationBeforeClear)
        XCTAssertFalse(runtime.annotationState.isAnnotationModeEnabled)
        XCTAssertFalse(runtime.annotationState.hasDrafts)
    }

    func testDisablingAnnotationModeDoesNotInvalidatePendingDraftGeneration() {
        let runtime = BrowserPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )

        runtime.setAnnotationModeEnabled(true)
        let generationBeforeToggle = runtime.currentAnnotationPageGeneration()

        runtime.setAnnotationModeEnabled(false)

        XCTAssertEqual(runtime.currentAnnotationPageGeneration(), generationBeforeToggle)
        XCTAssertFalse(runtime.annotationState.isAnnotationModeEnabled)
    }

    func testObservedURLChangeClearsDraftsAndExitsAnnotationMode() {
        let runtime = BrowserPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )

        XCTAssertFalse(runtime.handleObservedURLChange("https://example.com/first"))
        runtime.setAnnotationModeEnabled(true)
        recordDraft(in: runtime)
        let generationBeforeRouteChange = runtime.currentAnnotationPageGeneration()

        XCTAssertTrue(runtime.handleObservedURLChange("https://example.com/second"))

        XCTAssertNotEqual(runtime.currentAnnotationPageGeneration(), generationBeforeRouteChange)
        XCTAssertFalse(runtime.annotationState.isAnnotationModeEnabled)
        XCTAssertFalse(runtime.annotationState.hasDrafts)
        XCTAssertEqual(runtime.annotationState.nextSequenceNumber, 1)
    }

    func testObservedURLChangeWhileLoadingDoesNotClearDrafts() {
        let runtime = BrowserPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )

        XCTAssertFalse(runtime.handleObservedURLChange("https://example.com/first"))
        runtime.setAnnotationModeEnabled(true)
        recordDraft(in: runtime)
        let generationBeforeObservedLoad = runtime.currentAnnotationPageGeneration()

        XCTAssertFalse(
            runtime.handleObservedURLChange(
                "https://example.com/second",
                isPageLoading: true
            )
        )

        XCTAssertEqual(runtime.currentAnnotationPageGeneration(), generationBeforeObservedLoad)
        XCTAssertTrue(runtime.annotationState.isAnnotationModeEnabled)
        XCTAssertTrue(runtime.annotationState.hasDrafts)
    }

    func testObservedURLChangeTreatsHashRoutesAsPageChanges() {
        let runtime = BrowserPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )

        XCTAssertFalse(runtime.handleObservedURLChange("https://example.com/#/first"))
        runtime.setAnnotationModeEnabled(true)
        recordDraft(in: runtime)

        XCTAssertTrue(runtime.handleObservedURLChange("https://example.com/#/second"))
        XCTAssertFalse(runtime.annotationState.isAnnotationModeEnabled)
        XCTAssertFalse(runtime.annotationState.hasDrafts)
    }

    private func recordDraft(in runtime: BrowserPanelRuntime) {
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

    func testMarkScaleUsesImageToViewportWidthRatio() {
        XCTAssertEqual(
            BrowserAnnotatedScreenshotRenderer.markScale(
                imageSize: CGSize(width: 200, height: 160),
                viewportSize: CGSize(width: 100, height: 80)
            ),
            2
        )
        XCTAssertEqual(
            BrowserAnnotatedScreenshotRenderer.markScale(
                imageSize: CGSize(width: 200, height: 160),
                viewportSize: .zero
            ),
            1
        )
    }

    func testRendererDrawsRectangleBadgeOnTopLeftCorner() throws {
        let section = BrowserAnnotationSection(
            id: UUID(),
            pngData: BrowserAnnotationTestImage.pngData(width: 200, height: 160),
            url: nil,
            title: nil,
            scrollOffset: .zero,
            viewportSize: CGSize(width: 100, height: 80),
            capturedAt: Date(timeIntervalSince1970: 1),
            annotations: [
                BrowserAnnotationItem(
                    id: UUID(),
                    sequenceNumber: 2,
                    kind: .rectangle(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)),
                    comment: "Region",
                    createdAt: Date(timeIntervalSince1970: 2)
                ),
            ]
        )

        let renderedData = try BrowserAnnotatedScreenshotRenderer.render(section: section)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: renderedData))

        // The badge is centered on the rectangle's top-left corner, which is
        // pixel (50, 40) in top-left bitmap coordinates at 2x mark scale.
        var cornerRedPixelCount = 0
        for x in 28 ... 72 {
            for y in 18 ... 62 {
                guard x >= 0, y >= 0, x < bitmap.pixelsWide, y < bitmap.pixelsHigh,
                      let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                if color.redComponent > 0.75,
                   color.greenComponent < 0.5,
                   color.blueComponent < 0.5 {
                    cornerRedPixelCount += 1
                }
            }
        }

        XCTAssertGreaterThan(cornerRedPixelCount, 400)
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
