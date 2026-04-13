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
    var onEffectiveAppearanceChange: ((NSAppearance?) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateBackgroundColor()
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
        updateBackgroundColor()
        guard window != nil else { return }
        onEffectiveAppearanceChange?(effectiveAppearance)
        onLayout?(self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackgroundColor()
        onEffectiveAppearanceChange?(effectiveAppearance)
    }

    private func updateBackgroundColor() {
        layer?.backgroundColor = window?.backgroundColor.cgColor ?? NSColor.windowBackgroundColor.cgColor
    }
}
