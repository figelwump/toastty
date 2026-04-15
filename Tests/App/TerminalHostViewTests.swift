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

    func testGhosttyLinkHoverModifierFlagsStripsShiftWhenCommandIsPressed() {
        let flags = NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.command.rawValue
                | NSEvent.ModifierFlags.shift.rawValue
                | UInt(NX_DEVICERSHIFTKEYMASK)
        )

        let normalized = TerminalHostView.ghosttyLinkHoverModifierFlags(for: flags)

        XCTAssertTrue(normalized.contains(.command))
        XCTAssertFalse(normalized.contains(.shift))
        XCTAssertEqual(normalized.rawValue & UInt(NX_DEVICERSHIFTKEYMASK), 0)
    }

    func testGhosttyLinkHoverModifierFlagsKeepsShiftWithoutCommand() {
        let flags = NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICERSHIFTKEYMASK)
        )

        let normalized = TerminalHostView.ghosttyLinkHoverModifierFlags(for: flags)

        XCTAssertEqual(normalized, flags)
    }

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

    func testMakeContextMenuIncludesSearchWithGoogleForSearchableSelection() {
        let hostView = TerminalHostView()

        let menu = hostView.makeContextMenu(
            copyEnabled: true,
            pasteEnabled: true,
            selectionText: "git status"
        )

        XCTAssertEqual(menu.items.map(\.title), ["Copy", "Paste", "Search with Google"])
        XCTAssertTrue(menu.items[2].target === hostView)
        XCTAssertEqual(menu.items[2].action, #selector(TerminalHostView.searchWithGoogle(_:)))
    }

    func testMakeContextMenuOmitsSearchWithGoogleForWhitespaceOnlySelection() {
        let hostView = TerminalHostView()

        let menu = hostView.makeContextMenu(
            copyEnabled: true,
            pasteEnabled: true,
            selectionText: " \n\t "
        )

        XCTAssertEqual(menu.items.map(\.title), ["Copy", "Paste"])
    }

    func testOpenGoogleSearchNormalizesSelectionWhitespace() {
        let hostView = TerminalHostView()
        var openedURL: URL?

        hostView.openSearchSelectionURL = { url in
            openedURL = url
            return true
        }

        let opened = hostView.openGoogleSearch(for: "  brew   upgrade\npeekaboo  ")

        XCTAssertTrue(opened)
        XCTAssertEqual(
            openedURL?.absoluteString,
            "https://www.google.com/search?q=brew%20upgrade%20peekaboo"
        )
    }

    func testOpenGoogleSearchSkipsWhitespaceOnlySelection() {
        let hostView = TerminalHostView()
        var openCallCount = 0

        hostView.openSearchSelectionURL = { _ in
            openCallCount += 1
            return true
        }

        let opened = hostView.openGoogleSearch(for: " \n ")

        XCTAssertFalse(opened)
        XCTAssertEqual(openCallCount, 0)
    }

    func testGoogleSearchURLReturnsNilForWhitespaceOnlySelection() {
        XCTAssertNil(TerminalHostView.googleSearchURL(for: "\n\t "))
    }

    func testSurfaceScrollViewDisablesNativeScrollbarsByDefault() {
        let scrollView = TerminalSurfaceScrollView()

        XCTAssertFalse(scrollView.hasVerticalScroller)
        XCTAssertFalse(scrollView.hasHorizontalScroller)
        XCTAssertTrue(scrollView.autohidesScrollers)
    }

    func testSurfaceScrollViewUsesOverlayScrollerStyleOnInit() {
        let scrollView = TerminalSurfaceScrollView()

        XCTAssertEqual(scrollView.scrollerStyle, .overlay)
    }

    func testSurfaceScrollViewUsesDarkAppearanceForDarkTerminalBackground() {
        let hostView = TerminalHostView()
        hostView.layer?.backgroundColor = NSColor.black.cgColor

        let scrollView = TerminalSurfaceScrollView(terminalHostView: hostView)

        XCTAssertEqual(scrollView.appearance?.bestMatch(from: [.darkAqua, .aqua]), .darkAqua)
    }

    func testSurfaceScrollViewUsesLightAppearanceForLightTerminalBackground() {
        let hostView = TerminalHostView()
        hostView.layer?.backgroundColor = NSColor.white.cgColor

        let scrollView = TerminalSurfaceScrollView(terminalHostView: hostView)

        XCTAssertEqual(scrollView.appearance?.bestMatch(from: [.darkAqua, .aqua]), .aqua)
    }

    func testSurfaceScrollViewRefreshesAppearanceWhenTerminalBackgroundChanges() {
        let hostView = TerminalHostView()
        let scrollView = TerminalSurfaceScrollView(terminalHostView: hostView)
        scrollView.frame = CGRect(x: 0, y: 0, width: 160, height: 90)
        scrollView.layoutSubtreeIfNeeded()

        hostView.layer?.backgroundColor = NSColor.white.cgColor
        scrollView.needsLayout = true
        scrollView.layoutSubtreeIfNeeded()

        XCTAssertEqual(scrollView.appearance?.bestMatch(from: [.darkAqua, .aqua]), .aqua)
    }

    func testSurfaceScrollViewKeepsOverlayScrollerStyleAfterWindowAttach() {
        // AppKit fires `preferredScrollerStyleDidChangeNotification` when a
        // scroll view moves into a window, and its own observer can reset
        // `scrollerStyle` to `.legacy` (the "recommended" style once any mouse
        // has been seen on the session). If Toastty's restoration loses the
        // observer-order race, the terminal shows a fat always-visible legacy
        // scrollbar. Guard against both the notification race and any direct
        // reset during `viewDidMoveToWindow`.
        let scrollView = TerminalSurfaceScrollView()
        scrollView.applyScrollbar(totalRows: 100, offsetRows: 70, visibleRows: 20)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView

        // Drain the runloop so any deferred `DispatchQueue.main.async` reassertion
        // and notification observers complete before we assert.
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(scrollView.scrollerStyle, .overlay)
        XCTAssertEqual(scrollView.verticalScroller?.scrollerStyle, .overlay)
    }

    func testSurfaceScrollViewRestoresOverlayWhenPreferredStyleNotificationFires() {
        // Simulate AppKit flipping the scroller style to `.legacy` and then
        // posting the preferred-style-change notification. The observer plus
        // the async follow-up must restore `.overlay` so the bar never lingers
        // in legacy style along this path either.
        let scrollView = TerminalSurfaceScrollView()
        scrollView.scrollerStyle = .legacy

        NotificationCenter.default.post(
            name: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(scrollView.scrollerStyle, .overlay)
    }

    func testSurfaceScrollViewKeepsResolvedAppearanceAfterPreferredStyleNotification() {
        let hostView = TerminalHostView()
        hostView.layer?.backgroundColor = NSColor.white.cgColor
        let scrollView = TerminalSurfaceScrollView(terminalHostView: hostView)
        scrollView.scrollerStyle = .legacy

        NotificationCenter.default.post(
            name: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(scrollView.scrollerStyle, .overlay)
        XCTAssertEqual(scrollView.appearance?.bestMatch(from: [.darkAqua, .aqua]), .aqua)
    }

    func testSurfaceScrollViewKeepsHostViewSizedToClipViewBounds() {
        let scrollView = TerminalSurfaceScrollView()
        scrollView.frame = CGRect(x: 0, y: 0, width: 160, height: 90)
        scrollView.layoutSubtreeIfNeeded()

        XCTAssertEqual(scrollView.terminalHostView.frame.size, scrollView.contentView.bounds.size)
    }

    func testSurfaceScrollViewShowsVerticalScrollerWhenScrollbackExists() {
        let scrollView = TerminalSurfaceScrollView()

        scrollView.applyScrollbar(totalRows: 100, offsetRows: 70, visibleRows: 20)

        XCTAssertTrue(scrollView.hasVerticalScroller)
        XCTAssertFalse(scrollView.hasHorizontalScroller)
        XCTAssertTrue(scrollView.autohidesScrollers)
    }

    func testSurfaceScrollViewHidesVerticalScrollerWhenScrollbarStateClears() {
        let scrollView = TerminalSurfaceScrollView()

        scrollView.applyScrollbar(totalRows: 100, offsetRows: 70, visibleRows: 20)
        scrollView.clearScrollbarState()

        XCTAssertFalse(scrollView.hasVerticalScroller)
    }

    func testSurfaceScrollViewSizesDocumentAndViewportFromScrollbarState() {
        let scrollView = TerminalSurfaceScrollView()
        scrollView.frame = CGRect(x: 0, y: 0, width: 160, height: 200)
        scrollView.applyScrollbar(totalRows: 100, offsetRows: 40, visibleRows: 20)
        scrollView.applyCellHeightPoints(10)
        scrollView.layoutSubtreeIfNeeded()

        XCTAssertEqual(Double(scrollView.documentView?.frame.height ?? 0), 1_000, accuracy: 0.001)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 400, accuracy: 0.001)
        XCTAssertEqual(scrollView.terminalHostView.frame.origin.y, 400, accuracy: 0.001)
    }

    func testSurfaceScrollViewSupportsFractionalCellHeights() {
        let scrollView = TerminalSurfaceScrollView()
        scrollView.frame = CGRect(x: 0, y: 0, width: 160, height: 210)
        scrollView.applyScrollbar(totalRows: 100, offsetRows: 40, visibleRows: 20)
        scrollView.applyCellHeightPoints(10.5)
        scrollView.layoutSubtreeIfNeeded()

        XCTAssertEqual(Double(scrollView.documentView?.frame.height ?? 0), 1_050, accuracy: 0.001)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 420, accuracy: 0.001)
        XCTAssertEqual(scrollView.terminalHostView.frame.origin.y, 420, accuracy: 0.001)
    }

    func testSurfaceScrollViewLiveScrollSendsScrollToRowRequest() {
        let scrollView = TerminalSurfaceScrollView()
        scrollView.frame = CGRect(x: 0, y: 0, width: 160, height: 200)
        scrollView.applyScrollbar(totalRows: 100, offsetRows: 40, visibleRows: 20)
        scrollView.applyCellHeightPoints(10)
        scrollView.layoutSubtreeIfNeeded()

        var receivedRow: Int?
        scrollView.requestScrollToRow = { row in
            receivedRow = row
            return true
        }

        scrollView.setLiveScrollingForTesting(true)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: 500))
        scrollView.performLiveScrollWritebackForTesting()

        XCTAssertEqual(receivedRow, 30)
    }

    func testSurfaceScrollViewSuppressesProgrammaticSyncDuringLiveScroll() {
        let scrollView = TerminalSurfaceScrollView()
        scrollView.frame = CGRect(x: 0, y: 0, width: 160, height: 200)
        scrollView.applyScrollbar(totalRows: 100, offsetRows: 40, visibleRows: 20)
        scrollView.applyCellHeightPoints(10)
        scrollView.layoutSubtreeIfNeeded()

        scrollView.setLiveScrollingForTesting(true)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: 500))
        scrollView.applyScrollbar(totalRows: 100, offsetRows: 20, visibleRows: 20)

        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 500, accuracy: 0.001)
        XCTAssertEqual(scrollView.terminalHostView.frame.origin.y, 500, accuracy: 0.001)
    }

    func testSurfaceScrollViewResumesProgrammaticSyncAfterLiveScrollEnds() {
        let scrollView = TerminalSurfaceScrollView()
        scrollView.frame = CGRect(x: 0, y: 0, width: 160, height: 200)
        scrollView.applyScrollbar(totalRows: 100, offsetRows: 40, visibleRows: 20)
        scrollView.applyCellHeightPoints(10)
        scrollView.layoutSubtreeIfNeeded()

        scrollView.setLiveScrollingForTesting(true)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: 500))
        scrollView.applyScrollbar(totalRows: 100, offsetRows: 20, visibleRows: 20)
        scrollView.setLiveScrollingForTesting(false)
        scrollView.layoutSubtreeIfNeeded()

        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 600, accuracy: 0.001)
        XCTAssertEqual(scrollView.terminalHostView.frame.origin.y, 600, accuracy: 0.001)
    }

    func testSurfaceScrollViewSkipsReflectingUnchangedMetricsDuringLayout() {
        let scrollView = TerminalSurfaceScrollView()
        scrollView.frame = CGRect(x: 0, y: 0, width: 160, height: 200)
        scrollView.applyScrollbar(totalRows: 100, offsetRows: 40, visibleRows: 20)
        scrollView.applyCellHeightPoints(10)
        scrollView.layoutSubtreeIfNeeded()

        let baselineReflectCount = scrollView.reflectScrolledClipViewCount

        scrollView.layout()

        XCTAssertEqual(scrollView.reflectScrolledClipViewCount, baselineReflectCount)
    }

    func testSurfaceScrollViewSkipsReflectingUnchangedMetricsDuringTile() {
        let scrollView = TerminalSurfaceScrollView()
        scrollView.frame = CGRect(x: 0, y: 0, width: 160, height: 200)
        scrollView.applyScrollbar(totalRows: 100, offsetRows: 40, visibleRows: 20)
        scrollView.applyCellHeightPoints(10)
        scrollView.layoutSubtreeIfNeeded()

        let baselineReflectCount = scrollView.reflectScrolledClipViewCount

        scrollView.tile()

        XCTAssertEqual(scrollView.reflectScrolledClipViewCount, baselineReflectCount)
    }

    func testSurfaceScrollViewReflectsWhenScrollbarStateChanges() {
        let scrollView = TerminalSurfaceScrollView()
        scrollView.frame = CGRect(x: 0, y: 0, width: 160, height: 200)
        scrollView.applyScrollbar(totalRows: 100, offsetRows: 40, visibleRows: 20)
        scrollView.applyCellHeightPoints(10)
        scrollView.layoutSubtreeIfNeeded()

        let baselineReflectCount = scrollView.reflectScrolledClipViewCount

        scrollView.applyScrollbar(totalRows: 20, offsetRows: 0, visibleRows: 20)

        XCTAssertGreaterThan(scrollView.reflectScrolledClipViewCount, baselineReflectCount)
    }

    func testSurfaceScrollViewKeepsDraggedOffsetUntilScrollbarFeedbackArrives() {
        let scrollView = TerminalSurfaceScrollView()
        scrollView.frame = CGRect(x: 0, y: 0, width: 160, height: 200)
        scrollView.applyScrollbar(totalRows: 100, offsetRows: 40, visibleRows: 20)
        scrollView.applyCellHeightPoints(10)
        scrollView.layoutSubtreeIfNeeded()

        var receivedRow: Int?
        scrollView.requestScrollToRow = { row in
            receivedRow = row
            return true
        }

        scrollView.setLiveScrollingForTesting(true)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: 500))
        scrollView.performLiveScrollWritebackForTesting()
        scrollView.setLiveScrollingForTesting(false)
        scrollView.layoutSubtreeIfNeeded()

        XCTAssertEqual(receivedRow, 30)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 500, accuracy: 0.001)
        XCTAssertEqual(scrollView.terminalHostView.frame.origin.y, 500, accuracy: 0.001)

        scrollView.applyScrollbar(totalRows: 100, offsetRows: 30, visibleRows: 20)

        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 500, accuracy: 0.001)
        XCTAssertEqual(scrollView.terminalHostView.frame.origin.y, 500, accuracy: 0.001)
    }

    func testHostViewForwardsGhosttyScrollbarUpdatesToEnclosingScrollView() {
        let hostView = TerminalHostView()
        let scrollView = TerminalSurfaceScrollView(terminalHostView: hostView)
        scrollView.frame = CGRect(x: 0, y: 0, width: 160, height: 200)
        scrollView.applyCellHeightPoints(10)
        scrollView.layoutSubtreeIfNeeded()

        hostView.setGhosttyScrollbar(totalRows: 100, offsetRows: 40, visibleRows: 20)

        XCTAssertTrue(scrollView.hasVerticalScroller)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 400, accuracy: 0.001)
        XCTAssertEqual(scrollView.terminalHostView.frame.origin.y, 400, accuracy: 0.001)
    }

    func testGhosttyRuntimeManagerRoutesScrollbarActionToAssociatedHostView() {
        let hostView = TerminalHostView()
        let scrollView = TerminalSurfaceScrollView(terminalHostView: hostView)
        scrollView.frame = CGRect(x: 0, y: 0, width: 160, height: 200)
        scrollView.applyCellHeightPoints(10)
        scrollView.layoutSubtreeIfNeeded()

        let manager = GhosttyRuntimeManager.shared
        let surfaceHandle = UInt(0xFEEDF00D)
        manager.associateHostViewForTesting(hostView, surfaceHandle: surfaceHandle)
        defer {
            manager.removeHostViewAssociationForTesting(hostView, surfaceHandle: surfaceHandle)
        }

        let handled = manager.dispatchScrollbarDirectHostViewActionForTesting(
            surfaceHandle: surfaceHandle,
            totalRows: 100,
            offsetRows: 40,
            visibleRows: 20
        )

        XCTAssertTrue(handled)
        XCTAssertTrue(scrollView.hasVerticalScroller)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 400, accuracy: 0.001)
        XCTAssertEqual(scrollView.terminalHostView.frame.origin.y, 400, accuracy: 0.001)
    }

    func testSurfaceScrollViewClearScrollbarStateRestoresDocumentHeightToContentHeight() {
        let scrollView = TerminalSurfaceScrollView()
        scrollView.frame = CGRect(x: 0, y: 0, width: 160, height: 200)
        scrollView.applyScrollbar(totalRows: 100, offsetRows: 40, visibleRows: 20)
        scrollView.applyCellHeightPoints(10)
        scrollView.layoutSubtreeIfNeeded()

        scrollView.clearScrollbarState()

        XCTAssertFalse(scrollView.hasVerticalScroller)
        XCTAssertEqual(scrollView.documentView?.frame.height ?? 0, 200, accuracy: 0.001)
        XCTAssertEqual(scrollView.terminalHostView.frame.origin.y, 0, accuracy: 0.001)
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
                DispatchQueue.main.async {
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

    func testMouseExitStillClearsHoveredLinkAfterSyntheticHoverRefresh() throws {
        let hostView = TerminalHostView()
        let scrollView = TerminalSurfaceScrollView(terminalHostView: hostView)
        let window = TestWindow()
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
        window.contentView = scrollView
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
                modifierFlags: [.command]
            )
        )
        hostView.mouseDragged(
            with: try makeMouseEvent(
                type: .leftMouseDragged,
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

    func testSetMarkedTextSyncsGhosttyPreeditImmediately() {
        let hostView = TerminalHostView()
        let preeditRecorder = GhosttyPreeditRecorder()
        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            setPreedit: { _, text, length in
                preeditRecorder.record(text, length: length)
            }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1240))

        hostView.setMarkedText(
            "你好",
            selectedRange: NSRange(location: 0, length: 2),
            replacementRange: NSRange()
        )

        XCTAssertTrue(hostView.hasMarkedText())
        XCTAssertEqual(hostView.markedRange(), NSRange(location: 0, length: 2))
        XCTAssertEqual(preeditRecorder.values, ["你好"])
    }

    func testInsertTextSendsCommittedTextAndClearsPreedit() {
        let hostView = TerminalHostView()
        let preeditRecorder = GhosttyPreeditRecorder()
        let textRecorder = GhosttyTextRecorder()
        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            setPreedit: { _, text, length in
                preeditRecorder.record(text, length: length)
            },
            sendText: { _, text, length in
                textRecorder.record(text, length: length)
            }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1241))
        hostView.setMarkedText(
            "你好",
            selectedRange: NSRange(location: 0, length: 2),
            replacementRange: NSRange()
        )

        hostView.insertText("你", replacementRange: NSRange())

        XCTAssertFalse(hostView.hasMarkedText())
        XCTAssertEqual(textRecorder.values, ["你"])
        XCTAssertEqual(preeditRecorder.values, ["你好", nil])
    }

    func testFlagsChangedIgnoresModifierTransitionsDuringMarkedTextComposition() throws {
        let hostView = TerminalHostView()
        let keyRecorder = GhosttyKeyEventRecorder()
        hostView.ghosttySurfaceHooks = .init(
            setFocus: { _, _ in },
            setOcclusion: { _, _ in },
            refresh: { _ in },
            sendKey: { _, keyEvent in
                keyRecorder.record(keyEvent)
                return true
            },
            setPreedit: { _, _, _ in }
        )
        hostView.setGhosttySurface(fakeSurfaceHandle(0x1242))
        hostView.setMarkedText(
            "n",
            selectedRange: NSRange(location: 0, length: 1),
            replacementRange: NSRange()
        )

        hostView.flagsChanged(
            with: try makeKeyEvent(
                type: .flagsChanged,
                keyCode: 0x3B,
                modifierFlags: [.control]
            )
        )

        XCTAssertTrue(keyRecorder.events.isEmpty)
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

@MainActor
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
    let text: String?
    let composing: Bool
}

private struct RecordedGhosttyMousePosition: Equatable {
    let x: Double
    let y: Double
    let modsRawValue: UInt32
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
                keyCode: keyEvent.keycode,
                text: keyEvent.text.flatMap { String(cString: $0) },
                composing: keyEvent.composing
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

private final class GhosttyMousePositionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RecordedGhosttyMousePosition] = []

    func record(x: Double, y: Double, mods: ghostty_input_mods_e) {
        lock.lock()
        storage.append(
            RecordedGhosttyMousePosition(
                x: x,
                y: y,
                modsRawValue: mods.rawValue
            )
        )
        lock.unlock()
    }

    var lastEvent: RecordedGhosttyMousePosition? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return storage.last
    }
}

private final class SendableBooleanBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool) {
        self.value = value
    }

    func takeIfTrue() -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard value else {
            return false
        }
        value = false
        return true
    }
}

private final class GhosttyPreeditRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String?] = []

    func record(_ text: UnsafePointer<CChar>?, length: uintptr_t) {
        lock.lock()
        if let text {
            let bytePointer = UnsafeRawPointer(text).assumingMemoryBound(to: UInt8.self)
            let buffer = UnsafeBufferPointer(start: bytePointer, count: Int(length))
            storage.append(String(decoding: buffer, as: UTF8.self))
        } else {
            storage.append(nil)
        }
        lock.unlock()
    }

    var values: [String?] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return storage
    }
}

private final class GhosttyTextRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ text: UnsafePointer<CChar>, length: uintptr_t) {
        lock.lock()
        let bytePointer = UnsafeRawPointer(text).assumingMemoryBound(to: UInt8.self)
        let buffer = UnsafeBufferPointer(start: bytePointer, count: Int(length))
        storage.append(String(decoding: buffer, as: UTF8.self))
        lock.unlock()
    }

    var values: [String] {
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
    var forcedMouseLocationOutsideOfEventStream = NSPoint.zero
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

    override var mouseLocationOutsideOfEventStream: NSPoint {
        forcedMouseLocationOutsideOfEventStream
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
