import AppKit
#if TOASTTY_HAS_GHOSTTY_KIT
import GhosttyKit

/// Owns AppKit cursor presentation for a live terminal surface while keeping
/// the Ghostty render/input view positioned inside a separate document view.
/// This mirrors Ghostty's native macOS host model: AppKit owns scrollbar UI,
/// while Ghostty remains the source of truth for viewport state.
final class TerminalSurfaceScrollView: NSScrollView {
    enum ScrollbarPreference: String {
        case system
        case never
    }

    let terminalHostView: TerminalHostView
    private let scrollDocumentView: NSView
    private(set) var ghosttyCursorVisible = true
    private var viewportState: TerminalViewportState?
    private var cellHeightPoints: CGFloat = 0
    private var scrollbarPreference: ScrollbarPreference = .system
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []
    private var isLiveScrolling = false
    private var lastSentRow: Int?
    var performBindingAction: ((String) -> Bool)?

    init(terminalHostView: TerminalHostView = TerminalHostView()) {
        self.terminalHostView = terminalHostView
        scrollDocumentView = NSView(frame: .zero)
        super.init(frame: .zero)

        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = false
        hasHorizontalScroller = false
        autohidesScrollers = false
        usesPredominantAxisScrolling = true
        // Match Ghostty's native macOS host: "scrollbar = system" controls
        // whether a scrollbar exists, while AppKit rendering stays in overlay mode.
        scrollerStyle = .overlay
        contentView.clipsToBounds = false
        documentView = scrollDocumentView
        scrollDocumentView.addSubview(terminalHostView)
        contentView.postsBoundsChangedNotifications = true

        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: contentView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.synchronizeHostViewFrame()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isLiveScrolling = true
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isLiveScrolling = false
                self.synchronizeScrollMetrics()
                self.synchronizeHostViewFrame()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didLiveScrollNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleLiveScroll()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePreferredScrollerStyleChange()
            }
        })

        synchronizeScrollbarAppearance()
        synchronizeLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func layout() {
        super.layout()
        synchronizeLayout()
    }

    override func tile() {
        super.tile()
        synchronizeLayout()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
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

    func applyViewportState(_ viewportState: TerminalViewportState?) {
        guard self.viewportState != viewportState else {
            return
        }
        self.viewportState = viewportState
        synchronizeScrollbarAppearance()
        synchronizeScrollMetrics()
        synchronizeHostViewFrame()
    }

    func applyCellHeightPoints(_ cellHeightPoints: CGFloat?) {
        let nextCellHeightPoints = max(cellHeightPoints ?? 0, 0)
        guard abs(self.cellHeightPoints - nextCellHeightPoints) > 0.001 else {
            return
        }
        self.cellHeightPoints = nextCellHeightPoints
        synchronizeScrollMetrics()
        synchronizeHostViewFrame()
    }

    func applyScrollbarPreference(_ scrollbarPreference: ScrollbarPreference) {
        guard self.scrollbarPreference != scrollbarPreference else {
            return
        }
        self.scrollbarPreference = scrollbarPreference
        synchronizeScrollbarAppearance()
        synchronizeScrollMetrics()
        synchronizeHostViewFrame()
    }

    #if DEBUG
    var viewportStateForTesting: TerminalViewportState? {
        viewportState
    }

    func performLiveScrollWritebackForTesting() {
        handleLiveScroll()
    }
    #endif

    private func synchronizeLayout() {
        scrollDocumentView.frame.size.width = contentView.bounds.width
        synchronizeScrollbarAppearance()
        synchronizeScrollMetrics()
        synchronizeHostViewFrame()
    }

    private func synchronizeScrollbarAppearance() {
        hasVerticalScroller = scrollbarPreference == .system && (viewportState?.isScrollable ?? false)
    }

    private func synchronizeScrollMetrics() {
        let contentHeight = contentView.bounds.height
        let nextDocumentHeight = documentHeight(contentHeight: contentHeight)
        if abs(scrollDocumentView.frame.height - nextDocumentHeight) > 0.001 {
            scrollDocumentView.frame.size.height = nextDocumentHeight
        }

        guard isLiveScrolling == false else {
            reflectScrolledClipView(contentView)
            return
        }

        guard let viewportState,
              cellHeightPoints > 0 else {
            reflectScrolledClipView(contentView)
            return
        }

        let offsetY = contentOffsetY(for: viewportState)
        let currentOrigin = contentView.bounds.origin
        if abs(currentOrigin.x) > 0.001 || abs(currentOrigin.y - offsetY) > 0.001 {
            contentView.scroll(to: CGPoint(x: 0, y: offsetY))
        }
        lastSentRow = viewportState.offsetRows
        reflectScrolledClipView(contentView)
    }

    private func synchronizeHostViewFrame() {
        let visibleRect = contentView.documentVisibleRect
        let size = contentView.bounds.size
        let nextFrame = CGRect(origin: visibleRect.origin, size: size)
        guard terminalHostView.frame != nextFrame else {
            return
        }
        terminalHostView.frame = nextFrame
    }

    private func handleLiveScroll() {
        guard let viewportState,
              cellHeightPoints > 0,
              viewportState.isScrollable else {
            return
        }

        let visibleRect = contentView.documentVisibleRect
        let documentHeight = scrollDocumentView.frame.height
        let scrollOffset = max(documentHeight - visibleRect.origin.y - visibleRect.height, 0)
        let rawRow = Int((scrollOffset / cellHeightPoints).rounded(.down))
        let maxOffsetRows = max(viewportState.totalRows - viewportState.visibleRows, 0)
        let row = min(max(rawRow, 0), maxOffsetRows)
        guard row != lastSentRow else {
            return
        }
        guard performBindingAction?("scroll_to_row:\(row)") == true else {
            return
        }
        lastSentRow = row
    }

    private func handlePreferredScrollerStyleChange() {
        // Keep parity with Ghostty's native host implementation.
        scrollerStyle = .overlay
    }

    private func documentHeight(contentHeight: CGFloat) -> CGFloat {
        guard let viewportState,
              cellHeightPoints > 0 else {
            return max(contentHeight, 1)
        }
        let documentGridHeight = CGFloat(viewportState.totalRows) * cellHeightPoints
        let padding = contentHeight - (CGFloat(viewportState.visibleRows) * cellHeightPoints)
        return max(contentHeight, documentGridHeight + padding)
    }

    private func contentOffsetY(for viewportState: TerminalViewportState) -> CGFloat {
        guard cellHeightPoints > 0 else { return 0 }
        let rawOffsetY = CGFloat(
            max(viewportState.totalRows - viewportState.offsetRows - viewportState.visibleRows, 0)
        ) * cellHeightPoints
        let maxOffsetY = max(scrollDocumentView.frame.height - contentView.bounds.height, 0)
        return min(max(rawOffsetY, 0), maxOffsetY)
    }
}
#endif
