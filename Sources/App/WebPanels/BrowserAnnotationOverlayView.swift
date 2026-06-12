import AppKit
import SwiftUI

struct BrowserAnnotationOverlayView: NSViewRepresentable {
    @ObservedObject var runtime: BrowserPanelRuntime
    let activatePanel: () -> Void

    func makeNSView(context: Context) -> BrowserAnnotationOverlayNSView {
        let view = BrowserAnnotationOverlayNSView()
        view.runtime = runtime
        view.activatePanel = activatePanel
        return view
    }

    func updateNSView(_ view: BrowserAnnotationOverlayNSView, context: Context) {
        view.runtime = runtime
        view.activatePanel = activatePanel
        view.annotationStateDidChange()
    }
}

@MainActor
final class BrowserAnnotationOverlayNSView: NSView {
    private static let dragThreshold: CGFloat = 4
    private static let markDiameter: CGFloat = 22
    private static let markColor = NSColor.systemRed
    private static let textColor = NSColor.white
    private static let numberFont = NSFont.systemFont(ofSize: 12, weight: .bold)

    weak var runtime: BrowserPanelRuntime?
    var activatePanel: (() -> Void)?

    private var dragStartPoint: CGPoint?
    private var dragCurrentPoint: CGPoint?
    private var cachedViewport: BrowserAnnotationViewport?
    private var isRecordingAnnotation = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func annotationStateDidChange() {
        needsDisplay = true
        resetCursorRects()
        refreshViewportIfNeeded()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard runtime?.annotationState.isAnnotationModeEnabled == true,
              isHidden == false,
              alphaValue > 0,
              bounds.contains(point) else {
            return nil
        }
        return self
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if runtime?.annotationState.isAnnotationModeEnabled == true {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard runtime?.annotationState.isAnnotationModeEnabled == true,
              isRecordingAnnotation == false else {
            super.mouseDown(with: event)
            return
        }

        activatePanel?()
        window?.makeFirstResponder(self)
        let point = clampedPoint(convert(event.locationInWindow, from: nil))
        dragStartPoint = point
        dragCurrentPoint = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStartPoint != nil else {
            super.mouseDragged(with: event)
            return
        }
        dragCurrentPoint = clampedPoint(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let startPoint = dragStartPoint,
              runtime?.annotationState.isAnnotationModeEnabled == true else {
            super.mouseUp(with: event)
            return
        }

        let endPoint = clampedPoint(convert(event.locationInWindow, from: nil))
        dragStartPoint = nil
        dragCurrentPoint = nil
        needsDisplay = true

        recordAnnotation(startPoint: startPoint, endPoint: endPoint)
    }

    override func scrollWheel(with event: NSEvent) {
        guard isRecordingAnnotation == false else {
            return
        }
        forwardScrollWheelToUnderlyingView(event)
        refreshViewportIfNeeded()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            dragStartPoint = nil
            dragCurrentPoint = nil
            needsDisplay = true
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let runtime,
              runtime.annotationState.isAnnotationModeEnabled else {
            return
        }

        drawExistingAnnotations(from: runtime.annotationState)
        drawInProgressRectangle()
    }

    private func recordAnnotation(startPoint: CGPoint, endPoint: CGPoint) {
        guard let runtime,
              isRecordingAnnotation == false else {
            return
        }
        let pageGeneration = runtime.currentAnnotationPageGeneration()
        isRecordingAnnotation = true
        Task { @MainActor [weak self, weak runtime] in
            guard let self, let runtime else { return }
            defer {
                self.isRecordingAnnotation = false
                self.needsDisplay = true
            }

            do {
                let section = try await runtime.captureAnnotationSection()
                guard runtime.currentAnnotationPageGeneration() == pageGeneration else {
                    return
                }
                self.cachedViewport = BrowserAnnotationViewport(
                    scrollOffset: section.scrollOffset,
                    viewportSize: section.viewportSize
                )
                guard let comment = Self.promptForComment(
                    sequenceNumber: runtime.annotationState.nextSequenceNumber,
                    window: self.window
                ) else {
                    return
                }
                let kind = Self.annotationKind(
                    startPoint: startPoint,
                    endPoint: endPoint,
                    overlaySize: self.bounds.size,
                    viewportSize: section.viewportSize
                )
                runtime.recordAnnotation(
                    in: section,
                    kind: kind,
                    comment: comment
                )
            } catch {
                NSLog("Browser annotation capture failed: %@", error.localizedDescription)
            }
        }
    }

    private static func annotationKind(
        startPoint: CGPoint,
        endPoint: CGPoint,
        overlaySize: CGSize,
        viewportSize: CGSize
    ) -> BrowserAnnotationKind {
        let scaledStartPoint = scaledOverlayPoint(
            startPoint,
            overlaySize: overlaySize,
            viewportSize: viewportSize
        )
        let scaledEndPoint = scaledOverlayPoint(
            endPoint,
            overlaySize: overlaySize,
            viewportSize: viewportSize
        )

        if scaledStartPoint.distance(to: scaledEndPoint) <= dragThreshold {
            return .point(BrowserAnnotationCoordinateMapper.normalizedPoint(
                fromViewportTopLeftPoint: scaledEndPoint,
                viewportSize: viewportSize
            ))
        }
        return .rectangle(BrowserAnnotationCoordinateMapper.normalizedRectangle(
            fromViewportTopLeftStart: scaledStartPoint,
            end: scaledEndPoint,
            viewportSize: viewportSize
        ))
    }

    private static func scaledOverlayPoint(
        _ point: CGPoint,
        overlaySize: CGSize,
        viewportSize: CGSize
    ) -> CGPoint {
        guard overlaySize.width > 0,
              overlaySize.height > 0 else {
            return point
        }
        return CGPoint(
            x: point.x * viewportSize.width / overlaySize.width,
            y: point.y * viewportSize.height / overlaySize.height
        )
    }

    private func drawExistingAnnotations(from state: BrowserAnnotationDraftState) {
        let section = visibleSection(from: state) ?? state.sections.last
        guard let section else { return }

        for annotation in section.annotations {
            switch annotation.kind {
            case .point(let point):
                let center = CGPoint(
                    x: point.x * bounds.width,
                    y: point.y * bounds.height
                )
                drawNumberBubble(sequenceNumber: annotation.sequenceNumber, center: center)

            case .rectangle(let rect):
                let drawingRect = CGRect(
                    x: rect.minX * bounds.width,
                    y: rect.minY * bounds.height,
                    width: rect.width * bounds.width,
                    height: rect.height * bounds.height
                )
                let path = NSBezierPath(rect: drawingRect)
                path.lineWidth = 2
                Self.markColor.setStroke()
                path.stroke()
                drawNumberBubble(
                    sequenceNumber: annotation.sequenceNumber,
                    center: CGPoint(
                        x: drawingRect.minX + Self.markDiameter * 0.5,
                        y: drawingRect.minY + Self.markDiameter * 0.5
                    )
                )
            }
        }
    }

    private func drawInProgressRectangle() {
        guard let start = dragStartPoint,
              let current = dragCurrentPoint,
              start.distance(to: current) > Self.dragThreshold else {
            return
        }

        let rect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        Self.markColor.withAlphaComponent(0.9).setStroke()
        path.stroke()
    }

    private func drawNumberBubble(sequenceNumber: Int, center: CGPoint) {
        let diameter = Self.markDiameter
        let bubbleRect = CGRect(
            x: center.x - diameter * 0.5,
            y: center.y - diameter * 0.5,
            width: diameter,
            height: diameter
        )
        let bubblePath = NSBezierPath(ovalIn: bubbleRect)
        Self.markColor.setFill()
        bubblePath.fill()

        let text = "\(sequenceNumber)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.numberFont,
            .foregroundColor: Self.textColor,
        ]
        let textSize = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(
                x: center.x - textSize.width * 0.5,
                y: center.y - textSize.height * 0.5
            ),
            withAttributes: attributes
        )
    }

    private func visibleSection(from state: BrowserAnnotationDraftState) -> BrowserAnnotationSection? {
        guard let cachedViewport else { return nil }
        return state.visibleSection(
            scrollOffset: cachedViewport.scrollOffset,
            viewportSize: cachedViewport.viewportSize
        )
    }

    private func refreshViewportIfNeeded() {
        guard runtime?.annotationState.isAnnotationModeEnabled == true,
              let runtime else {
            cachedViewport = nil
            return
        }
        Task { @MainActor [weak self, weak runtime] in
            guard let self, let runtime else { return }
            self.cachedViewport = await runtime.currentAnnotationViewport()
            self.needsDisplay = true
        }
    }

    private func forwardScrollWheelToUnderlyingView(_ event: NSEvent) {
        guard let window,
              let contentView = window.contentView else {
            return
        }

        isHidden = true
        defer { isHidden = false }

        let pointInContent = contentView.convert(event.locationInWindow, from: nil)
        guard let target = contentView.hitTest(pointInContent),
              target !== self else {
            return
        }
        target.scrollWheel(with: event)
    }

    private func clampedPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), bounds.width),
            y: min(max(point.y, 0), bounds.height)
        )
    }

    private static func promptForComment(sequenceNumber: Int, window: NSWindow?) -> String? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Comment"

        let alert = NSAlert()
        alert.messageText = "Annotation \(sequenceNumber)"
        alert.informativeText = "Add a comment for this browser annotation."
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        if let window {
            alert.window.level = window.level
        }
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return nil
        }

        let comment = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return comment.isEmpty ? nil : comment
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}
