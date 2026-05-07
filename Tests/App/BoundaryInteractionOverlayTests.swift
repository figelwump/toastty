@testable import ToasttyApp
import AppKit
import XCTest

final class BoundaryInteractionOverlayTests: XCTestCase {
    @MainActor
    func testDescriptorSelectionStraddlesVerticalSeamFromBothSides() {
        let overlay = BoundaryInteractionOverlayView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 100)
        )
        overlay.updateDescriptors([
            descriptor(id: "seam", hitFrame: CGRect(x: 95, y: 0, width: 10, height: 100)),
        ])

        XCTAssertEqual(overlay.descriptorID(at: CGPoint(x: 96, y: 50)), "seam")
        XCTAssertEqual(overlay.descriptorID(at: CGPoint(x: 104, y: 50)), "seam")
        XCTAssertNil(overlay.descriptorID(at: CGPoint(x: 94.9, y: 50)))
        XCTAssertNil(overlay.descriptorID(at: CGPoint(x: 105.1, y: 50)))
    }

    @MainActor
    func testHitTestReturnsOverlayOnlyInsideBoundaryFrame() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let content = HitProbeView(frame: container.bounds)
        let overlay = BoundaryInteractionOverlayView(frame: container.bounds)
        container.addSubview(content)
        container.addSubview(overlay)
        overlay.updateDescriptors([
            descriptor(id: "seam", hitFrame: CGRect(x: 95, y: 0, width: 10, height: 100)),
        ])

        XCTAssertIdentical(container.hitTest(NSPoint(x: 100, y: 50)), overlay)
        XCTAssertIdentical(container.hitTest(NSPoint(x: 70, y: 50)), content)
        XCTAssertIdentical(container.hitTest(NSPoint(x: 130, y: 50)), content)
    }

    @MainActor
    func testHitTestConvertsSuperviewCoordinatesBeforeDescriptorLookup() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1407, height: 951))
        let content = HitProbeView(frame: container.bounds)
        let overlay = BoundaryInteractionOverlayView(frame: container.bounds)
        container.addSubview(content)
        container.addSubview(overlay)
        overlay.updateDescriptors([
            descriptor(
                id: "horizontal-divider",
                hitFrame: CGRect(x: 448, y: 388.5, width: 959, height: 10.5)
            ),
        ])

        let visualBottomRowClick = NSPoint(x: 1044.8, y: 396.7)
        let overlayLocalClick = overlay.convert(visualBottomRowClick, from: container)
        XCTAssertEqual(overlayLocalClick.y, 554.3, accuracy: 0.1)
        XCTAssertNil(overlay.descriptorID(at: overlayLocalClick))
        XCTAssertIdentical(container.hitTest(visualBottomRowClick), content)
    }

    @MainActor
    func testOverlayWinsInsideBoundaryWhenBoundaryOverlapsSiblingContent() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let primaryContent = HitProbeView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let rightContent = HitProbeView(frame: NSRect(x: 100, y: 0, width: 200, height: 100))
        let overlay = BoundaryInteractionOverlayView(frame: container.bounds)
        container.addSubview(primaryContent)
        container.addSubview(rightContent)
        container.addSubview(overlay)
        overlay.updateDescriptors([
            descriptor(id: "seam", hitFrame: CGRect(x: 95, y: 0, width: 10, height: 100)),
        ])

        XCTAssertIdentical(container.hitTest(NSPoint(x: 98, y: 50)), overlay)
        XCTAssertIdentical(container.hitTest(NSPoint(x: 102, y: 50)), overlay)
        XCTAssertIdentical(container.hitTest(NSPoint(x: 90, y: 50)), primaryContent)
        XCTAssertIdentical(container.hitTest(NSPoint(x: 110, y: 50)), rightContent)
    }

    @MainActor
    func testMouseDownMissForwardsToUnderlyingHitView() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let content = MouseDownProbeView(frame: container.bounds)
        let overlay = BoundaryInteractionOverlayView(frame: container.bounds)
        container.addSubview(content)
        container.addSubview(overlay)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        container.layoutSubtreeIfNeeded()

        var beganValue: BoundaryInteractionValue?
        overlay.updateDescriptors([
            descriptor(
                id: "seam",
                hitFrame: CGRect(x: 95, y: 0, width: 10, height: 100),
                onBegan: { beganValue = $0 }
            ),
        ])

        let mouseDown = try mouseEvent(type: .leftMouseDown, location: NSPoint(x: 70, y: 50), window: window)
        XCTAssertIdentical(container.hitTest(NSPoint(x: 70, y: 50)), content)

        overlay.mouseDown(with: mouseDown)

        XCTAssertEqual(content.mouseDownCount, 1)
        XCTAssertNil(beganValue)
    }

    @MainActor
    func testMouseDownMissForwardsToValidSuperviewCandidateWhenWindowCandidateIsOutsideBounds() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let contentView = ForcedHitContentView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let staleTarget = MouseDownProbeView(frame: NSRect(x: 0, y: 70, width: 300, height: 20))
        let container = NSView(frame: contentView.bounds)
        let validTarget = MouseDownProbeView(frame: contentView.bounds)
        let overlay = BoundaryInteractionOverlayView(frame: container.bounds)
        contentView.addSubview(staleTarget)
        contentView.addSubview(container)
        container.addSubview(validTarget)
        container.addSubview(overlay)
        contentView.forcedHitView = staleTarget
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        contentView.layoutSubtreeIfNeeded()

        overlay.updateDescriptors([
            descriptor(id: "seam", hitFrame: CGRect(x: 95, y: 0, width: 10, height: 100)),
        ])

        let mouseDown = try mouseEvent(type: .leftMouseDown, location: NSPoint(x: 70, y: 50), window: window)
        let staleTargetLocation = staleTarget.convert(mouseDown.locationInWindow, from: nil)
        XCTAssertFalse(staleTarget.bounds.contains(staleTargetLocation))
        XCTAssertIdentical(container.hitTest(NSPoint(x: 70, y: 50)), validTarget)

        overlay.mouseDown(with: mouseDown)

        XCTAssertEqual(staleTarget.mouseDownCount, 0)
        XCTAssertEqual(validTarget.mouseDownCount, 1)
    }

    @MainActor
    func testDragReportsOverlayLocalTranslationAndRestoresWindowMovement() throws {
        defer { WindowMovementSuppression.resetForTesting() }
        let (window, overlay) = makeWindowWithOverlay()
        defer { window.orderOut(nil) }

        overlay.usesEventTrackingLoop = false
        var beganValue: BoundaryInteractionValue?
        var changedValue: BoundaryInteractionValue?
        var endedValue: BoundaryInteractionValue?
        overlay.updateDescriptors([
            descriptor(
                id: "seam",
                hitFrame: CGRect(x: 95, y: 0, width: 10, height: 100),
                onBegan: { beganValue = $0 },
                onChanged: { changedValue = $0 },
                onEnded: { endedValue = $0 }
            ),
        ])

        XCTAssertTrue(window.isMovable)
        overlay.mouseDown(
            with: try mouseEvent(type: .leftMouseDown, location: NSPoint(x: 100, y: 50), window: window)
        )
        XCTAssertFalse(window.isMovable)
        overlay.mouseDragged(
            with: try mouseEvent(type: .leftMouseDragged, location: NSPoint(x: 70, y: 40), window: window)
        )
        overlay.mouseUp(
            with: try mouseEvent(type: .leftMouseUp, location: NSPoint(x: 70, y: 40), window: window)
        )
        XCTAssertTrue(window.isMovable)

        let began = try XCTUnwrap(beganValue)
        XCTAssertEqual(began.descriptorID, "seam")
        XCTAssertEqual(began.startLocation.x, 100, accuracy: 0.001)
        XCTAssertEqual(began.startLocation.y, 50, accuracy: 0.001)
        XCTAssertEqual(began.translation.width, 0, accuracy: 0.001)
        XCTAssertEqual(began.translation.height, 0, accuracy: 0.001)

        let changed = try XCTUnwrap(changedValue)
        XCTAssertEqual(changed.descriptorID, "seam")
        XCTAssertEqual(changed.translation.width, -30, accuracy: 0.001)
        XCTAssertEqual(changed.translation.height, 10, accuracy: 0.001)
        XCTAssertEqual(changed.location.x, 70, accuracy: 0.001)
        XCTAssertEqual(changed.location.y, 60, accuracy: 0.001)
        XCTAssertEqual(endedValue, changedValue)
    }

    @MainActor
    func testLocalMouseDownMonitorCapturesBoundaryWhenSiblingWouldReceiveHitTest() throws {
        defer { WindowMovementSuppression.resetForTesting() }
        let (window, container, overlay, coveringContent) = makeWindowWithCoveredOverlay()
        defer { window.orderOut(nil) }

        var beganValue: BoundaryInteractionValue?
        var changedValue: BoundaryInteractionValue?
        var endedValue: BoundaryInteractionValue?
        overlay.updateDescriptors([
            descriptor(
                id: "seam",
                hitFrame: CGRect(x: 95, y: 0, width: 10, height: 100),
                onBegan: { beganValue = $0 },
                onChanged: { changedValue = $0 },
                onEnded: { endedValue = $0 }
            ),
        ])

        XCTAssertIdentical(container.hitTest(NSPoint(x: 100, y: 50)), coveringContent)
        let mouseDown = try mouseEvent(type: .leftMouseDown, location: NSPoint(x: 100, y: 50), window: window)
        var trackingEvents = [
            try mouseEvent(type: .leftMouseDragged, location: NSPoint(x: 80, y: 40), window: window),
            try mouseEvent(type: .leftMouseUp, location: NSPoint(x: 80, y: 40), window: window),
        ]
        overlay.trackingEventProviderForTesting = { _ in
            trackingEvents.isEmpty ? nil : trackingEvents.removeFirst()
        }

        XCTAssertNil(overlay.handleLocalMouseDownMonitorEventForTesting(mouseDown))
        XCTAssertTrue(window.isMovable)
        XCTAssertTrue(trackingEvents.isEmpty)

        let began = try XCTUnwrap(beganValue)
        XCTAssertEqual(began.descriptorID, "seam")
        XCTAssertEqual(began.startLocation.x, 100, accuracy: 0.001)
        XCTAssertEqual(began.startLocation.y, 50, accuracy: 0.001)
        let changed = try XCTUnwrap(changedValue)
        XCTAssertEqual(changed.translation.width, -20, accuracy: 0.001)
        XCTAssertEqual(changed.translation.height, 10, accuracy: 0.001)
        XCTAssertEqual(endedValue, changedValue)
    }

    @MainActor
    func testInstalledLocalMouseDownMonitorConsumesBoundaryHit() throws {
        defer { WindowMovementSuppression.resetForTesting() }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let overlay = BoundaryInteractionOverlayView(frame: container.bounds)
        let coveringContent = HitProbeView(frame: container.bounds)
        let monitorToken = NSObject()
        var installedHandler: ((NSEvent) -> NSEvent?)?
        overlay.localMouseDownMonitorInstallerForTesting = { mask, handler in
            XCTAssertTrue(mask.contains(.leftMouseDown))
            installedHandler = handler
            return monitorToken
        }
        overlay.localMouseDownMonitorRemoverForTesting = { monitor in
            XCTAssertTrue((monitor as AnyObject) === monitorToken)
        }

        container.addSubview(overlay)
        container.addSubview(coveringContent)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        container.layoutSubtreeIfNeeded()

        var beganValue: BoundaryInteractionValue?
        var endedValue: BoundaryInteractionValue?
        overlay.updateDescriptors([
            descriptor(
                id: "seam",
                hitFrame: CGRect(x: 95, y: 0, width: 10, height: 100),
                onBegan: { beganValue = $0 },
                onEnded: { endedValue = $0 }
            ),
        ])
        var trackingEvents = [
            try mouseEvent(type: .leftMouseUp, location: NSPoint(x: 100, y: 50), window: window),
        ]
        overlay.trackingEventProviderForTesting = { _ in
            trackingEvents.isEmpty ? nil : trackingEvents.removeFirst()
        }

        XCTAssertIdentical(container.hitTest(NSPoint(x: 100, y: 50)), coveringContent)
        let mouseDown = try mouseEvent(type: .leftMouseDown, location: NSPoint(x: 100, y: 50), window: window)
        let handler = try XCTUnwrap(installedHandler)

        XCTAssertNil(handler(mouseDown))
        XCTAssertNotNil(beganValue)
        XCTAssertEqual(endedValue, beganValue)
        XCTAssertTrue(trackingEvents.isEmpty)
    }

    @MainActor
    func testLocalMouseDownMonitorPassesThroughNonBoundaryClicks() throws {
        let (window, _, overlay, _) = makeWindowWithCoveredOverlay()
        defer { window.orderOut(nil) }

        var beganValue: BoundaryInteractionValue?
        overlay.updateDescriptors([
            descriptor(
                id: "seam",
                hitFrame: CGRect(x: 95, y: 0, width: 10, height: 100),
                onBegan: { beganValue = $0 }
            ),
        ])
        let mouseDown = try mouseEvent(type: .leftMouseDown, location: NSPoint(x: 70, y: 50), window: window)

        XCTAssertIdentical(overlay.handleLocalMouseDownMonitorEventForTesting(mouseDown), mouseDown)
        XCTAssertNil(beganValue)
    }

    @MainActor
    func testLocalMouseDownMonitorPassesThroughWhenOverlayIsHidden() throws {
        let (window, _, overlay, _) = makeWindowWithCoveredOverlay()
        defer { window.orderOut(nil) }

        var beganValue: BoundaryInteractionValue?
        overlay.updateDescriptors([
            descriptor(
                id: "seam",
                hitFrame: CGRect(x: 95, y: 0, width: 10, height: 100),
                onBegan: { beganValue = $0 }
            ),
        ])
        overlay.isHidden = true
        let mouseDown = try mouseEvent(type: .leftMouseDown, location: NSPoint(x: 100, y: 50), window: window)

        XCTAssertIdentical(overlay.handleLocalMouseDownMonitorEventForTesting(mouseDown), mouseDown)
        XCTAssertNil(beganValue)
    }

    @MainActor
    func testLocalMouseDownMonitorPassesThroughWhenAncestorIsHidden() throws {
        let (window, container, overlay, _) = makeWindowWithCoveredOverlay()
        defer { window.orderOut(nil) }

        var beganValue: BoundaryInteractionValue?
        overlay.updateDescriptors([
            descriptor(
                id: "seam",
                hitFrame: CGRect(x: 95, y: 0, width: 10, height: 100),
                onBegan: { beganValue = $0 }
            ),
        ])
        container.isHidden = true
        let mouseDown = try mouseEvent(type: .leftMouseDown, location: NSPoint(x: 100, y: 50), window: window)

        XCTAssertIdentical(overlay.handleLocalMouseDownMonitorEventForTesting(mouseDown), mouseDown)
        XCTAssertNil(beganValue)
    }

    @MainActor
    func testHoverClearsWhenDescriptorReplacementNoLongerContainsPointer() throws {
        let (window, overlay) = makeWindowWithOverlay()
        defer { window.orderOut(nil) }

        var hoverStates: [Bool] = []
        overlay.updateDescriptors([
            descriptor(
                id: "seam",
                hitFrame: CGRect(x: 95, y: 0, width: 10, height: 100),
                onHoverChanged: { hoverStates.append($0) }
            ),
        ])

        overlay.mouseMoved(
            with: try mouseEvent(type: .mouseMoved, location: NSPoint(x: 100, y: 50), window: window)
        )
        XCTAssertEqual(hoverStates, [true])

        overlay.updateDescriptors([
            descriptor(
                id: "seam",
                hitFrame: CGRect(x: 150, y: 0, width: 10, height: 100),
                onHoverChanged: { hoverStates.append($0) }
            ),
        ])
        XCTAssertEqual(hoverStates, [true, false])
    }

    @MainActor
    func testDescriptorReplacementReappliesCursorForStationaryHoveredPointer() throws {
        defer { NSCursor.arrow.set() }
        let (window, overlay) = makeWindowWithOverlay()
        defer { window.orderOut(nil) }

        overlay.updateDescriptors([
            descriptor(
                id: "seam",
                hitFrame: CGRect(x: 95, y: 0, width: 10, height: 100),
                cursor: nil
            ),
        ])
        overlay.mouseMoved(
            with: try mouseEvent(type: .mouseMoved, location: NSPoint(x: 100, y: 50), window: window)
        )
        NSCursor.arrow.set()
        overlay.currentLocalMouseLocationProvider = {
            CGPoint(x: 100, y: 50)
        }

        overlay.updateDescriptors([
            descriptor(
                id: "seam",
                hitFrame: CGRect(x: 95, y: 0, width: 10, height: 100),
                cursor: .resizeLeftRight
            ),
        ])

        XCTAssertTrue(NSCursor.current === NSCursor.resizeLeftRight)
    }

    @MainActor
    func testCursorUpdateUsesCurrentPointerWhenEventLocationIsStale() throws {
        defer { NSCursor.arrow.set() }
        let (window, overlay) = makeWindowWithOverlay()
        defer { window.orderOut(nil) }

        var hoverStates: [Bool] = []
        overlay.currentLocalMouseLocationProvider = {
            CGPoint(x: 100, y: 50)
        }
        overlay.updateDescriptors([
            descriptor(
                id: "seam",
                hitFrame: CGRect(x: 95, y: 0, width: 10, height: 100),
                cursor: .resizeLeftRight,
                onHoverChanged: { hoverStates.append($0) }
            ),
        ])
        NSCursor.arrow.set()

        overlay.cursorUpdate(
            with: try mouseEvent(type: .mouseMoved, location: NSPoint(x: 40, y: 50), window: window)
        )

        XCTAssertTrue(NSCursor.current === NSCursor.resizeLeftRight)
        XCTAssertEqual(hoverStates, [true])
    }

    @MainActor
    func testCursorUpdateClearsHoverWhenStaleEventLocationStillHitsBoundary() throws {
        defer { NSCursor.arrow.set() }
        let (window, overlay) = makeWindowWithOverlay()
        defer { window.orderOut(nil) }

        var hoverStates: [Bool] = []
        overlay.currentLocalMouseLocationProvider = {
            CGPoint(x: 100, y: 50)
        }
        overlay.updateDescriptors([
            descriptor(
                id: "seam",
                hitFrame: CGRect(x: 95, y: 0, width: 10, height: 100),
                cursor: .resizeLeftRight,
                onHoverChanged: { hoverStates.append($0) }
            ),
        ])
        overlay.cursorUpdate(
            with: try mouseEvent(type: .mouseMoved, location: NSPoint(x: 100, y: 50), window: window)
        )
        XCTAssertTrue(NSCursor.current === NSCursor.resizeLeftRight)
        XCTAssertEqual(hoverStates, [true])

        overlay.currentLocalMouseLocationProvider = {
            CGPoint(x: 40, y: 50)
        }
        overlay.cursorUpdate(
            with: try mouseEvent(type: .mouseMoved, location: NSPoint(x: 100, y: 50), window: window)
        )

        XCTAssertEqual(hoverStates, [true, false])
    }

    @MainActor
    func testDeferredCursorReassertionRestoresCursorInsideBoundary() throws {
        defer { NSCursor.arrow.set() }
        let (window, overlay) = makeWindowWithOverlay()
        defer { window.orderOut(nil) }

        overlay.currentLocalMouseLocationProvider = {
            CGPoint(x: 100, y: 50)
        }
        overlay.updateDescriptors([
            descriptor(
                id: "seam",
                hitFrame: CGRect(x: 95, y: 0, width: 10, height: 100),
                cursor: .resizeLeftRight
            ),
        ])

        overlay.mouseMoved(
            with: try mouseEvent(type: .mouseMoved, location: NSPoint(x: 100, y: 50), window: window)
        )
        XCTAssertTrue(NSCursor.current === NSCursor.resizeLeftRight)
        XCTAssertTrue(overlay.hasPendingCursorReassertion)

        NSCursor.arrow.set()
        runDeferredMainQueueWork()

        XCTAssertTrue(NSCursor.current === NSCursor.resizeLeftRight)
        XCTAssertEqual(overlay.deferredCursorReassertionCount, 1)
    }

    @MainActor
    func testDeferredCursorReassertionSetsCursorWhenAlreadyCurrent() throws {
        defer { NSCursor.arrow.set() }
        let (window, overlay) = makeWindowWithOverlay()
        defer { window.orderOut(nil) }

        let resizeCursor = NSCursor.resizeLeftRight
        var setCursors: [NSCursor] = []
        overlay.cursorSetter = { cursor in
            setCursors.append(cursor)
            cursor.set()
        }
        overlay.updateDescriptors([
            descriptor(
                id: "seam",
                hitFrame: CGRect(x: 95, y: 0, width: 10, height: 100),
                cursor: resizeCursor
            ),
        ])
        overlay.currentLocalMouseLocationProvider = {
            CGPoint(x: 100, y: 50)
        }

        resizeCursor.set()
        XCTAssertTrue(NSCursor.current === resizeCursor)
        overlay.performCursorReassertionForTesting(descriptorID: "seam")

        XCTAssertEqual(setCursors.count, 1)
        XCTAssertTrue(try XCTUnwrap(setCursors.first) === resizeCursor)
        XCTAssertEqual(overlay.deferredCursorReassertionCount, 1)
    }

    @MainActor
    func testDeferredCursorReassertionDoesNotRestoreAfterPointerLeavesBoundary() throws {
        defer { NSCursor.arrow.set() }
        let (window, overlay) = makeWindowWithOverlay()
        defer { window.orderOut(nil) }

        var hoverStates: [Bool] = []
        overlay.currentLocalMouseLocationProvider = {
            CGPoint(x: 100, y: 50)
        }
        overlay.updateDescriptors([
            descriptor(
                id: "seam",
                hitFrame: CGRect(x: 95, y: 0, width: 10, height: 100),
                cursor: .resizeLeftRight,
                onHoverChanged: { hoverStates.append($0) }
            ),
        ])

        overlay.mouseMoved(
            with: try mouseEvent(type: .mouseMoved, location: NSPoint(x: 100, y: 50), window: window)
        )
        XCTAssertTrue(NSCursor.current === NSCursor.resizeLeftRight)
        XCTAssertTrue(overlay.hasPendingCursorReassertion)

        overlay.currentLocalMouseLocationProvider = {
            CGPoint(x: 40, y: 50)
        }
        overlay.mouseMoved(
            with: try mouseEvent(type: .mouseMoved, location: NSPoint(x: 40, y: 50), window: window)
        )
        XCTAssertEqual(hoverStates, [true, false])
        XCTAssertFalse(overlay.hasPendingCursorReassertion)

        NSCursor.arrow.set()
        runDeferredMainQueueWork()

        XCTAssertEqual(overlay.deferredCursorReassertionCount, 0)
    }

    @MainActor
    func testDescriptorRemovalCancelsPendingDeferredCursorReassertion() throws {
        defer { NSCursor.arrow.set() }
        let (window, overlay) = makeWindowWithOverlay()
        defer { window.orderOut(nil) }

        var hoverStates: [Bool] = []
        overlay.currentLocalMouseLocationProvider = {
            CGPoint(x: 100, y: 50)
        }
        overlay.updateDescriptors([
            descriptor(
                id: "seam",
                hitFrame: CGRect(x: 95, y: 0, width: 10, height: 100),
                cursor: .resizeLeftRight,
                onHoverChanged: { hoverStates.append($0) }
            ),
        ])

        overlay.mouseMoved(
            with: try mouseEvent(type: .mouseMoved, location: NSPoint(x: 100, y: 50), window: window)
        )
        XCTAssertTrue(overlay.hasPendingCursorReassertion)

        overlay.updateDescriptors([])
        XCTAssertEqual(hoverStates, [true, false])
        XCTAssertFalse(overlay.hasPendingCursorReassertion)

        NSCursor.arrow.set()
        runDeferredMainQueueWork()

        XCTAssertEqual(overlay.deferredCursorReassertionCount, 0)
    }

    @MainActor
    func testDescriptorReplacementDuringDragKeepsCapturedDescriptorID() throws {
        defer { WindowMovementSuppression.resetForTesting() }
        let (window, overlay) = makeWindowWithOverlay()
        defer { window.orderOut(nil) }

        overlay.usesEventTrackingLoop = false
        var changedValues: [BoundaryInteractionValue] = []
        overlay.updateDescriptors([
            descriptor(id: "seam", hitFrame: CGRect(x: 95, y: 0, width: 10, height: 100)),
        ])

        overlay.mouseDown(
            with: try mouseEvent(type: .leftMouseDown, location: NSPoint(x: 100, y: 50), window: window)
        )
        XCTAssertFalse(window.isMovable)

        overlay.updateDescriptors([
            descriptor(
                id: "seam",
                hitFrame: CGRect(x: 150, y: 0, width: 10, height: 100),
                onChanged: { changedValues.append($0) }
            ),
        ])
        overlay.mouseDragged(
            with: try mouseEvent(type: .leftMouseDragged, location: NSPoint(x: 80, y: 50), window: window)
        )
        overlay.mouseUp(
            with: try mouseEvent(type: .leftMouseUp, location: NSPoint(x: 80, y: 50), window: window)
        )

        let changed = try XCTUnwrap(changedValues.first)
        XCTAssertEqual(changed.descriptorID, "seam")
        XCTAssertEqual(changed.translation.width, -20, accuracy: 0.001)
        XCTAssertTrue(window.isMovable)
    }

    @MainActor
    func testDescriptorRemovalDuringDragCancelsAndRestoresWindowMovement() throws {
        defer { WindowMovementSuppression.resetForTesting() }
        let (window, overlay) = makeWindowWithOverlay()
        defer { window.orderOut(nil) }

        overlay.usesEventTrackingLoop = false
        var endedValues: [BoundaryInteractionValue] = []
        overlay.updateDescriptors([
            descriptor(
                id: "seam",
                hitFrame: CGRect(x: 95, y: 0, width: 10, height: 100),
                onEnded: { endedValues.append($0) }
            ),
        ])

        overlay.mouseDown(
            with: try mouseEvent(type: .leftMouseDown, location: NSPoint(x: 100, y: 50), window: window)
        )
        XCTAssertFalse(window.isMovable)
        overlay.updateDescriptors([])

        XCTAssertTrue(window.isMovable)
        XCTAssertEqual(endedValues.count, 1)
        XCTAssertEqual(endedValues.first?.descriptorID, "seam")
    }

    @MainActor
    func testViewRemovalDuringDragRestoresWindowMovement() throws {
        defer { WindowMovementSuppression.resetForTesting() }
        let (window, overlay) = makeWindowWithOverlay()
        defer { window.orderOut(nil) }

        overlay.usesEventTrackingLoop = false
        overlay.updateDescriptors([
            descriptor(id: "seam", hitFrame: CGRect(x: 95, y: 0, width: 10, height: 100)),
        ])

        overlay.mouseDown(
            with: try mouseEvent(type: .leftMouseDown, location: NSPoint(x: 100, y: 50), window: window)
        )
        XCTAssertFalse(window.isMovable)
        overlay.removeFromSuperview()

        XCTAssertTrue(window.isMovable)
    }

    @MainActor
    func testTrackingAreasRequestCursorUpdatesForBoundaryFrames() throws {
        let (window, overlay) = makeWindowWithOverlay()
        defer { window.orderOut(nil) }

        overlay.updateDescriptors([
            descriptor(
                id: "seam",
                hitFrame: CGRect(x: 95, y: 0, width: 10, height: 100),
                cursor: .resizeLeftRight
            ),
        ])
        overlay.updateTrackingAreas()

        let trackingArea = try XCTUnwrap(
            overlay.trackingAreas.first(where: { $0.options.contains(.cursorUpdate) })
        )
        XCTAssertEqual(trackingArea.rect, NSRect(x: 95, y: 0, width: 10, height: 100))
        XCTAssertTrue(trackingArea.options.contains(.mouseEnteredAndExited))
        XCTAssertTrue(trackingArea.options.contains(.mouseMoved))
    }

    @MainActor
    func testEquivalentDescriptorReplacementDoesNotRebuildTrackingAreas() {
        let overlay = BoundaryInteractionOverlayView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 100)
        )
        overlay.updateDescriptors([
            descriptor(
                id: "seam",
                hitFrame: CGRect(x: 95, y: 0, width: 10, height: 100),
                cursor: .resizeLeftRight,
                onChanged: { _ in XCTFail("first callback should not be invoked") }
            ),
        ])
        let rebuildCount = overlay.boundaryTrackingAreaRebuildCount

        overlay.updateDescriptors([
            descriptor(
                id: "seam",
                hitFrame: CGRect(x: 95, y: 0, width: 10, height: 100),
                cursor: .resizeLeftRight,
                onChanged: { _ in }
            ),
        ])

        XCTAssertEqual(overlay.boundaryTrackingAreaRebuildCount, rebuildCount)
        XCTAssertEqual(
            overlay.trackingAreas.filter { $0.options.contains(.cursorUpdate) }.count,
            1
        )
    }

    @MainActor
    func testFractionalHitFrameExpandsOutwardToBackingPixels() throws {
        let (window, overlay) = makeWindowWithOverlay()
        defer { window.orderOut(nil) }

        let logicalFrame = CGRect(x: 95.25, y: 0, width: 10, height: 100)
        overlay.updateDescriptors([
            descriptor(id: "seam", hitFrame: logicalFrame),
        ])

        let effectiveFrame = try XCTUnwrap(overlay.effectiveHitFrame(forDescriptorID: "seam"))
        let backingScale = window.backingScaleFactor
        let expectedMinX = floor(logicalFrame.minX * backingScale) / backingScale
        let expectedMaxX = ceil(logicalFrame.maxX * backingScale) / backingScale
        XCTAssertEqual(effectiveFrame.minX, expectedMinX, accuracy: 0.001)
        XCTAssertEqual(effectiveFrame.maxX, expectedMaxX, accuracy: 0.001)
        XCTAssertLessThanOrEqual(effectiveFrame.minX, logicalFrame.minX)
        XCTAssertGreaterThanOrEqual(effectiveFrame.maxX, logicalFrame.maxX)
        XCTAssertEqual(
            overlay.descriptorID(at: CGPoint(x: expectedMaxX - 0.001, y: 50)),
            "seam"
        )
        XCTAssertNil(overlay.descriptorID(at: CGPoint(x: expectedMaxX + 0.001, y: 50)))
    }

    @MainActor
    func testMouseExitedKeepsHoverWhenCurrentPointerIsStillInsideBoundary() throws {
        defer { NSCursor.arrow.set() }
        let (window, overlay) = makeWindowWithOverlay()
        defer { window.orderOut(nil) }

        var hoverStates: [Bool] = []
        overlay.updateDescriptors([
            descriptor(
                id: "seam",
                hitFrame: CGRect(x: 95, y: 0, width: 10, height: 100),
                cursor: .resizeLeftRight,
                onHoverChanged: { hoverStates.append($0) }
            ),
        ])

        overlay.mouseMoved(
            with: try mouseEvent(type: .mouseMoved, location: NSPoint(x: 100, y: 50), window: window)
        )
        XCTAssertEqual(hoverStates, [true])

        overlay.currentLocalMouseLocationProvider = {
            CGPoint(x: 100, y: 50)
        }
        overlay.mouseExited(
            with: try mouseEvent(type: .mouseMoved, location: NSPoint(x: 40, y: 50), window: window)
        )

        XCTAssertEqual(hoverStates, [true])
        XCTAssertTrue(NSCursor.current === NSCursor.resizeLeftRight)
    }

    @MainActor
    func testBackingPropertyChangeRebuildsTrackingAreasAndPreservesHover() throws {
        defer { NSCursor.arrow.set() }
        let (window, overlay) = makeWindowWithOverlay()
        defer { window.orderOut(nil) }

        var backingScale: CGFloat = 2
        overlay.backingScaleFactorProvider = {
            backingScale
        }
        overlay.currentLocalMouseLocationProvider = {
            CGPoint(x: 100, y: 50)
        }

        var hoverStates: [Bool] = []
        let logicalFrame = CGRect(x: 95.25, y: 0, width: 10, height: 100)
        overlay.updateDescriptors([
            descriptor(
                id: "seam",
                hitFrame: logicalFrame,
                cursor: .resizeLeftRight,
                onHoverChanged: { hoverStates.append($0) }
            ),
        ])
        overlay.mouseMoved(
            with: try mouseEvent(type: .mouseMoved, location: NSPoint(x: 100, y: 50), window: window)
        )
        let initialRebuildCount = overlay.boundaryTrackingAreaRebuildCount
        let initialEffectiveFrame = try XCTUnwrap(overlay.effectiveHitFrame(forDescriptorID: "seam"))
        XCTAssertEqual(initialEffectiveFrame.maxX, 105.5, accuracy: 0.001)
        XCTAssertEqual(hoverStates, [true])

        backingScale = 1
        overlay.viewDidChangeBackingProperties()

        let refreshedEffectiveFrame = try XCTUnwrap(overlay.effectiveHitFrame(forDescriptorID: "seam"))
        XCTAssertEqual(refreshedEffectiveFrame.maxX, 106, accuracy: 0.001)
        XCTAssertEqual(overlay.boundaryTrackingAreaRebuildCount, initialRebuildCount + 1)
        XCTAssertEqual(hoverStates, [true])
        XCTAssertTrue(NSCursor.current === NSCursor.resizeLeftRight)
    }

    @MainActor
    private func makeWindowWithOverlay() -> (NSWindow, BoundaryInteractionOverlayView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let overlay = BoundaryInteractionOverlayView(frame: container.bounds)
        container.addSubview(overlay)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        container.layoutSubtreeIfNeeded()
        return (window, overlay)
    }

    @MainActor
    private func makeWindowWithCoveredOverlay() -> (
        NSWindow,
        NSView,
        BoundaryInteractionOverlayView,
        HitProbeView
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let overlay = BoundaryInteractionOverlayView(frame: container.bounds)
        let coveringContent = HitProbeView(frame: container.bounds)
        container.addSubview(overlay)
        container.addSubview(coveringContent)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        container.layoutSubtreeIfNeeded()
        return (window, container, overlay, coveringContent)
    }

    private func descriptor(
        id: String,
        hitFrame: CGRect,
        cursor: NSCursor? = nil,
        onBegan: @escaping (BoundaryInteractionValue) -> Void = { _ in },
        onChanged: @escaping (BoundaryInteractionValue) -> Void = { _ in },
        onEnded: @escaping (BoundaryInteractionValue) -> Void = { _ in },
        onHoverChanged: @escaping (Bool) -> Void = { _ in }
    ) -> BoundaryInteractionDescriptor {
        BoundaryInteractionDescriptor(
            id: id,
            hitFrame: hitFrame,
            axis: .vertical,
            cursor: cursor,
            onBegan: onBegan,
            onChanged: onChanged,
            onEnded: onEnded,
            onHoverChanged: onHoverChanged
        )
    }

    @MainActor
    private func mouseEvent(
        type: NSEvent.EventType,
        location: NSPoint,
        window: NSWindow
    ) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: type == .mouseMoved ? 0 : 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ) else {
            throw NSError(domain: "BoundaryInteractionOverlayTests", code: 1, userInfo: nil)
        }
        return event
    }

    @MainActor
    private func runDeferredMainQueueWork() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
}

private final class HitProbeView: NSView {}

private final class MouseDownProbeView: NSView {
    private(set) var mouseDownCount = 0

    override func mouseDown(with event: NSEvent) {
        mouseDownCount += 1
        super.mouseDown(with: event)
    }
}

private final class ForcedHitContentView: NSView {
    weak var forcedHitView: NSView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        forcedHitView ?? super.hitTest(point)
    }
}
