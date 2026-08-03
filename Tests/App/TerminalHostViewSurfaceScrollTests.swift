import AppKit
@testable import ToasttyApp
import XCTest

#if TOASTTY_HAS_GHOSTTY_KIT
import GhosttyKit

@MainActor
final class TerminalHostViewSurfaceScrollTests: TerminalHostViewTestCase {
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

    func testSurfaceScrollViewRestoresOverlayDuringLaterTilePass() {
        let scrollView = TerminalSurfaceScrollView()
        scrollView.frame = CGRect(x: 0, y: 0, width: 160, height: 200)
        scrollView.applyScrollbar(totalRows: 100, offsetRows: 70, visibleRows: 20)
        scrollView.applyCellHeightPoints(10)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        scrollView.scrollerStyle = .legacy
        scrollView.tile()

        XCTAssertEqual(scrollView.scrollerStyle, .overlay)
        XCTAssertEqual(scrollView.verticalScroller?.scrollerStyle, .overlay)
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
}
#endif
