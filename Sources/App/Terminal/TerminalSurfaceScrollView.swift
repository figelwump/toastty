import AppKit
#if TOASTTY_HAS_GHOSTTY_KIT
import GhosttyKit

/// Owns AppKit cursor presentation for a live terminal surface while keeping
/// the Ghostty render/input view as the document view. This mirrors Ghostty's
/// native macOS approach of binding pointer state to the outer scroll container
/// rather than fighting cursor rect updates from the inner render view.
final class TerminalSurfaceScrollView: NSScrollView {
    let terminalHostView: TerminalHostView
    private(set) var ghosttyCursorVisible = true

    init(terminalHostView: TerminalHostView = TerminalHostView()) {
        self.terminalHostView = terminalHostView
        super.init(frame: .zero)

        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = false
        hasHorizontalScroller = false
        autohidesScrollers = true
        documentView = terminalHostView
        syncDocumentViewFrame()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        syncDocumentViewFrame()
    }

    override func tile() {
        super.tile()
        syncDocumentViewFrame()
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

    private func syncDocumentViewFrame() {
        let size = contentView.bounds.size
        guard terminalHostView.frame.origin != .zero || terminalHostView.frame.size != size else {
            return
        }
        terminalHostView.frame = CGRect(origin: .zero, size: size)
    }
}
#endif
