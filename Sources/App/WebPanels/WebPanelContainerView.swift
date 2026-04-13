import AppKit
import WebKit

final class FocusAwareWKWebView: WKWebView {
    var interactionDidRequestFocus: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        interactionDidRequestFocus?()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        interactionDidRequestFocus?()
        super.rightMouseDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        interactionDidRequestFocus?()
        super.otherMouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        interactionDidRequestFocus?()
        return super.becomeFirstResponder()
    }
}

final class WebPanelContainerView: NSView {
    var onLayout: ((NSView) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        onLayout?(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        onLayout?(self)
    }
}
