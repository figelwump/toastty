import AppKit
@testable import ToasttyApp
import XCTest

#if TOASTTY_HAS_GHOSTTY_KIT
import GhosttyKit

@MainActor
final class TerminalHostViewMouseForwardingTests: TerminalHostViewTestCase {
    func testMouseMovedNormalizesCommandShiftHoverModifiersForLinkDiscovery() throws {
        let hostView = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        let mouseRecorder = GhosttyMousePositionRecorder()
        let modifierFlags = NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.command.rawValue
                | NSEvent.ModifierFlags.shift.rawValue
                | UInt(NX_DEVICERSHIFTKEYMASK)
        )

        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            sendMousePosition: { _, x, y, mods in
                mouseRecorder.record(x: x, y: y, mods: mods)
            }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1243))
        window.contentView = contentView
        contentView.addSubview(hostView)

        hostView.mouseMoved(
            with: try makeMouseEvent(
                type: .mouseMoved,
                window: window,
                location: NSPoint(x: 20, y: 30),
                modifierFlags: modifierFlags
            )
        )

        let event = try XCTUnwrap(mouseRecorder.lastEvent)
        XCTAssertEqual(event.x, 20, accuracy: 0.001)
        XCTAssertEqual(event.y, 70, accuracy: 0.001)
        XCTAssertEqual(event.modsRawValue, GHOSTTY_MODS_SUPER.rawValue)
    }

    func testMouseDraggedPreservesShiftForCommandShiftDragModifiers() throws {
        let hostView = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        let mouseRecorder = GhosttyMousePositionRecorder()
        let modifierFlags = NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.command.rawValue
                | NSEvent.ModifierFlags.shift.rawValue
                | UInt(NX_DEVICERSHIFTKEYMASK)
        )

        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            sendMousePosition: { _, x, y, mods in
                mouseRecorder.record(x: x, y: y, mods: mods)
            }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1244))
        window.contentView = contentView
        contentView.addSubview(hostView)

        hostView.mouseDragged(
            with: try makeMouseEvent(
                type: .leftMouseDragged,
                window: window,
                location: NSPoint(x: 24, y: 36),
                modifierFlags: modifierFlags
            )
        )

        let event = try XCTUnwrap(mouseRecorder.lastEvent)
        XCTAssertEqual(event.modsRawValue, GHOSTTY_MODS_SUPER.rawValue | GHOSTTY_MODS_SHIFT.rawValue | GHOSTTY_MODS_SHIFT_RIGHT.rawValue)
    }

    func testFlagsChangedUsesNormalizedHoverModifiersForCurrentMousePosition() throws {
        let hostView = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        let mouseRecorder = GhosttyMousePositionRecorder()
        let modifierFlags = NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.command.rawValue
                | NSEvent.ModifierFlags.shift.rawValue
                | UInt(NX_DEVICERSHIFTKEYMASK)
        )

        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            sendMousePosition: { _, x, y, mods in
                mouseRecorder.record(x: x, y: y, mods: mods)
            },
            keyTranslationMods: { _, mods in mods },
            sendKey: { _, _ in true }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1245))
        window.contentView = contentView
        window.forcedMouseLocationOutsideOfEventStream = NSPoint(x: 28, y: 32)
        contentView.addSubview(hostView)

        hostView.flagsChanged(
            with: try makeKeyEvent(
                type: .flagsChanged,
                keyCode: 0x38,
                modifierFlags: modifierFlags
            )
        )

        let event = try XCTUnwrap(mouseRecorder.lastEvent)
        XCTAssertEqual(event.x, 28, accuracy: 0.001)
        XCTAssertEqual(event.y, 68, accuracy: 0.001)
        XCTAssertEqual(event.modsRawValue, GHOSTTY_MODS_SUPER.rawValue)
    }

    func testFocusedLeftMousePressAndReleaseForwardsBalancedButtons() throws {
        let hostView = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        let mouseButtonRecorder = GhosttyMouseButtonRecorder()
        let pressureRecorder = GhosttyMousePressureRecorder()

        window.forcedIsKeyWindow = true
        window.contentView = contentView
        contentView.addSubview(hostView)
        _ = window.makeFirstResponder(hostView)
        hostView.applicationIsActiveProvider = { true }
        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            sendMousePosition: { _, _, _, _ in },
            sendMouseButton: { surface, state, button, mods in
                mouseButtonRecorder.record(
                    surface: surface,
                    state: state,
                    button: button,
                    mods: mods
                )
                return true
            },
            setMousePressure: { surface, stage, pressure in
                pressureRecorder.record(surface: surface, stage: stage, pressure: pressure)
            }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1250))

        hostView.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, window: window))
        hostView.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, window: window))

        XCTAssertEqual(
            mouseButtonRecorder.events.map { "\($0.stateRawValue):\($0.buttonRawValue)" },
            [
                "\(GHOSTTY_MOUSE_PRESS.rawValue):\(GHOSTTY_MOUSE_LEFT.rawValue)",
                "\(GHOSTTY_MOUSE_RELEASE.rawValue):\(GHOSTTY_MOUSE_LEFT.rawValue)",
            ]
        )
        XCTAssertEqual(pressureRecorder.events.map(\.stage), [0])
    }

    func testFocusTransferLeftMouseClickIsFocusOnly() throws {
        let hostView = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let otherHostView = TerminalHostView()
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        let mouseButtonRecorder = GhosttyMouseButtonRecorder()
        let pressureRecorder = GhosttyMousePressureRecorder()
        var activationCount = 0

        window.forcedIsKeyWindow = true
        window.contentView = contentView
        contentView.addSubview(otherHostView)
        contentView.addSubview(hostView)
        _ = window.makeFirstResponder(otherHostView)
        hostView.applicationIsActiveProvider = { true }
        hostView.activatePanelIfNeeded = {
            activationCount += 1
            return true
        }
        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            sendMousePosition: { _, _, _, _ in },
            sendMouseButton: { surface, state, button, mods in
                mouseButtonRecorder.record(
                    surface: surface,
                    state: state,
                    button: button,
                    mods: mods
                )
                return true
            },
            setMousePressure: { surface, stage, pressure in
                pressureRecorder.record(surface: surface, stage: stage, pressure: pressure)
            }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1251))

        hostView.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, window: window))
        hostView.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, window: window))

        XCTAssertEqual(activationCount, 1)
        XCTAssertTrue(window.firstResponder === hostView)
        XCTAssertTrue(mouseButtonRecorder.events.isEmpty)
        XCTAssertTrue(pressureRecorder.events.isEmpty)
    }

    func testClickFromNonTerminalFirstResponderStillForwardsMouseButton() throws {
        let hostView = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let focusableView = FocusableTestView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        let mouseButtonRecorder = GhosttyMouseButtonRecorder()
        let pressureRecorder = GhosttyMousePressureRecorder()

        window.forcedIsKeyWindow = true
        window.contentView = contentView
        contentView.addSubview(focusableView)
        contentView.addSubview(hostView)
        _ = window.makeFirstResponder(focusableView)
        hostView.applicationIsActiveProvider = { true }
        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            sendMousePosition: { _, _, _, _ in },
            sendMouseButton: { surface, state, button, mods in
                mouseButtonRecorder.record(
                    surface: surface,
                    state: state,
                    button: button,
                    mods: mods
                )
                return true
            },
            setMousePressure: { surface, stage, pressure in
                pressureRecorder.record(surface: surface, stage: stage, pressure: pressure)
            }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1259))

        hostView.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, window: window))
        hostView.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, window: window))

        XCTAssertTrue(window.firstResponder === hostView)
        XCTAssertEqual(
            mouseButtonRecorder.events.map { "\($0.stateRawValue):\($0.buttonRawValue)" },
            [
                "\(GHOSTTY_MOUSE_PRESS.rawValue):\(GHOSTTY_MOUSE_LEFT.rawValue)",
                "\(GHOSTTY_MOUSE_RELEASE.rawValue):\(GHOSTTY_MOUSE_LEFT.rawValue)",
            ]
        )
        XCTAssertEqual(pressureRecorder.events.map(\.stage), [0])
    }

    func testFocusTransferDragDoesNotForwardMousePositionAfterSuppressedPress() throws {
        let hostView = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let otherHostView = TerminalHostView()
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        let mouseRecorder = GhosttyMousePositionRecorder()
        let mouseButtonRecorder = GhosttyMouseButtonRecorder()

        window.forcedIsKeyWindow = true
        window.contentView = contentView
        contentView.addSubview(otherHostView)
        contentView.addSubview(hostView)
        _ = window.makeFirstResponder(otherHostView)
        hostView.applicationIsActiveProvider = { true }
        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            sendMousePosition: { surface, x, y, mods in
                mouseRecorder.record(surface: surface, x: x, y: y, mods: mods)
            },
            sendMouseButton: { surface, state, button, mods in
                mouseButtonRecorder.record(
                    surface: surface,
                    state: state,
                    button: button,
                    mods: mods
                )
                return true
            }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1252))

        hostView.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, window: window))
        hostView.mouseDragged(
            with: try makeMouseEvent(
                type: .leftMouseDragged,
                window: window,
                location: NSPoint(x: 28, y: 36)
            )
        )
        hostView.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, window: window))

        XCTAssertTrue(mouseRecorder.events.isEmpty)
        XCTAssertTrue(mouseButtonRecorder.events.isEmpty)
    }

    func testFocusTransferCommandClickDoesNotOpenLinkOrRefreshHover() throws {
        let hostView = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let otherHostView = TerminalHostView()
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        let mouseRecorder = GhosttyMousePositionRecorder()
        var openCallCount = 0

        window.forcedIsKeyWindow = true
        window.contentView = contentView
        contentView.addSubview(otherHostView)
        contentView.addSubview(hostView)
        _ = window.makeFirstResponder(otherHostView)
        hostView.applicationIsActiveProvider = { true }
        hostView.setGhosttyMouseOverLink("https://example.com/docs")
        hostView.openCommandClickLink = { _, _ in
            openCallCount += 1
            return true
        }
        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            sendMousePosition: { surface, x, y, mods in
                mouseRecorder.record(surface: surface, x: x, y: y, mods: mods)
            }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1253))

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

        XCTAssertEqual(openCallCount, 0)
        XCTAssertTrue(mouseRecorder.events.isEmpty)
    }

    func testDragAfterForwardedLeftPressStillForwardsPosition() throws {
        let hostView = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        let mouseRecorder = GhosttyMousePositionRecorder()

        window.forcedIsKeyWindow = true
        window.contentView = contentView
        contentView.addSubview(hostView)
        _ = window.makeFirstResponder(hostView)
        hostView.applicationIsActiveProvider = { true }
        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            sendMousePosition: { surface, x, y, mods in
                mouseRecorder.record(surface: surface, x: x, y: y, mods: mods)
            },
            sendMouseButton: { _, _, _, _ in true },
            setMousePressure: { _, _, _ in }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1254))

        hostView.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, window: window))
        hostView.mouseDragged(
            with: try makeMouseEvent(
                type: .leftMouseDragged,
                window: window,
                location: NSPoint(x: 28, y: 36)
            )
        )

        XCTAssertEqual(mouseRecorder.events.count, 2)
        let lastMouseEvent = try XCTUnwrap(mouseRecorder.lastEvent)
        XCTAssertEqual(lastMouseEvent.x, 28, accuracy: 0.001)
        XCTAssertEqual(lastMouseEvent.y, 64, accuracy: 0.001)
    }

    func testUnhandledFocusedLeftMousePressStaysOwnedByTerminal() throws {
        let hostView = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        let mouseRecorder = GhosttyMousePositionRecorder()
        let mouseButtonRecorder = GhosttyMouseButtonRecorder()
        let pressureRecorder = GhosttyMousePressureRecorder()
        let nextResponder = MouseEventRecordingResponder()

        window.forcedIsKeyWindow = true
        window.contentView = contentView
        contentView.addSubview(hostView)
        hostView.nextResponder = nextResponder
        _ = window.makeFirstResponder(hostView)
        hostView.applicationIsActiveProvider = { true }
        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            sendMousePosition: { surface, x, y, mods in
                mouseRecorder.record(surface: surface, x: x, y: y, mods: mods)
            },
            sendMouseButton: { surface, state, button, mods in
                mouseButtonRecorder.record(
                    surface: surface,
                    state: state,
                    button: button,
                    mods: mods
                )
                return false
            },
            setMousePressure: { surface, stage, pressure in
                pressureRecorder.record(surface: surface, stage: stage, pressure: pressure)
            }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1261))

        hostView.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, window: window))
        hostView.mouseDragged(
            with: try makeMouseEvent(
                type: .leftMouseDragged,
                window: window,
                location: NSPoint(x: 30, y: 40)
            )
        )
        hostView.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, window: window))

        XCTAssertEqual(
            mouseButtonRecorder.events.map { "\($0.stateRawValue):\($0.buttonRawValue)" },
            [
                "\(GHOSTTY_MOUSE_PRESS.rawValue):\(GHOSTTY_MOUSE_LEFT.rawValue)",
                "\(GHOSTTY_MOUSE_RELEASE.rawValue):\(GHOSTTY_MOUSE_LEFT.rawValue)",
            ]
        )
        XCTAssertEqual(pressureRecorder.events.map(\.stage), [0])
        XCTAssertEqual(nextResponder.mouseDownCount, 0)
        XCTAssertEqual(nextResponder.mouseUpCount, 0)
        XCTAssertEqual(mouseRecorder.events.count, 3)
        let draggedPosition = mouseRecorder.events[1]
        XCTAssertEqual(draggedPosition.x, 30, accuracy: 0.001)
        XCTAssertEqual(draggedPosition.y, 60, accuracy: 0.001)
    }

    func testMouseMovedAfterForwardedLeftPressDoesNotSynthesizeRelease() throws {
        let hostView = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        let mouseButtonRecorder = GhosttyMouseButtonRecorder()
        let pressureRecorder = GhosttyMousePressureRecorder()

        window.forcedIsKeyWindow = true
        window.contentView = contentView
        contentView.addSubview(hostView)
        _ = window.makeFirstResponder(hostView)
        hostView.applicationIsActiveProvider = { true }
        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            sendMousePosition: { _, _, _, _ in },
            sendMouseButton: { surface, state, button, mods in
                mouseButtonRecorder.record(
                    surface: surface,
                    state: state,
                    button: button,
                    mods: mods
                )
                return true
            },
            setMousePressure: { surface, stage, pressure in
                pressureRecorder.record(surface: surface, stage: stage, pressure: pressure)
            }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1262))

        hostView.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, window: window))
        hostView.mouseMoved(
            with: try makeMouseEvent(
                type: .mouseMoved,
                window: window,
                location: NSPoint(x: 30, y: 40)
            )
        )

        XCTAssertEqual(
            mouseButtonRecorder.events.map { "\($0.stateRawValue):\($0.buttonRawValue)" },
            ["\(GHOSTTY_MOUSE_PRESS.rawValue):\(GHOSTTY_MOUSE_LEFT.rawValue)"]
        )
        XCTAssertTrue(pressureRecorder.events.isEmpty)
    }

    func testFocusLossAfterUnhandledRightPressStillForwardsLaterMouseUpToAppKit() throws {
        let hostView = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        let mouseButtonRecorder = GhosttyMouseButtonRecorder()
        let pressureRecorder = GhosttyMousePressureRecorder()
        let nextResponder = MouseEventRecordingResponder()

        window.forcedIsKeyWindow = true
        window.contentView = contentView
        contentView.addSubview(hostView)
        hostView.nextResponder = nextResponder
        _ = window.makeFirstResponder(hostView)
        hostView.applicationIsActiveProvider = { true }
        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            sendMousePosition: { _, _, _, _ in },
            sendMouseButton: { surface, state, button, mods in
                mouseButtonRecorder.record(
                    surface: surface,
                    state: state,
                    button: button,
                    mods: mods
                )
                return false
            },
            setMousePressure: { surface, stage, pressure in
                pressureRecorder.record(surface: surface, stage: stage, pressure: pressure)
            },
            isMouseCaptured: { _ in true }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1263))

        hostView.rightMouseDown(with: try makeMouseEvent(type: .rightMouseDown, window: window))
        _ = hostView.syncSurfaceFocus(false, reason: "test_focus_loss")
        hostView.rightMouseUp(with: try makeMouseEvent(type: .rightMouseUp, window: window))

        XCTAssertEqual(
            mouseButtonRecorder.events.map { "\($0.stateRawValue):\($0.buttonRawValue)" },
            [
                "\(GHOSTTY_MOUSE_PRESS.rawValue):\(GHOSTTY_MOUSE_RIGHT.rawValue)",
                "\(GHOSTTY_MOUSE_RELEASE.rawValue):\(GHOSTTY_MOUSE_RIGHT.rawValue)",
            ]
        )
        XCTAssertEqual(pressureRecorder.events.map(\.stage), [0])
        XCTAssertEqual(nextResponder.rightMouseUpCount, 1)
    }

    func testFocusLossReleasesForwardedLeftPress() throws {
        let hostView = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        let mouseButtonRecorder = GhosttyMouseButtonRecorder()
        let pressureRecorder = GhosttyMousePressureRecorder()

        window.forcedIsKeyWindow = true
        window.contentView = contentView
        contentView.addSubview(hostView)
        _ = window.makeFirstResponder(hostView)
        hostView.applicationIsActiveProvider = { true }
        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            sendMousePosition: { _, _, _, _ in },
            sendMouseButton: { surface, state, button, mods in
                mouseButtonRecorder.record(
                    surface: surface,
                    state: state,
                    button: button,
                    mods: mods
                )
                return true
            },
            setMousePressure: { surface, stage, pressure in
                pressureRecorder.record(surface: surface, stage: stage, pressure: pressure)
            }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1255))

        hostView.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, window: window))
        _ = hostView.syncSurfaceFocus(false, reason: "test_focus_loss")

        XCTAssertEqual(
            mouseButtonRecorder.events.map { "\($0.stateRawValue):\($0.buttonRawValue)" },
            [
                "\(GHOSTTY_MOUSE_PRESS.rawValue):\(GHOSTTY_MOUSE_LEFT.rawValue)",
                "\(GHOSTTY_MOUSE_RELEASE.rawValue):\(GHOSTTY_MOUSE_LEFT.rawValue)",
            ]
        )
        XCTAssertEqual(pressureRecorder.events.map(\.stage), [0])
    }

    func testFocusLossReleasesForwardedRightPressOnce() throws {
        let hostView = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        let mouseButtonRecorder = GhosttyMouseButtonRecorder()
        let pressureRecorder = GhosttyMousePressureRecorder()

        window.forcedIsKeyWindow = true
        window.contentView = contentView
        contentView.addSubview(hostView)
        _ = window.makeFirstResponder(hostView)
        hostView.applicationIsActiveProvider = { true }
        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            sendMousePosition: { _, _, _, _ in },
            sendMouseButton: { surface, state, button, mods in
                mouseButtonRecorder.record(
                    surface: surface,
                    state: state,
                    button: button,
                    mods: mods
                )
                return true
            },
            setMousePressure: { surface, stage, pressure in
                pressureRecorder.record(surface: surface, stage: stage, pressure: pressure)
            },
            isMouseCaptured: { _ in true }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1260))

        hostView.rightMouseDown(with: try makeMouseEvent(type: .rightMouseDown, window: window))
        _ = hostView.syncSurfaceFocus(false, reason: "test_focus_loss")
        hostView.rightMouseUp(with: try makeMouseEvent(type: .rightMouseUp, window: window))

        XCTAssertEqual(
            mouseButtonRecorder.events.map { "\($0.stateRawValue):\($0.buttonRawValue)" },
            [
                "\(GHOSTTY_MOUSE_PRESS.rawValue):\(GHOSTTY_MOUSE_RIGHT.rawValue)",
                "\(GHOSTTY_MOUSE_RELEASE.rawValue):\(GHOSTTY_MOUSE_RIGHT.rawValue)",
            ]
        )
        XCTAssertEqual(pressureRecorder.events.map(\.stage), [0])
    }

    func testFocusLossAfterFocusOnlyClickDoesNotSynthesizeRelease() throws {
        let hostView = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let otherHostView = TerminalHostView()
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        let mouseButtonRecorder = GhosttyMouseButtonRecorder()

        window.forcedIsKeyWindow = true
        window.contentView = contentView
        contentView.addSubview(otherHostView)
        contentView.addSubview(hostView)
        _ = window.makeFirstResponder(otherHostView)
        hostView.applicationIsActiveProvider = { true }
        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            sendMousePosition: { _, _, _, _ in },
            sendMouseButton: { surface, state, button, mods in
                mouseButtonRecorder.record(
                    surface: surface,
                    state: state,
                    button: button,
                    mods: mods
                )
                return true
            }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1256))

        hostView.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, window: window))
        _ = hostView.syncSurfaceFocus(false, reason: "test_focus_loss")

        XCTAssertTrue(mouseButtonRecorder.events.isEmpty)
    }

    func testSurfaceReplacementReleasesForwardedLeftPressAgainstOldSurface() throws {
        let hostView = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        let mouseButtonRecorder = GhosttyMouseButtonRecorder()
        let oldSurface = fakeSurfaceHandle(0x1257)
        let newSurface = fakeSurfaceHandle(0x1258)

        window.forcedIsKeyWindow = true
        window.contentView = contentView
        contentView.addSubview(hostView)
        _ = window.makeFirstResponder(hostView)
        hostView.applicationIsActiveProvider = { true }
        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            sendMousePosition: { _, _, _, _ in },
            sendMouseButton: { surface, state, button, mods in
                mouseButtonRecorder.record(
                    surface: surface,
                    state: state,
                    button: button,
                    mods: mods
                )
                return true
            },
            setMousePressure: { _, _, _ in }
        )
        hostView.setGhosttySurface(oldSurface)

        hostView.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, window: window))
        hostView.setGhosttySurface(newSurface)

        XCTAssertEqual(
            mouseButtonRecorder.events.map { "\($0.surfaceRawValue):\($0.stateRawValue)" },
            [
                "\(UInt(bitPattern: oldSurface)):\(GHOSTTY_MOUSE_PRESS.rawValue)",
                "\(UInt(bitPattern: oldSurface)):\(GHOSTTY_MOUSE_RELEASE.rawValue)",
            ]
        )
    }
}
#endif
