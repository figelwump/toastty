import AppKit
@testable import ToasttyApp
import XCTest

#if TOASTTY_HAS_GHOSTTY_KIT
import GhosttyKit

final class GhosttyClipboardBridgeTests: XCTestCase {
    func testStandardClipboardUsesSystemPasteboard() {
        let pasteboard = GhosttyClipboardBridge.pasteboard(for: GHOSTTY_CLIPBOARD_STANDARD)

        XCTAssertEqual(pasteboard?.name, NSPasteboard.general.name)
    }

    func testSelectionClipboardUsesToasttyPrivatePasteboard() {
        let pasteboard = GhosttyClipboardBridge.pasteboard(for: GHOSTTY_CLIPBOARD_SELECTION)

        XCTAssertEqual(pasteboard?.name, GhosttyClipboardBridge.selectionPasteboardName)
        XCTAssertNotEqual(pasteboard?.name, NSPasteboard.general.name)
    }

    func testGhosttyRuntimeAdvertisesSelectionClipboardSupport() {
        XCTAssertTrue(GhosttyClipboardBridge.runtimeSupportsSelectionClipboard)
    }
}

@MainActor
final class TerminalHostViewTests: XCTestCase {
    func testFlagsChangedReturnsPressForLeftCommandPress() {
        let action = TerminalHostView.ghosttyModifierActionForFlagsChanged(
            keyCode: 0x37,
            modifierFlags: [.command]
        )

        XCTAssertEqual(action?.rawValue, GHOSTTY_ACTION_PRESS.rawValue)
    }

    func testFlagsChangedReturnsReleaseForRightCommandReleaseWhileLeftRemainsHeld() {
        let action = TerminalHostView.ghosttyModifierActionForFlagsChanged(
            keyCode: 0x36,
            modifierFlags: [.command]
        )

        XCTAssertEqual(action?.rawValue, GHOSTTY_ACTION_RELEASE.rawValue)
    }

    func testFlagsChangedReturnsPressForRightShiftPress() {
        let modifierFlags = NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICERSHIFTKEYMASK)
        )
        let action = TerminalHostView.ghosttyModifierActionForFlagsChanged(
            keyCode: 0x3C,
            modifierFlags: modifierFlags
        )

        XCTAssertEqual(action?.rawValue, GHOSTTY_ACTION_PRESS.rawValue)
    }

    func testFlagsChangedReturnsNilForNonModifierKeyCode() {
        let action = TerminalHostView.ghosttyModifierActionForFlagsChanged(
            keyCode: 0x24,
            modifierFlags: []
        )

        XCTAssertNil(action)
    }

    func testUnshiftedCodepointSkipsCharacterLookupForFlagsChangedEvents() {
        var providerWasCalled = false

        let codepoint = TerminalHostView.ghosttyUnshiftedCodepoint(eventType: .flagsChanged) {
            providerWasCalled = true
            return "x"
        }

        XCTAssertEqual(codepoint, 0)
        XCTAssertFalse(providerWasCalled)
    }

    func testUnshiftedCodepointUsesFirstScalarForKeyDownEvents() {
        let codepoint = TerminalHostView.ghosttyUnshiftedCodepoint(eventType: .keyDown) {
            "A"
        }

        XCTAssertEqual(codepoint, UnicodeScalar("A").value)
    }

    func testMouseShapeMapsPointerToLinkCursorStyle() {
        let cursorStyle = TerminalHostView.ghosttyMouseCursorStyle(for: GHOSTTY_MOUSE_SHAPE_POINTER)

        XCTAssertEqual(cursorStyle, .link)
    }

    func testMouseShapeMapsTextToHorizontalTextCursorStyle() {
        let cursorStyle = TerminalHostView.ghosttyMouseCursorStyle(for: GHOSTTY_MOUSE_SHAPE_TEXT)

        XCTAssertEqual(cursorStyle, .horizontalText)
    }

    func testMouseShapeReturnsNilForUnknownShape() {
        let cursorStyle = TerminalHostView.ghosttyMouseCursorStyle(
            for: ghostty_action_mouse_shape_e(rawValue: UInt32.max)
        )

        XCTAssertNil(cursorStyle)
    }

    func testSurfaceScrollViewAppliesGhosttyPointerCursorToDocumentCursor() {
        let hostView = TerminalHostView()
        let scrollView = TerminalSurfaceScrollView(terminalHostView: hostView)

        hostView.setGhosttyMouseShape(GHOSTTY_MOUSE_SHAPE_POINTER)

        XCTAssertTrue(scrollView.documentCursor === NSCursor.pointingHand)
    }

    func testSurfaceScrollViewAppliesGhosttyTextCursorToDocumentCursor() {
        let hostView = TerminalHostView()
        let scrollView = TerminalSurfaceScrollView(terminalHostView: hostView)

        hostView.setGhosttyMouseShape(GHOSTTY_MOUSE_SHAPE_TEXT)

        XCTAssertTrue(scrollView.documentCursor === NSCursor.iBeam)
    }

    func testSurfaceScrollViewTracksGhosttyCursorVisibility() {
        let hostView = TerminalHostView()
        let scrollView = TerminalSurfaceScrollView(terminalHostView: hostView)

        hostView.setGhosttyMouseVisibility(GHOSTTY_MOUSE_HIDDEN)
        XCTAssertFalse(scrollView.ghosttyCursorVisible)

        hostView.setGhosttyMouseVisibility(GHOSTTY_MOUSE_VISIBLE)
        XCTAssertTrue(scrollView.ghosttyCursorVisible)
    }

    func testSurfaceScrollViewDisablesNativeScrollbars() {
        let scrollView = TerminalSurfaceScrollView()

        XCTAssertFalse(scrollView.hasVerticalScroller)
        XCTAssertFalse(scrollView.hasHorizontalScroller)
    }

    func testSurfaceScrollViewKeepsDocumentViewSizedToClipViewBounds() {
        let scrollView = TerminalSurfaceScrollView()
        scrollView.frame = CGRect(x: 0, y: 0, width: 160, height: 90)
        scrollView.layoutSubtreeIfNeeded()

        XCTAssertEqual(scrollView.terminalHostView.frame.size, scrollView.contentView.bounds.size)
    }

    func testHostViewRequestsFirstResponderRestorationWhenAttachedToWindow() {
        let hostView = TerminalHostView()
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        var requestCount = 0

        window.contentView = contentView
        hostView.requestFirstResponderIfNeeded = {
            requestCount += 1
        }

        contentView.addSubview(hostView)

        XCTAssertEqual(requestCount, 1)
    }

    func testHostViewAcceptsFirstMouse() {
        let hostView = TerminalHostView()

        XCTAssertTrue(hostView.acceptsFirstMouse(for: nil))
    }

    func testHostViewConsumesCommandWThroughClosePanelShortcutHandler() throws {
        let hostView = TerminalHostView()
        var invocationCount = 0
        hostView.handleClosePanelShortcut = {
            invocationCount += 1
            return true
        }

        hostView.keyDown(with: try makeKeyEvent(characters: "w", modifiers: [.command], keyCode: 0x0D))

        XCTAssertEqual(invocationCount, 1)
    }

    func testClosePanelShortcutMatchesPlainCommandWOnly() throws {
        let matchingEvent = try makeKeyEvent(characters: "w", modifiers: [.command], keyCode: 0x0D)
        let shiftedEvent = try makeKeyEvent(characters: "W", modifiers: [.command, .shift], keyCode: 0x0D)
        let otherKeyEvent = try makeKeyEvent(characters: "q", modifiers: [.command], keyCode: 0x0C)

        XCTAssertTrue(TerminalHostView.isClosePanelShortcut(matchingEvent))
        XCTAssertFalse(TerminalHostView.isClosePanelShortcut(shiftedEvent))
        XCTAssertFalse(TerminalHostView.isClosePanelShortcut(otherKeyEvent))
    }

    func testClosePanelShortcutIgnoresRepeatedCommandW() throws {
        let repeatedEvent = try makeKeyEvent(
            characters: "w",
            modifiers: [.command],
            keyCode: 0x0D,
            isARepeat: true
        )

        XCTAssertFalse(TerminalHostView.isClosePanelShortcut(repeatedEvent))
    }

    func testMouseDownActivatesPanelBeforeFocusingHostView() throws {
        let hostView = TerminalHostView()
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        var activationCount = 0
        var firstResponderDuringActivation: NSResponder?

        window.contentView = contentView
        contentView.addSubview(hostView)
        hostView.activatePanelIfNeeded = {
            activationCount += 1
            firstResponderDuringActivation = window.firstResponder
            return true
        }

        hostView.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, window: window))

        XCTAssertEqual(activationCount, 1)
        XCTAssertNil(firstResponderDuringActivation)
        XCTAssertTrue(window.firstResponder === hostView)
    }

    func testRightMouseDownActivatesPanelBeforeFocusingHostView() throws {
        let hostView = TerminalHostView()
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        var activationCount = 0
        var firstResponderDuringActivation: NSResponder?

        window.contentView = contentView
        contentView.addSubview(hostView)
        hostView.activatePanelIfNeeded = {
            activationCount += 1
            firstResponderDuringActivation = window.firstResponder
            return true
        }

        hostView.rightMouseDown(with: try makeMouseEvent(type: .rightMouseDown, window: window))

        XCTAssertEqual(activationCount, 1)
        XCTAssertNil(firstResponderDuringActivation)
        XCTAssertTrue(window.firstResponder === hostView)
    }

    func testSynchronizePresentationVisibilityTracksHiddenAncestorTransition() {
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        let ancestor = NSView(frame: contentView.bounds)
        let hostView = TerminalHostView()
        window.forcedOcclusionState = [.visible]
        window.contentView = contentView
        ancestor.isHidden = true

        contentView.addSubview(ancestor)
        ancestor.addSubview(hostView)

        XCTAssertFalse(hostView.synchronizePresentationVisibility(reason: "test_hidden_ancestor"))
        XCTAssertFalse(hostView.isEffectivelyVisible)

        ancestor.isHidden = false

        XCTAssertTrue(hostView.synchronizePresentationVisibility(reason: "test_revealed_ancestor"))
        XCTAssertTrue(hostView.isEffectivelyVisible)
    }

    func testSynchronizePresentationVisibilityTracksWindowOcclusionTransition() {
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        let hostView = TerminalHostView()
        window.forcedOcclusionState = [.visible]
        window.contentView = contentView
        contentView.addSubview(hostView)

        XCTAssertTrue(hostView.synchronizePresentationVisibility(reason: "test_window_visible"))
        XCTAssertTrue(hostView.isEffectivelyVisible)

        window.forcedOcclusionState = []

        XCTAssertFalse(hostView.synchronizePresentationVisibility(reason: "test_window_hidden"))
        XCTAssertFalse(hostView.isEffectivelyVisible)
    }

    func testSynchronizePresentationVisibilityTreatsTransparentAncestorAsHidden() {
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        let ancestor = NSView(frame: contentView.bounds)
        let hostView = TerminalHostView()
        window.forcedOcclusionState = [.visible]
        window.contentView = contentView
        ancestor.alphaValue = 0

        contentView.addSubview(ancestor)
        ancestor.addSubview(hostView)

        XCTAssertFalse(hostView.synchronizePresentationVisibility(reason: "test_transparent_ancestor"))
        XCTAssertFalse(hostView.isEffectivelyVisible)

        ancestor.alphaValue = 1

        XCTAssertTrue(hostView.synchronizePresentationVisibility(reason: "test_opaque_ancestor"))
        XCTAssertTrue(hostView.isEffectivelyVisible)
    }

    func testResolvedGhosttySurfaceFocusStateRequiresActiveKeyFocusedHost() {
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        let hostView = TerminalHostView()
        hostView.applicationIsActiveProvider = { true }
        window.forcedOcclusionState = [.visible]
        window.forcedIsKeyWindow = true
        window.contentView = contentView

        contentView.addSubview(hostView)
        _ = hostView.synchronizePresentationVisibility(reason: "test_focus_visible")
        _ = window.makeFirstResponder(hostView)

        XCTAssertTrue(hostView.resolvedGhosttySurfaceFocusState())
    }

    func testResolvedGhosttySurfaceFocusStateReturnsFalseWhenApplicationInactive() {
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        let hostView = TerminalHostView()
        hostView.applicationIsActiveProvider = { false }
        window.forcedOcclusionState = [.visible]
        window.forcedIsKeyWindow = true
        window.contentView = contentView

        contentView.addSubview(hostView)
        _ = hostView.synchronizePresentationVisibility(reason: "test_focus_inactive")
        _ = window.makeFirstResponder(hostView)

        XCTAssertFalse(hostView.resolvedGhosttySurfaceFocusState())
    }

    func testSetGhosttySurfaceSkipsRepeatedAssignmentForSameSurface() {
        let hostView = TerminalHostView()
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        var requestCount = 0
        let focusHookCount = HookCallCounter()
        let occlusionHookCount = HookCallCounter()
        let refreshHookCount = HookCallCounter()
        let surface = fakeSurfaceHandle(0x1234)

        hostView.applicationIsActiveProvider = { true }
        hostView.requestFirstResponderIfNeeded = {
            requestCount += 1
        }
        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in
                focusHookCount.increment()
            },
            setOcclusion: { _, _ in
                occlusionHookCount.increment()
            },
            refresh: { _ in
                refreshHookCount.increment()
            }
        )
        window.forcedOcclusionState = [.visible]
        window.forcedIsKeyWindow = true
        window.contentView = contentView

        contentView.addSubview(hostView)
        _ = hostView.synchronizePresentationVisibility(reason: "test_surface_assignment_visible")
        _ = window.makeFirstResponder(hostView)
        requestCount = 0

        hostView.setGhosttySurface(surface)
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(focusHookCount.value, 1)
        XCTAssertEqual(occlusionHookCount.value, 1)
        XCTAssertEqual(refreshHookCount.value, 1)

        requestCount = 0
        hostView.setGhosttySurface(surface)
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(focusHookCount.value, 1)
        XCTAssertEqual(occlusionHookCount.value, 1)
        XCTAssertEqual(refreshHookCount.value, 1)
    }
}

private func fakeSurfaceHandle(_ rawValue: UInt) -> ghostty_surface_t {
    guard let surface = ghostty_surface_t(bitPattern: rawValue) else {
        fatalError("expected fake Ghostty surface handle")
    }
    return surface
}

private func makeMouseEvent(
    type: NSEvent.EventType,
    window: NSWindow,
    location: NSPoint = NSPoint(x: 12, y: 12)
) throws -> NSEvent {
    guard let event = NSEvent.mouseEvent(
        with: type,
        location: location,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
    ) else {
        throw NSError(domain: "TerminalHostViewTests", code: 1, userInfo: nil)
    }
    return event
}

private func makeKeyEvent(
    characters: String,
    modifiers: NSEvent.ModifierFlags,
    keyCode: UInt16,
    isARepeat: Bool = false
) throws -> NSEvent {
    guard let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: isARepeat,
        keyCode: keyCode
    ) else {
        throw NSError(domain: "TerminalHostViewTests", code: 2, userInfo: nil)
    }
    return event
}

private final class HookCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return storage
    }
}

private final class TestWindow: NSWindow {
    var forcedOcclusionState: NSWindow.OcclusionState = []
    var forcedIsKeyWindow = false
    private var storedFirstResponder: NSResponder?

    override var firstResponder: NSResponder? {
        storedFirstResponder
    }

    override var isKeyWindow: Bool {
        forcedIsKeyWindow
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
    }

    override var occlusionState: NSWindow.OcclusionState {
        forcedOcclusionState
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if let responder, responder.acceptsFirstResponder == false {
            return false
        }
        storedFirstResponder = responder
        return true
    }
}
#endif
