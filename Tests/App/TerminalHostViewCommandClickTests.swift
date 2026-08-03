import AppKit
@testable import ToasttyApp
import XCTest

#if TOASTTY_HAS_GHOSTTY_KIT
import GhosttyKit

@MainActor
final class TerminalHostViewCommandClickTests: TerminalHostViewTestCase {
    func testCommandClickHoveredLinkOpensViaAppCallbackOnMouseUp() throws {
        let hostView = TerminalHostView()
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        var openedURL: URL?
        var usedAlternatePlacement = true

        window.contentView = contentView
        contentView.addSubview(hostView)
        hostView.setGhosttyMouseOverLink("https://example.com/docs")
        hostView.openCommandClickLink = { url, useAlternatePlacement in
            openedURL = url
            usedAlternatePlacement = useAlternatePlacement
            return true
        }

        hostView.mouseDown(
            with: try makeMouseEvent(
                type: .leftMouseDown,
                window: window,
                modifierFlags: [.command]
            )
        )
        hostView.mouseUp(
            with: try makeMouseEvent(
                type: .leftMouseUp,
                window: window,
                modifierFlags: [.command]
            )
        )

        XCTAssertEqual(openedURL?.absoluteString, "https://example.com/docs")
        XCTAssertFalse(usedAlternatePlacement)
    }

    func testCommandClickRefreshesHoveredLinkAtClickTimeWhenHoverStateIsEmpty() throws {
        let hostView = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        let mouseRecorder = GhosttyMousePositionRecorder()
        let mousePositionCallCount = SendableIntBox(0)
        var openedURL: URL?

        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            sendMousePosition: { _, x, y, mods in
                mousePositionCallCount.increment()
                mouseRecorder.record(x: x, y: y, mods: mods)
                guard x >= 0, y >= 0, mods.rawValue == GHOSTTY_MODS_SUPER.rawValue else {
                    return
                }
                hostView.setGhosttyMouseOverLink("https://example.com/docs")
            }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x124B))
        window.contentView = contentView
        contentView.addSubview(hostView)
        hostView.openCommandClickLink = { url, _ in
            openedURL = url
            return true
        }

        hostView.mouseDown(
            with: try makeMouseEvent(
                type: .leftMouseDown,
                window: window,
                location: NSPoint(x: 20, y: 30),
                modifierFlags: [.command]
            )
        )
        hostView.mouseUp(
            with: try makeMouseEvent(
                type: .leftMouseUp,
                window: window,
                location: NSPoint(x: 20, y: 30),
                modifierFlags: [.command]
            )
        )

        let lastMouseEvent = try XCTUnwrap(mouseRecorder.lastEvent)
        XCTAssertGreaterThanOrEqual(mousePositionCallCount.value, 2)
        XCTAssertEqual(lastMouseEvent.x, 20, accuracy: 0.001)
        XCTAssertEqual(lastMouseEvent.y, 70, accuracy: 0.001)
        XCTAssertEqual(lastMouseEvent.modsRawValue, GHOSTTY_MODS_SUPER.rawValue)
        XCTAssertEqual(openedURL?.absoluteString, "https://example.com/docs")
    }

    func testCommandShiftClickRefreshesHoveredLinkAtClickTimeWhenHoverStateIsEmpty() throws {
        let hostView = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        let mouseRecorder = GhosttyMousePositionRecorder()
        let mousePositionCallCount = SendableIntBox(0)
        var openedURL: URL?
        var usedAlternatePlacement = false

        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            sendMousePosition: { _, x, y, mods in
                mousePositionCallCount.increment()
                mouseRecorder.record(x: x, y: y, mods: mods)
                guard x >= 0, y >= 0, mods.rawValue == GHOSTTY_MODS_SUPER.rawValue else {
                    return
                }
                hostView.setGhosttyMouseOverLink("https://example.com/docs")
            }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x124C))
        window.contentView = contentView
        contentView.addSubview(hostView)
        hostView.openCommandClickLink = { url, useAlternatePlacement in
            openedURL = url
            usedAlternatePlacement = useAlternatePlacement
            return true
        }

        hostView.mouseDown(
            with: try makeMouseEvent(
                type: .leftMouseDown,
                window: window,
                location: NSPoint(x: 24, y: 36),
                modifierFlags: [.command, .shift]
            )
        )
        hostView.mouseUp(
            with: try makeMouseEvent(
                type: .leftMouseUp,
                window: window,
                location: NSPoint(x: 24, y: 36),
                modifierFlags: [.command, .shift]
            )
        )

        let lastMouseEvent = try XCTUnwrap(mouseRecorder.lastEvent)
        XCTAssertGreaterThanOrEqual(mousePositionCallCount.value, 2)
        XCTAssertEqual(lastMouseEvent.x, 24, accuracy: 0.001)
        XCTAssertEqual(lastMouseEvent.y, 64, accuracy: 0.001)
        XCTAssertEqual(lastMouseEvent.modsRawValue, GHOSTTY_MODS_SUPER.rawValue)
        XCTAssertEqual(openedURL?.absoluteString, "https://example.com/docs")
        XCTAssertTrue(usedAlternatePlacement)
    }

    func testCommandClickDoesNotRefreshHoveredLinkAtClickTimeWhenHoverStateIsPopulated() throws {
        let hostView = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        let mousePositionCallCount = SendableIntBox(0)
        var openedURL: URL?

        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            sendMousePosition: { _, _, _, _ in
                mousePositionCallCount.increment()
            }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x124D))
        window.contentView = contentView
        contentView.addSubview(hostView)
        hostView.setGhosttyMouseOverLink("https://example.com/docs")
        hostView.openCommandClickLink = { url, _ in
            openedURL = url
            return true
        }

        hostView.mouseDown(
            with: try makeMouseEvent(
                type: .leftMouseDown,
                window: window,
                location: NSPoint(x: 20, y: 30),
                modifierFlags: [.command]
            )
        )
        hostView.mouseUp(
            with: try makeMouseEvent(
                type: .leftMouseUp,
                window: window,
                location: NSPoint(x: 20, y: 30),
                modifierFlags: [.command]
            )
        )

        XCTAssertEqual(mousePositionCallCount.value, 0)
        XCTAssertEqual(openedURL?.absoluteString, "https://example.com/docs")
    }

    func testCommandShiftClickHoveredLinkUsesAlternatePlacement() throws {
        let hostView = TerminalHostView()
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        var openedURL: URL?
        var usedAlternatePlacement = false

        window.contentView = contentView
        contentView.addSubview(hostView)
        hostView.setGhosttyMouseOverLink("https://example.com/docs")
        hostView.openCommandClickLink = { url, useAlternatePlacement in
            openedURL = url
            usedAlternatePlacement = useAlternatePlacement
            return true
        }

        hostView.mouseDown(
            with: try makeMouseEvent(
                type: .leftMouseDown,
                window: window,
                modifierFlags: [.command, .shift]
            )
        )
        hostView.mouseUp(
            with: try makeMouseEvent(
                type: .leftMouseUp,
                window: window,
                modifierFlags: [.command, .shift]
            )
        )

        XCTAssertEqual(openedURL?.absoluteString, "https://example.com/docs")
        XCTAssertTrue(usedAlternatePlacement)
    }

    func testCommandShiftClickKeepsAlternatePlacementWhenShiftReleasesBeforeMouseUp() throws {
        let hostView = TerminalHostView()
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        var usedAlternatePlacement = false

        window.contentView = contentView
        contentView.addSubview(hostView)
        hostView.setGhosttyMouseOverLink("https://example.com/docs")
        hostView.openCommandClickLink = { _, useAlternatePlacement in
            usedAlternatePlacement = useAlternatePlacement
            return true
        }

        hostView.mouseDown(
            with: try makeMouseEvent(
                type: .leftMouseDown,
                window: window,
                modifierFlags: [.command, .shift]
            )
        )
        hostView.mouseUp(
            with: try makeMouseEvent(
                type: .leftMouseUp,
                window: window,
                modifierFlags: [.command]
            )
        )

        XCTAssertTrue(usedAlternatePlacement)
    }

    func testCommandShiftClickAfterStationaryShiftPressKeepsHoveredLink() throws {
        let hostView = TerminalHostView()
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        var openedURL: URL?
        var usedAlternatePlacement = false
        let transientClearPending = SendableBooleanBox(true)

        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            sendMousePosition: { _, _, _, _ in
                guard transientClearPending.takeIfTrue() else {
                    return
                }
                Task { @MainActor in
                    hostView.setGhosttyMouseOverLink(nil)
                }
            },
            keyTranslationMods: { _, mods in mods },
            sendKey: { _, _ in true }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1246))
        window.contentView = contentView
        window.forcedMouseLocationOutsideOfEventStream = NSPoint(x: 28, y: 32)
        contentView.addSubview(hostView)

        hostView.setGhosttyMouseOverLink("https://example.com/docs")
        hostView.openCommandClickLink = { url, useAlternatePlacement in
            openedURL = url
            usedAlternatePlacement = useAlternatePlacement
            return true
        }

        hostView.flagsChanged(
            with: try makeKeyEvent(
                type: .flagsChanged,
                keyCode: 0x38,
                modifierFlags: [.command, .shift]
            )
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        hostView.mouseDown(
            with: try makeMouseEvent(
                type: .leftMouseDown,
                window: window,
                modifierFlags: [.command, .shift]
            )
        )
        hostView.mouseUp(
            with: try makeMouseEvent(
                type: .leftMouseUp,
                window: window,
                modifierFlags: [.command, .shift]
            )
        )

        XCTAssertEqual(openedURL?.absoluteString, "https://example.com/docs")
        XCTAssertTrue(usedAlternatePlacement)
    }

    func testCommandShiftClickSurvivesSynchronousLinkClearDuringShiftKeyPress() throws {
        // Ghostty can synchronously emit mouse_over_link(nil) while processing a
        // Shift key press on a Cmd-hovered link. The suppression window must
        // cover the key event itself, not just the follow-up hover refresh.
        let hostView = TerminalHostView()
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        var openedURL: URL?
        var usedAlternatePlacement = false

        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            sendMousePosition: { _, _, _, _ in },
            keyTranslationMods: { _, mods in mods },
            sendKey: { _, _ in
                // Simulate Ghostty synchronously clearing the hovered link
                // when the shift modifier press is forwarded.
                hostView.setGhosttyMouseOverLink(nil)
                return true
            }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1248))
        window.contentView = contentView
        window.forcedMouseLocationOutsideOfEventStream = NSPoint(x: 28, y: 32)
        contentView.addSubview(hostView)

        hostView.setGhosttyMouseOverLink("https://example.com/docs")
        hostView.openCommandClickLink = { url, useAlternatePlacement in
            openedURL = url
            usedAlternatePlacement = useAlternatePlacement
            return true
        }

        hostView.flagsChanged(
            with: try makeKeyEvent(
                type: .flagsChanged,
                keyCode: 0x38,
                modifierFlags: [.command, .shift]
            )
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        hostView.mouseDown(
            with: try makeMouseEvent(
                type: .leftMouseDown,
                window: window,
                modifierFlags: [.command, .shift]
            )
        )
        hostView.mouseUp(
            with: try makeMouseEvent(
                type: .leftMouseUp,
                window: window,
                modifierFlags: [.command, .shift]
            )
        )

        XCTAssertEqual(openedURL?.absoluteString, "https://example.com/docs")
        XCTAssertTrue(usedAlternatePlacement)
    }

    func testShiftFlagsChangedIsWithheldFromGhosttyWhileCmdHoveringLink() throws {
        // Ghostty renders the link underline from its own tracked modifier
        // state, so forwarding a Shift press while the pointer is Cmd-hovering
        // a link visually turns the underline off even though the cached URL
        // stays armed. The matching release must be swallowed too, otherwise
        // Ghostty sees a release for a press it never observed.
        let hostView = TerminalHostView()
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        let keyCallCount = SendableIntBox(0)

        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            sendMousePosition: { _, _, _, _ in },
            keyTranslationMods: { _, mods in mods },
            sendKey: { _, _ in
                keyCallCount.increment()
                return true
            }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1249))
        window.contentView = contentView
        window.forcedMouseLocationOutsideOfEventStream = NSPoint(x: 28, y: 32)
        contentView.addSubview(hostView)

        hostView.setGhosttyMouseOverLink("https://example.com/docs")

        hostView.flagsChanged(
            with: try makeKeyEvent(
                type: .flagsChanged,
                keyCode: 0x38,
                modifierFlags: [.command, .shift]
            )
        )
        XCTAssertEqual(keyCallCount.value, 0, "Shift press while Cmd-hovering must not reach Ghostty")

        hostView.flagsChanged(
            with: try makeKeyEvent(
                type: .flagsChanged,
                keyCode: 0x38,
                modifierFlags: [.command]
            )
        )
        XCTAssertEqual(keyCallCount.value, 0, "Matching Shift release must also be swallowed")
    }

    func testShiftFlagsChangedForwardsNormallyWithoutCachedLinkHover() throws {
        // The suppression must be scoped to Cmd-hovered links. Shift without a
        // cached hover (or without Cmd) still needs to reach Ghostty so it can
        // track modifier state for selection drags and keyboard shortcuts.
        let hostView = TerminalHostView()
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        let keyCallCount = SendableIntBox(0)

        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            sendMousePosition: { _, _, _, _ in },
            keyTranslationMods: { _, mods in mods },
            sendKey: { _, _ in
                keyCallCount.increment()
                return true
            }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x124A))
        window.contentView = contentView
        window.forcedMouseLocationOutsideOfEventStream = NSPoint(x: 28, y: 32)
        contentView.addSubview(hostView)

        hostView.flagsChanged(
            with: try makeKeyEvent(
                type: .flagsChanged,
                keyCode: 0x38,
                modifierFlags: [.command, .shift]
            )
        )
        XCTAssertEqual(keyCallCount.value, 1, "Shift without a cached hover must still reach Ghostty")
    }

    func testMouseExitStillClearsHoveredLinkAfterSyntheticHoverRefresh() throws {
        let hostView = TerminalHostView()
        let scrollView = TerminalSurfaceScrollView(terminalHostView: hostView)
        let window = attachToVisibleWindow(scrollView)
        let transientClearPending = SendableBooleanBox(true)

        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            sendMousePosition: { _, _, _, _ in
                guard transientClearPending.takeIfTrue() else {
                    return
                }
                DispatchQueue.main.async {
                    hostView.setGhosttyMouseOverLink(nil)
                }
            },
            keyTranslationMods: { _, mods in mods },
            sendKey: { _, _ in true }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1247))
        hostView.setGhosttyMouseShape(GHOSTTY_MOUSE_SHAPE_TEXT)
        window.forcedMouseLocationOutsideOfEventStream = NSPoint(x: 28, y: 32)

        hostView.setGhosttyMouseOverLink("https://example.com/docs")

        hostView.flagsChanged(
            with: try makeKeyEvent(
                type: .flagsChanged,
                keyCode: 0x38,
                modifierFlags: [.command, .shift]
            )
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(scrollView.documentCursor === NSCursor.pointingHand)

        hostView.mouseExited(
            with: try makeMouseEvent(
                type: .mouseExited,
                window: window,
                modifierFlags: [.command, .shift]
            )
        )

        XCTAssertTrue(scrollView.documentCursor === NSCursor.iBeam)
    }

    func testCommandClickStaysPrimaryWhenShiftAppearsOnlyOnMouseUp() throws {
        let hostView = TerminalHostView()
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        var usedAlternatePlacement = true

        window.contentView = contentView
        contentView.addSubview(hostView)
        hostView.setGhosttyMouseOverLink("https://example.com/docs")
        hostView.openCommandClickLink = { _, useAlternatePlacement in
            usedAlternatePlacement = useAlternatePlacement
            return true
        }

        hostView.mouseDown(
            with: try makeMouseEvent(
                type: .leftMouseDown,
                window: window,
                modifierFlags: [.command]
            )
        )
        hostView.mouseUp(
            with: try makeMouseEvent(
                type: .leftMouseUp,
                window: window,
                modifierFlags: [.command, .shift]
            )
        )

        XCTAssertFalse(usedAlternatePlacement)
    }

    func testCommandClickHoveredLinkAllowsSmallDragJitter() throws {
        let hostView = TerminalHostView()
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        var openedURL: URL?

        window.contentView = contentView
        contentView.addSubview(hostView)
        hostView.setGhosttyMouseOverLink("https://example.com/docs")
        hostView.openCommandClickLink = { url, _ in
            openedURL = url
            return true
        }

        hostView.mouseDown(
            with: try makeMouseEvent(
                type: .leftMouseDown,
                window: window,
                location: NSPoint(x: 12, y: 12),
                modifierFlags: [.command]
            )
        )
        hostView.mouseDragged(
            with: try makeMouseEvent(
                type: .leftMouseDragged,
                window: window,
                location: NSPoint(x: 14, y: 13),
                modifierFlags: [.command]
            )
        )
        hostView.mouseUp(
            with: try makeMouseEvent(
                type: .leftMouseUp,
                window: window,
                location: NSPoint(x: 14, y: 13),
                modifierFlags: [.command]
            )
        )

        XCTAssertEqual(openedURL?.absoluteString, "https://example.com/docs")
    }

    func testCommandClickHoveredLinkDragCancelsOpen() throws {
        let hostView = TerminalHostView()
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        var openCallCount = 0

        window.contentView = contentView
        contentView.addSubview(hostView)
        hostView.setGhosttyMouseOverLink("https://example.com/docs")
        hostView.openCommandClickLink = { _, _ in
            openCallCount += 1
            return true
        }

        hostView.mouseDown(
            with: try makeMouseEvent(
                type: .leftMouseDown,
                window: window,
                location: NSPoint(x: 12, y: 12),
                modifierFlags: [.command]
            )
        )
        hostView.mouseDragged(
            with: try makeMouseEvent(
                type: .leftMouseDragged,
                window: window,
                location: NSPoint(x: 18, y: 12),
                modifierFlags: [.command]
            )
        )
        hostView.mouseUp(
            with: try makeMouseEvent(
                type: .leftMouseUp,
                window: window,
                location: NSPoint(x: 18, y: 12),
                modifierFlags: [.command]
            )
        )

        XCTAssertEqual(openCallCount, 0)
    }

    func testCommandClickHoveredLinkMouseUpMovementCancelsOpenWithoutDragEvent() throws {
        let hostView = TerminalHostView()
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        var openCallCount = 0

        window.contentView = contentView
        contentView.addSubview(hostView)
        hostView.setGhosttyMouseOverLink("https://example.com/docs")
        hostView.openCommandClickLink = { _, _ in
            openCallCount += 1
            return true
        }

        hostView.mouseDown(
            with: try makeMouseEvent(
                type: .leftMouseDown,
                window: window,
                location: NSPoint(x: 12, y: 12),
                modifierFlags: [.command]
            )
        )
        hostView.mouseUp(
            with: try makeMouseEvent(
                type: .leftMouseUp,
                window: window,
                location: NSPoint(x: 18, y: 12),
                modifierFlags: [.command]
            )
        )

        XCTAssertEqual(openCallCount, 0)
    }
}
#endif
