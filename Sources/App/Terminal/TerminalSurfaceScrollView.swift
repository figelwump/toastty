import AppKit
#if TOASTTY_HAS_GHOSTTY_KIT
import GhosttyKit

/// Owns AppKit cursor presentation for a live terminal surface while keeping
/// the Ghostty render/input view positioned inside a dedicated document view.
/// AppKit owns the scrollbar presentation while Ghostty remains the source of
/// truth for scrollback state and wheel input.
final class TerminalSurfaceScrollView: NSScrollView {
    private struct ScrollbarState: Equatable {
        let totalRows: Int
        let offsetRows: Int
        let visibleRows: Int

        var isScrollable: Bool {
            totalRows > visibleRows
        }
    }

    let terminalHostView: TerminalHostView
    private let scrollDocumentView: NSView
    private(set) var ghosttyCursorVisible = true
    private var scrollbarState: ScrollbarState?
    private var cellHeightPoints: CGFloat = 0
    private var isLiveScrolling = false
    private var isRestoringOverlayScrollerStyle = false
    private var lastSentRow: Int?
    private var pendingRequestedRow: Int?
    var requestScrollToRow: ((Int) -> Bool)?
    #if DEBUG
    private(set) var reflectScrolledClipViewCount = 0
    #endif

    init(terminalHostView: TerminalHostView = TerminalHostView()) {
        self.terminalHostView = terminalHostView
        scrollDocumentView = NSView(frame: .zero)
        super.init(frame: .zero)

        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = false
        hasHorizontalScroller = false
        autohidesScrollers = true
        usesPredominantAxisScrolling = true
        scrollerStyle = .overlay
        contentView.clipsToBounds = false
        documentView = scrollDocumentView
        scrollDocumentView.addSubview(terminalHostView)
        contentView.postsBoundsChangedNotifications = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: contentView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(willStartLiveScroll(_:)),
            name: NSScrollView.willStartLiveScrollNotification,
            object: self
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didEndLiveScroll(_:)),
            name: NSScrollView.didEndLiveScrollNotification,
            object: self
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didLiveScroll(_:)),
            name: NSScrollView.didLiveScrollNotification,
            object: self
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferredScrollerStyleDidChange(_:)),
            name: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil
        )

        synchronizeAppearance()
        synchronizeScrollMetrics()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        synchronizeAppearance()
        synchronizeScrollMetrics()
        syncHostViewFrame()
    }

    override func tile() {
        super.tile()
        synchronizeAppearance()
        synchronizeScrollMetrics()
        syncHostViewFrame()
        restoreOverlayScrollerStyleIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            isLiveScrolling = false
        }
        // AppKit resets `scrollerStyle` back to the window-context "recommended"
        // style (often `.legacy` when any mouse has been seen on the session)
        // inside the `preferredScrollerStyleDidChangeNotification` dispatch that
        // fires on window attach. Reassert here as a belt-and-suspenders in
        // addition to the notification observer so the scroller never lingers
        // in legacy style along any path.
        reassertOverlayScrollerStyle(asyncPasses: 2)
        terminalHostView.syncGhosttyCursorOwner()
    }

    override func scrollWheel(with event: NSEvent) {
        terminalHostView.scrollWheel(with: event)
    }

    func applyGhosttyCursor(
        style: TerminalHostView.GhosttyMouseCursorStyle,
        visible: Bool
    ) {
        ghosttyCursorVisible = visible
        documentCursor = style.nsCursor
        // Match Ghostty's native macOS host behavior for mouse-hide-while-typing.
        NSCursor.setHiddenUntilMouseMoves(!visible)
    }

    func applyCellHeightPoints(_ cellHeightPoints: CGFloat?) {
        let nextCellHeightPoints = max(cellHeightPoints ?? 0, 0)
        guard abs(self.cellHeightPoints - nextCellHeightPoints) > 0.001 else {
            return
        }
        self.cellHeightPoints = nextCellHeightPoints
        synchronizeScrollMetrics()
        syncHostViewFrame()
    }

    func applyScrollbar(totalRows: Int, offsetRows: Int, visibleRows: Int) {
        let previousOffsetRows = scrollbarState?.offsetRows
        let nextState = ScrollbarState(
            totalRows: totalRows,
            offsetRows: offsetRows,
            visibleRows: visibleRows
        )
        guard scrollbarState != nextState else { return }
        scrollbarState = nextState
        if let pendingRequestedRow,
           nextState.offsetRows == pendingRequestedRow || nextState.offsetRows != previousOffsetRows {
            self.pendingRequestedRow = nil
        }
        synchronizeScrollMetrics()
        syncHostViewFrame()
    }

    func clearScrollbarState() {
        guard scrollbarState != nil || hasVerticalScroller else { return }
        scrollbarState = nil
        lastSentRow = nil
        pendingRequestedRow = nil
        isLiveScrolling = false
        synchronizeScrollMetrics()
        if contentView.bounds.origin != .zero {
            contentView.scroll(to: .zero)
            reflectScrolledClipView(contentView)
        }
        syncHostViewFrame()
    }

    @objc
    private func clipViewBoundsDidChange(_ notification: Notification) {
        _ = notification
        syncHostViewFrame()
    }

    @objc
    private func willStartLiveScroll(_ notification: Notification) {
        _ = notification
        isLiveScrolling = true
    }

    @objc
    private func didEndLiveScroll(_ notification: Notification) {
        _ = notification
        isLiveScrolling = false
        guard pendingRequestedRow == nil else {
            reflectScrolledClipView(contentView)
            syncHostViewFrame()
            return
        }
        synchronizeScrollMetrics()
        syncHostViewFrame()
    }

    @objc
    private func didLiveScroll(_ notification: Notification) {
        _ = notification
        handleLiveScroll()
    }

    @objc
    private func preferredScrollerStyleDidChange(_ notification: Notification) {
        _ = notification
        // Reassert synchronously for the current notification dispatch, then
        // again across follow-up main-queue turns so we also win the race
        // against AppKit's own observers and any extra pass triggered after
        // the scroller appearance changes.
        // (`+[NSScrollerImpPair _updateAllScrollerImpPairsForNewRecommendedScrollerStyle:]`)
        // which can otherwise fire last and leave the scroller in `.legacy`.
        reassertOverlayScrollerStyle(asyncPasses: 2)
    }

    private func synchronizeAppearance() {
        let nextAppearanceName = Self.scrollerAppearanceName(
            for: terminalHostView.layer.flatMap(\.backgroundColor).flatMap(NSColor.init(cgColor:))
        )
        let currentAppearanceName = appearance?.bestMatch(from: [.darkAqua, .aqua])
        guard currentAppearanceName != nextAppearanceName else {
            return
        }

        let nextAppearance = NSAppearance(named: nextAppearanceName)
        appearance = nextAppearance
        // Match Ghostty's host behavior and refresh hover tracking after the
        // scroller appearance flips so AppKit's cursor regions stay in sync.
        updateTrackingAreas()
    }

    private func reassertOverlayScrollerStyle(asyncPasses: Int) {
        restoreOverlayScrollerStyleIfNeeded()
        guard asyncPasses > 0 else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            // Some AppKit paths still schedule a later scroller-style reset
            // after window attach or preferred-style notifications once the
            // appearance-backed scroller state settles. Keep the extra passes
            // bounded to these low-frequency lifecycle hooks.
            self?.reassertOverlayScrollerStyle(asyncPasses: asyncPasses - 1)
        }
    }

    private func synchronizeScrollMetrics() {
        var shouldReflect = false
        let contentBounds = contentView.bounds
        let desiredDocumentSize = CGSize(
            width: contentBounds.width,
            height: documentHeight(contentHeight: contentBounds.height)
        )
        if setScrollDocumentViewSizeIfNeeded(desiredDocumentSize) {
            shouldReflect = true
        }
        if setVerticalScrollerVisibilityIfNeeded(scrollbarState?.isScrollable ?? false) {
            shouldReflect = true
        }

        guard isLiveScrolling == false,
              pendingRequestedRow == nil,
              let scrollbarState,
              cellHeightPoints > 0 else {
            reflectScrolledClipViewIfNeeded(shouldReflect)
            return
        }

        let desiredOffsetY = contentOffsetY(for: scrollbarState)
        let currentOriginY = contentView.bounds.origin.y
        if abs(currentOriginY - desiredOffsetY) > 0.5 {
            contentView.scroll(to: CGPoint(x: 0, y: desiredOffsetY))
            shouldReflect = true
        }
        lastSentRow = scrollbarState.offsetRows
        reflectScrolledClipViewIfNeeded(shouldReflect)
    }

    private func syncHostViewFrame() {
        let visibleRect = contentView.documentVisibleRect
        let size = contentView.bounds.size
        let nextFrame = CGRect(origin: visibleRect.origin, size: size)
        guard terminalHostView.frame != nextFrame else {
            return
        }
        terminalHostView.frame = nextFrame
    }

    private func handleLiveScroll() {
        guard isLiveScrolling,
              let scrollbarState,
              cellHeightPoints > 0,
              scrollbarState.isScrollable else {
            return
        }

        let visibleRect = contentView.documentVisibleRect
        let documentHeight = scrollDocumentView.frame.height
        let scrollOffset = max(documentHeight - visibleRect.origin.y - visibleRect.height, 0)
        let rawRow = Int((scrollOffset / cellHeightPoints).rounded(.down))
        let maxOffsetRows = max(scrollbarState.totalRows - scrollbarState.visibleRows, 0)
        let row = min(max(rawRow, 0), maxOffsetRows)
        guard row != lastSentRow else {
            return
        }
        guard requestScrollToRow?(row) == true else {
            return
        }
        pendingRequestedRow = row
        lastSentRow = row
    }

    private func documentHeight(contentHeight: CGFloat) -> CGFloat {
        guard let scrollbarState,
              cellHeightPoints > 0 else {
            return max(contentHeight, 1)
        }
        let documentGridHeight = CGFloat(scrollbarState.totalRows) * cellHeightPoints
        let padding = contentHeight - (CGFloat(scrollbarState.visibleRows) * cellHeightPoints)
        return max(contentHeight, documentGridHeight + padding)
    }

    private func contentOffsetY(for scrollbarState: ScrollbarState) -> CGFloat {
        guard cellHeightPoints > 0 else { return 0 }
        let remainingRows = max(scrollbarState.totalRows - scrollbarState.offsetRows - scrollbarState.visibleRows, 0)
        return CGFloat(remainingRows) * cellHeightPoints
    }

    private func setScrollDocumentViewSizeIfNeeded(_ size: CGSize) -> Bool {
        guard abs(scrollDocumentView.frame.width - size.width) > 0.001 ||
                abs(scrollDocumentView.frame.height - size.height) > 0.001 else {
            return false
        }

        var nextFrame = scrollDocumentView.frame
        nextFrame.size = size
        scrollDocumentView.frame = nextFrame
        return true
    }

    private func setVerticalScrollerVisibilityIfNeeded(_ visible: Bool) -> Bool {
        guard hasVerticalScroller != visible else {
            return false
        }
        hasVerticalScroller = visible
        return true
    }

    private func reflectScrolledClipViewIfNeeded(_ shouldReflect: Bool) {
        guard shouldReflect else {
            return
        }

        // Avoid redundant reflections on no-op layout/tile passes because AppKit
        // can re-show overlay scrollers when we keep reasserting unchanged metrics.
        reflectScrolledClipView(contentView)
        #if DEBUG
        reflectScrolledClipViewCount += 1
        #endif
    }

    // Match Ghostty's host-side luminance heuristic so standalone Ghostty and
    // Toastty choose the same Aqua variant for native overlay scrollers.
    static func scrollerAppearanceName(for backgroundColor: NSColor?) -> NSAppearance.Name {
        let fallbackColor = backgroundColor ?? .black
        guard let rgb = fallbackColor.usingColorSpace(.sRGB) else {
            return .darkAqua
        }

        let luminance = (0.299 * rgb.redComponent) + (0.587 * rgb.greenComponent) + (0.114 * rgb.blueComponent)
        return luminance > 0.5 ? .aqua : .darkAqua
    }

    private func restoreOverlayScrollerStyleIfNeeded() {
        guard isRestoringOverlayScrollerStyle == false,
              scrollerStyle != .overlay else {
            return
        }

        // AppKit can silently drift back to `.legacy` during later tiling
        // passes after sibling-panel relayout. Repair the style at the end of
        // tiling so the configured scroller survives the final AppKit pass.
        isRestoringOverlayScrollerStyle = true
        defer { isRestoringOverlayScrollerStyle = false }
        scrollerStyle = .overlay
        verticalScroller?.scrollerStyle = .overlay
        horizontalScroller?.scrollerStyle = .overlay
    }

    #if DEBUG
    func setLiveScrollingForTesting(_ isLiveScrolling: Bool) {
        self.isLiveScrolling = isLiveScrolling
        if isLiveScrolling == false {
            synchronizeScrollMetrics()
            syncHostViewFrame()
        }
    }

    func performLiveScrollWritebackForTesting() {
        handleLiveScroll()
    }
    #endif
}
#endif
