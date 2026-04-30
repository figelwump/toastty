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
}

private final class HitProbeView: NSView {}
