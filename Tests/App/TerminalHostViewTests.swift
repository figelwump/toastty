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

    func testGhosttyTextPreservesBacktabForShiftTab() {
        let text = TerminalHostView.ghosttyText(
            eventType: .keyDown,
            keyCode: 48,
            modifierFlags: [.shift],
            characterProvider: { "\u{19}" },
            translatedCharacterProvider: { "\t" }
        )

        XCTAssertNil(text)
    }

    func testGhosttyTextPreservesBareTabAsText() {
        let text = TerminalHostView.ghosttyText(
            eventType: .keyDown,
            keyCode: 48,
            modifierFlags: [],
            characterProvider: { "\t" },
            translatedCharacterProvider: { "\t" }
        )

        XCTAssertEqual(text, "\t")
    }

    func testGhosttyTextSuppressesModifiedTabTextForControlTab() {
        let text = TerminalHostView.ghosttyText(
            eventType: .keyDown,
            keyCode: 48,
            modifierFlags: [.control],
            characterProvider: { "\t" },
            translatedCharacterProvider: { "\t" }
        )

        XCTAssertNil(text)
    }

    func testGhosttyTextNormalizesControlCharacterWhenNeeded() {
        let text = TerminalHostView.ghosttyText(
            eventType: .keyDown,
            keyCode: 8,
            modifierFlags: [.control],
            characterProvider: { "\u{03}" },
            translatedCharacterProvider: { "c" }
        )

        XCTAssertEqual(text, "c")
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

    func testSurfaceScrollViewUsesLinkCursorForMouseOverLinkFallback() {
        let hostView = TerminalHostView()
        let scrollView = TerminalSurfaceScrollView(terminalHostView: hostView)

        hostView.setGhosttyMouseShape(GHOSTTY_MOUSE_SHAPE_TEXT)
        hostView.setGhosttyMouseOverLink("https://example.com")

        XCTAssertTrue(scrollView.documentCursor === NSCursor.pointingHand)
    }

    func testSurfaceScrollViewRestoresBaseCursorWhenMouseOverLinkClears() {
        let hostView = TerminalHostView()
        let scrollView = TerminalSurfaceScrollView(terminalHostView: hostView)

        hostView.setGhosttyMouseShape(GHOSTTY_MOUSE_SHAPE_TEXT)
        hostView.setGhosttyMouseOverLink("https://example.com")
        hostView.setGhosttyMouseOverLink(nil)

        XCTAssertTrue(scrollView.documentCursor === NSCursor.iBeam)
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

    func testLocalInterruptKeyRecognizesEscape() {
        XCTAssertTrue(
            TerminalHostView.isLocalInterruptKey(
                keyCode: 53,
                modifierFlags: [],
                charactersIgnoringModifiers: nil
            )
        )
    }

    func testLocalInterruptKeyRecognizesControlC() {
        XCTAssertTrue(
            TerminalHostView.isLocalInterruptKey(
                keyCode: 8,
                modifierFlags: [.control],
                charactersIgnoringModifiers: "c"
            )
        )
    }

    func testLocalInterruptKeyIgnoresPlainC() {
        XCTAssertFalse(
            TerminalHostView.isLocalInterruptKey(
                keyCode: 8,
                modifierFlags: [],
                charactersIgnoringModifiers: "c"
            )
        )
    }

    func testLocalInterruptKeyIgnoresCommandC() {
        XCTAssertFalse(
            TerminalHostView.isLocalInterruptKey(
                keyCode: 8,
                modifierFlags: [.command],
                charactersIgnoringModifiers: "c"
            )
        )
    }

    func testVisibilityTraceSnapshotReportsTransparentAncestorWhileWindowAttached() {
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        let outer = NSView(frame: contentView.bounds)
        let inner = NSView(frame: outer.bounds)
        let hostView = TerminalHostView()
        window.forcedOcclusionState = [.visible]
        window.contentView = contentView
        outer.alphaValue = 0.4
        inner.alphaValue = 0

        contentView.addSubview(outer)
        outer.addSubview(inner)
        inner.addSubview(hostView)

        let snapshot = hostView.visibilityTraceSnapshot()

        XCTAssertTrue(snapshot.hasWindow)
        XCTAssertTrue(snapshot.windowVisible)
        XCTAssertEqual(snapshot.selfAlphaThousandths, 1_000)
        XCTAssertEqual(snapshot.minAncestorAlphaThousandths, 0)
        XCTAssertEqual(snapshot.minChainAlphaThousandths, 0)
        XCTAssertTrue(snapshot.visuallyTransparent)
        XCTAssertTrue(snapshot.logicallyVisibleIgnoringTransparency)
        XCTAssertFalse(snapshot.resolvedVisible)
    }

    func testVisibilityTraceSnapshotTreatsDetachedHostAsOpaqueChain() {
        let hostView = TerminalHostView()

        let snapshot = hostView.visibilityTraceSnapshot()

        XCTAssertEqual(snapshot.selfAlphaThousandths, 1_000)
        XCTAssertEqual(snapshot.minAncestorAlphaThousandths, 1_000)
        XCTAssertEqual(snapshot.minChainAlphaThousandths, 1_000)
        XCTAssertFalse(snapshot.visuallyTransparent)
        XCTAssertFalse(snapshot.resolvedVisible)
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

    func testPrimaryMouseDownActivationSkipsShiftClickSelection() {
        XCTAssertFalse(
            TerminalHostView.shouldActivatePanelForPrimaryMouseDown(modifierFlags: [.shift])
        )
        XCTAssertTrue(
            TerminalHostView.shouldActivatePanelForPrimaryMouseDown(modifierFlags: [.command])
        )
    }

    func testShiftMouseDownSkipsPanelActivationAndFocus() throws {
        let hostView = TerminalHostView()
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        var activationCount = 0

        window.contentView = contentView
        contentView.addSubview(hostView)
        hostView.activatePanelIfNeeded = {
            activationCount += 1
            return true
        }

        hostView.mouseDown(
            with: try makeMouseEvent(
                type: .leftMouseDown,
                window: window,
                modifierFlags: [.shift]
            )
        )

        XCTAssertEqual(activationCount, 0)
        XCTAssertNil(window.firstResponder)
        XCTAssertFalse(hostView.forwardsPrimaryMouseDrag)
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

    func testResetTrackedGhosttyModifiersForApplicationDeactivationSendsSyntheticControlRelease() throws {
        let hostView = TerminalHostView()
        let keyRecorder = GhosttyKeyEventRecorder()
        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            keyTranslationMods: { _, mods in mods },
            sendKey: { _, keyEvent in
                keyRecorder.record(keyEvent)
                return true
            }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1234))

        hostView.flagsChanged(
            with: try makeKeyEvent(
                type: .flagsChanged,
                keyCode: 0x3B,
                modifierFlags: [.control]
            )
        )

        let releasedCount = hostView.resetTrackedGhosttyModifiersForApplicationDeactivation()

        XCTAssertEqual(releasedCount, 1)
        XCTAssertEqual(
            keyRecorder.events.map(\.actionRawValue),
            [GHOSTTY_ACTION_PRESS.rawValue, GHOSTTY_ACTION_RELEASE.rawValue]
        )
        XCTAssertEqual(
            keyRecorder.events.map(\.keyCode),
            [UInt32(0x3B), UInt32(0x3B)]
        )
        XCTAssertEqual(keyRecorder.events.first?.modsRawValue, GHOSTTY_MODS_CTRL.rawValue)
        XCTAssertEqual(keyRecorder.events.last?.modsRawValue, GHOSTTY_MODS_NONE.rawValue)
    }

    func testResetTrackedGhosttyModifiersForApplicationDeactivationPreservesRemainingRightShiftState() throws {
        let hostView = TerminalHostView()
        let keyRecorder = GhosttyKeyEventRecorder()
        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            keyTranslationMods: { _, mods in mods },
            sendKey: { _, keyEvent in
                keyRecorder.record(keyEvent)
                return true
            }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1235))

        hostView.flagsChanged(
            with: try makeKeyEvent(
                type: .flagsChanged,
                keyCode: 0x3C,
                modifierFlags: NSEvent.ModifierFlags(
                    rawValue: NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICERSHIFTKEYMASK)
                )
            )
        )
        hostView.flagsChanged(
            with: try makeKeyEvent(
                type: .flagsChanged,
                keyCode: 0x3B,
                modifierFlags: NSEvent.ModifierFlags.shift.union(.control)
            )
        )

        let releasedCount = hostView.resetTrackedGhosttyModifiersForApplicationDeactivation()

        XCTAssertEqual(releasedCount, 2)
        let syntheticReleases = Array(keyRecorder.events.suffix(2))
        XCTAssertEqual(
            syntheticReleases.map(\.keyCode),
            [UInt32(0x3B), UInt32(0x3C)]
        )
        XCTAssertEqual(
            syntheticReleases.map(\.modsRawValue),
            [
                GHOSTTY_MODS_SHIFT.rawValue | GHOSTTY_MODS_SHIFT_RIGHT.rawValue,
                GHOSTTY_MODS_NONE.rawValue,
            ]
        )
    }

    func testSetGhosttySurfaceReplacementDrainsTrackedModifiersFromPreviousSurface() throws {
        let hostView = TerminalHostView()
        let keyRecorder = GhosttyKeyEventRecorder()
        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            keyTranslationMods: { _, mods in mods },
            sendKey: { _, keyEvent in
                keyRecorder.record(keyEvent)
                return true
            }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1237))
        hostView.flagsChanged(
            with: try makeKeyEvent(
                type: .flagsChanged,
                keyCode: 0x3B,
                modifierFlags: [.control]
            )
        )

        hostView.setGhosttySurface(fakeSurfaceHandle(0x1238))

        XCTAssertEqual(
            keyRecorder.events.map(\.actionRawValue),
            [GHOSTTY_ACTION_PRESS.rawValue, GHOSTTY_ACTION_RELEASE.rawValue]
        )
        XCTAssertEqual(
            keyRecorder.events.map(\.keyCode),
            [UInt32(0x3B), UInt32(0x3B)]
        )
        XCTAssertEqual(keyRecorder.events.last?.modsRawValue, GHOSTTY_MODS_NONE.rawValue)
        XCTAssertEqual(hostView.resetTrackedGhosttyModifiersForApplicationDeactivation(), 0)
    }

    func testResetTrackedGhosttyModifiersForApplicationDeactivationIsIdempotent() throws {
        let hostView = TerminalHostView()
        let keyRecorder = GhosttyKeyEventRecorder()
        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            keyTranslationMods: { _, mods in mods },
            sendKey: { _, keyEvent in
                keyRecorder.record(keyEvent)
                return true
            }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1236))
        hostView.flagsChanged(
            with: try makeKeyEvent(
                type: .flagsChanged,
                keyCode: 0x3B,
                modifierFlags: [.control]
            )
        )

        XCTAssertEqual(hostView.resetTrackedGhosttyModifiersForApplicationDeactivation(), 1)
        let eventCountAfterFirstReset = keyRecorder.events.count

        XCTAssertEqual(hostView.resetTrackedGhosttyModifiersForApplicationDeactivation(), 0)
        XCTAssertEqual(keyRecorder.events.count, eventCountAfterFirstReset)
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
    location: NSPoint = NSPoint(x: 12, y: 12),
    modifierFlags: NSEvent.ModifierFlags = []
) throws -> NSEvent {
    guard let event = NSEvent.mouseEvent(
        with: type,
        location: location,
        modifierFlags: modifierFlags,
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
    type: NSEvent.EventType,
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags,
    characters: String = "",
    charactersIgnoringModifiers: String = ""
) throws -> NSEvent {
    guard let event = NSEvent.keyEvent(
        with: type,
        location: .zero,
        modifierFlags: modifierFlags,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: charactersIgnoringModifiers,
        isARepeat: false,
        keyCode: keyCode
    ) else {
        throw NSError(domain: "TerminalHostViewTests", code: 2, userInfo: nil)
    }
    return event
}

private struct RecordedGhosttyKeyEvent: Equatable {
    let actionRawValue: UInt32
    let modsRawValue: UInt32
    let keyCode: UInt32
}

private final class GhosttyKeyEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RecordedGhosttyKeyEvent] = []

    func record(_ keyEvent: ghostty_input_key_s) {
        lock.lock()
        storage.append(
            RecordedGhosttyKeyEvent(
                actionRawValue: keyEvent.action.rawValue,
                modsRawValue: keyEvent.mods.rawValue,
                keyCode: keyEvent.keycode
            )
        )
        lock.unlock()
    }

    var events: [RecordedGhosttyKeyEvent] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return storage
    }
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
