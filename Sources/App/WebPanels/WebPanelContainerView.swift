import AppKit
import CoreState
import Foundation
import WebKit

final class FocusAwareWKWebView: WKWebView {
    var interactionDidRequestFocus: (() -> Void)?
    var cursorDiagnosticPanelID: UUID?
    var cursorDiagnosticPanelKind: String?

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

    // WKWebView manages its hovered cursor from its internal content view.
    // Rebuilding AppKit cursor rects for the outer host can briefly restore
    // the default arrow cursor before WebKit reasserts the hovered cursor on
    // the next mouse move, so leave the outer host without its own rects.
    override func resetCursorRects() {
        logCursorDiagnostic("reset-cursor-rects")
    }

    override func cursorUpdate(with event: NSEvent) {
        logCursorDiagnostic("cursor-update", event: event)
        super.cursorUpdate(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        logCursorDiagnostic("mouse-entered", event: event)
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        logCursorDiagnostic("mouse-exited", event: event)
        super.mouseExited(with: event)
    }

    private func logCursorDiagnostic(
        _ phase: String,
        event: NSEvent? = nil
    ) {
        guard let window else { return }

        let windowMouseLocation = event?.locationInWindow ?? window.mouseLocationOutsideOfEventStream
        let localMouseLocation = convert(windowMouseLocation, from: nil)
        let insideBounds = bounds.contains(localMouseLocation)
        let edgeThreshold: CGFloat = 18
        let nearHorizontalEdge = localMouseLocation.x <= edgeThreshold ||
            bounds.width - localMouseLocation.x <= edgeThreshold
        let nearVerticalEdge = localMouseLocation.y <= edgeThreshold ||
            bounds.height - localMouseLocation.y <= edgeThreshold
        let nearExpandedBounds = bounds.insetBy(dx: -edgeThreshold, dy: -edgeThreshold).contains(localMouseLocation)
        guard nearExpandedBounds && (insideBounds == false || nearHorizontalEdge || nearVerticalEdge) else {
            return
        }

        var metadata: [String: String] = [
            "phase": phase,
            "panelID": cursorDiagnosticPanelID?.uuidString ?? "unknown",
            "panelKind": cursorDiagnosticPanelKind ?? "unknown",
            "frame": DraggableInteractionLog.rectDescription(frame),
            "bounds": DraggableInteractionLog.rectDescription(bounds),
            "windowNumber": "\(window.windowNumber)",
            "windowCursorRectsEnabled": "\(window.areCursorRectsEnabled)",
            "windowMouseLocation": DraggableInteractionLog.pointDescription(windowMouseLocation),
            "localMouseLocation": DraggableInteractionLog.pointDescription(localMouseLocation),
            "localMouseInsideBounds": "\(insideBounds)",
            "localMouseNearHorizontalEdge": "\(nearHorizontalEdge)",
            "localMouseNearVerticalEdge": "\(nearVerticalEdge)",
        ]
        if let event {
            metadata["eventType"] = DraggableInteractionLog.eventTypeDescription(event.type)
        }

        ToasttyLog.info(
            "web panel cursor diagnostic near pointer",
            category: .input,
            metadata: metadata
        )
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
