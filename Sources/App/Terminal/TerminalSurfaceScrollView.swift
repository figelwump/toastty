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
    private var lastSentRow: Int?
    private var pendingRequestedRow: Int?
    var requestScrollToRow: ((Int) -> Bool)?

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
        synchronizeScrollMetrics()
        syncHostViewFrame()
    }

    override func tile() {
        super.tile()
        synchronizeScrollMetrics()
        syncHostViewFrame()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            isLiveScrolling = false
        }
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
        scrollerStyle = .overlay
    }

    private func synchronizeScrollMetrics() {
        scrollDocumentView.frame.size.width = contentView.bounds.width
        scrollDocumentView.frame.size.height = documentHeight(contentHeight: contentView.bounds.height)
        hasVerticalScroller = scrollbarState?.isScrollable ?? false

        guard isLiveScrolling == false,
              pendingRequestedRow == nil,
              let scrollbarState,
              cellHeightPoints > 0 else {
            reflectScrolledClipView(contentView)
            return
        }

        let desiredOffsetY = contentOffsetY(for: scrollbarState)
        let currentOriginY = contentView.bounds.origin.y
        if abs(currentOriginY - desiredOffsetY) > 0.5 {
            contentView.scroll(to: CGPoint(x: 0, y: desiredOffsetY))
        }
        lastSentRow = scrollbarState.offsetRows
        reflectScrolledClipView(contentView)
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
