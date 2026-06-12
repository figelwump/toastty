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

/// One in-flight annotation gesture: the mark is shown immediately while the
/// viewport capture runs in the background and the comment popover is open.
private struct PendingAnnotationDraft {
    let startPoint: CGPoint
    let endPoint: CGPoint
    let overlaySize: CGSize
    let sequenceNumber: Int
    let pageGeneration: Int
    let captureTask: Task<BrowserAnnotationCapturedSection, Error>

    var isRectangle: Bool {
        hypot(endPoint.x - startPoint.x, endPoint.y - startPoint.y)
            > BrowserAnnotationMarkStyle.dragThreshold
    }

    var rectangle: CGRect {
        CGRect(
            x: min(startPoint.x, endPoint.x),
            y: min(startPoint.y, endPoint.y),
            width: abs(endPoint.x - startPoint.x),
            height: abs(endPoint.y - startPoint.y)
        )
    }

    var bubbleRect: CGRect {
        BrowserAnnotationDisplayGeometry.bubbleRect(
            center: isRectangle ? rectangle.origin : endPoint
        )
    }
}

@MainActor
private final class BrowserAnnotationPopoverSession: NSObject, NSPopoverDelegate {
    enum Purpose: Equatable {
        case create
        case edit(annotationID: UUID)
        case view(annotationID: UUID)
    }

    let purpose: Purpose
    let popover: NSPopover
    var currentText: String
    var onClosedExternally: (() -> Void)?

    var isEditing: Bool {
        switch purpose {
        case .create, .edit:
            return true
        case .view:
            return false
        }
    }

    var annotationID: UUID? {
        switch purpose {
        case .create:
            return nil
        case .edit(let annotationID), .view(let annotationID):
            return annotationID
        }
    }

    init(purpose: Purpose, initialText: String = "") {
        self.purpose = purpose
        self.popover = NSPopover()
        self.currentText = initialText
        super.init()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
    }

    func popoverDidClose(_ notification: Notification) {
        onClosedExternally?()
    }
}

@MainActor
final class BrowserAnnotationOverlayNSView: NSView {
    weak var runtime: BrowserPanelRuntime?
    var activatePanel: (() -> Void)?

    private var dragStartPoint: CGPoint?
    private var dragCurrentPoint: CGPoint?
    private var pendingDraft: PendingAnnotationDraft?
    private var isResolvingPendingDraft = false
    private var popoverSession: BrowserAnnotationPopoverSession?
    private var hoveredAnnotationID: UUID?
    private var hoverTrackingArea: NSTrackingArea?
    private var wasAnnotationModeEnabled = false

    /// Live scroll offset estimate in view points. Updated synchronously from
    /// scroll-wheel deltas so marks track the page without waiting for the
    /// async JavaScript offset reconcile.
    private var scrollEstimatePoints: CGPoint?
    private var isViewportReconcileInFlight = false
    private var isViewportReconcileQueued = false

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

    // MARK: - Runtime state sync

    func annotationStateDidChange() {
        needsDisplay = true
        // Deferred so popover/first-responder side effects never run inside a
        // SwiftUI view update pass.
        DispatchQueue.main.async { [weak self] in
            self?.synchronizeWithRuntimeState()
        }
    }

    private func synchronizeWithRuntimeState() {
        guard let runtime else { return }
        let isEnabled = runtime.annotationState.isAnnotationModeEnabled
        if isEnabled != wasAnnotationModeEnabled {
            wasAnnotationModeEnabled = isEnabled
            if isEnabled {
                window?.makeFirstResponder(self)
                scheduleViewportReconcile()
            } else {
                dragStartPoint = nil
                dragCurrentPoint = nil
                hoveredAnnotationID = nil
                dismissActiveSession(cancelDraft: true, restoreFocus: false)
                // A draft mid-save keeps resolving (the user committed it);
                // anything else is orphaned once the mode closes.
                if isResolvingPendingDraft == false {
                    cancelPendingDraft()
                }
                scrollEstimatePoints = nil
            }
        }

        if let session = popoverSession,
           let annotationID = session.annotationID,
           runtime.annotationState.annotationItem(withID: annotationID) == nil {
            dismissActiveSession(cancelDraft: false)
        }

        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else { return }
        dragStartPoint = nil
        dragCurrentPoint = nil
        hoveredAnnotationID = nil
        dismissActiveSession(cancelDraft: true, restoreFocus: false)
    }

    // MARK: - Hit-testing and cursors

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
        guard runtime?.annotationState.isAnnotationModeEnabled == true else {
            return
        }
        addCursorRect(bounds, cursor: .crosshair)
        for mark in currentDisplayMarks() {
            let cursorRect = mark.bubbleRect.intersection(bounds)
            guard cursorRect.isEmpty == false else { continue }
            addCursorRect(cursorRect, cursor: .pointingHand)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        guard runtime?.annotationState.isAnnotationModeEnabled == true else {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let hitID = displayMark(at: point)?.annotationID
        guard hitID != hoveredAnnotationID else { return }
        hoveredAnnotationID = hitID
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard hoveredAnnotationID != nil else { return }
        hoveredAnnotationID = nil
        needsDisplay = true
    }

    private func displayMark(at point: CGPoint) -> BrowserAnnotationDisplayMark? {
        // Topmost (highest sequence number) marks draw last, so search from
        // the end of the draw order.
        currentDisplayMarks().reversed().first { $0.bubbleRect.contains(point) }
    }

    private func currentDisplayMarks() -> [BrowserAnnotationDisplayMark] {
        guard let runtime,
              runtime.annotationState.isAnnotationModeEnabled,
              let scrollEstimatePoints else {
            return []
        }
        return BrowserAnnotationDisplayGeometry.displayMarks(
            sections: runtime.annotationState.sections,
            currentScrollOffsetPoints: scrollEstimatePoints,
            pageZoom: runtime.annotationDisplayZoom,
            overlayBounds: bounds
        )
    }

    // MARK: - Mouse interaction

    override func mouseDown(with event: NSEvent) {
        guard let runtime,
              runtime.annotationState.isAnnotationModeEnabled else {
            super.mouseDown(with: event)
            return
        }

        activatePanel?()

        if popoverSession != nil {
            resolveActiveSessionFromClickAway()
            return
        }
        guard pendingDraft == nil else {
            return
        }

        let point = clampedPoint(convert(event.locationInWindow, from: nil))
        if let mark = displayMark(at: point) {
            openDetailPopover(annotationID: mark.annotationID, anchorRect: mark.bubbleRect)
            return
        }

        window?.makeFirstResponder(self)
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
        beginDraft(startPoint: startPoint, endPoint: endPoint)
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        if popoverSession?.isEditing == true || pendingDraft != nil {
            // The page is visually frozen while a comment is being composed;
            // scrolling underneath would desync the popover from its mark.
            return
        }
        if popoverSession != nil {
            dismissActiveSession(cancelDraft: false)
        }
        forwardScrollWheelToUnderlyingView(event)
        applyScrollEstimate(for: event)
        scheduleViewportReconcile()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            if dragStartPoint != nil {
                dragStartPoint = nil
                dragCurrentPoint = nil
                needsDisplay = true
            } else if popoverSession != nil {
                dismissActiveSession(cancelDraft: true)
            } else {
                runtime?.setAnnotationModeEnabled(false)
            }
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Draft lifecycle

    private func beginDraft(startPoint: CGPoint, endPoint: CGPoint) {
        guard let runtime,
              pendingDraft == nil,
              popoverSession == nil else {
            return
        }

        let captureTask = Task { @MainActor [weak runtime] () throws -> BrowserAnnotationCapturedSection in
            guard let runtime else { throw CancellationError() }
            return try await runtime.captureAnnotationSection()
        }
        let draft = PendingAnnotationDraft(
            startPoint: startPoint,
            endPoint: endPoint,
            overlaySize: bounds.size,
            sequenceNumber: runtime.annotationState.nextSequenceNumber,
            pageGeneration: runtime.currentAnnotationPageGeneration(),
            captureTask: captureTask
        )
        pendingDraft = draft
        needsDisplay = true
        openCreatePopover(for: draft)
    }

    private func resolvePendingDraft(comment: String) {
        guard let draft = pendingDraft, let runtime else {
            pendingDraft = nil
            return
        }

        isResolvingPendingDraft = true
        Task { @MainActor [weak self] in
            defer {
                if let self {
                    self.isResolvingPendingDraft = false
                    self.pendingDraft = nil
                    self.needsDisplay = true
                    self.window?.invalidateCursorRects(for: self)
                }
            }

            do {
                let section = try await draft.captureTask.value
                guard runtime.currentAnnotationPageGeneration() == draft.pageGeneration else {
                    return
                }
                let kind = BrowserAnnotationDisplayGeometry.annotationKind(
                    startPoint: draft.startPoint,
                    endPoint: draft.endPoint,
                    overlaySize: draft.overlaySize,
                    viewportSize: section.viewportSize
                )
                runtime.recordAnnotation(in: section, kind: kind, comment: comment)
                let zoom = runtime.annotationDisplayZoom
                self?.scrollEstimatePoints = CGPoint(
                    x: section.scrollOffset.x * zoom,
                    y: section.scrollOffset.y * zoom
                )
            } catch {
                runtime.postAnnotationSendNotice(
                    message: "Couldn't capture the page — annotation discarded",
                    isFailure: true
                )
                NSLog("Browser annotation capture failed: %@", error.localizedDescription)
            }
        }
    }

    private func cancelPendingDraft() {
        pendingDraft?.captureTask.cancel()
        pendingDraft = nil
        needsDisplay = true
    }

    // MARK: - Popovers

    private func openCreatePopover(for draft: PendingAnnotationDraft) {
        let session = BrowserAnnotationPopoverSession(purpose: .create)
        let content = BrowserAnnotationCommentEditorView(
            sequenceNumber: draft.sequenceNumber,
            saveButtonTitle: "Add",
            onSave: { [weak self] comment in
                guard let self else { return }
                self.dismissActiveSession(cancelDraft: false)
                self.resolvePendingDraft(comment: comment)
            },
            onCancel: { [weak self] in
                self?.dismissActiveSession(cancelDraft: true)
            },
            onTextChange: { [weak session] text in
                session?.currentText = text
            }
        )
        present(session: session, content: content, anchorRect: draft.bubbleRect)
        runtime?.setAnnotationEditorActive(true)
    }

    private func openEditPopover(annotationID: UUID, anchorRect: CGRect) {
        guard let runtime,
              let item = runtime.annotationState.annotationItem(withID: annotationID) else {
            return
        }
        let session = BrowserAnnotationPopoverSession(
            purpose: .edit(annotationID: annotationID),
            initialText: item.comment
        )
        let content = BrowserAnnotationCommentEditorView(
            sequenceNumber: item.sequenceNumber,
            initialComment: item.comment,
            saveButtonTitle: "Save",
            onSave: { [weak self] comment in
                guard let self else { return }
                self.dismissActiveSession(cancelDraft: false)
                self.runtime?.updateAnnotationComment(annotationID: annotationID, comment: comment)
            },
            onCancel: { [weak self] in
                self?.dismissActiveSession(cancelDraft: false)
            },
            onDelete: { [weak self] in
                self?.deleteAnnotation(annotationID: annotationID)
            },
            onTextChange: { [weak session] text in
                session?.currentText = text
            }
        )
        present(session: session, content: content, anchorRect: anchorRect)
        runtime.setAnnotationEditorActive(true)
    }

    private func openDetailPopover(annotationID: UUID, anchorRect: CGRect) {
        guard let runtime,
              let item = runtime.annotationState.annotationItem(withID: annotationID) else {
            return
        }
        let session = BrowserAnnotationPopoverSession(purpose: .view(annotationID: annotationID))
        let content = BrowserAnnotationCommentDetailView(
            sequenceNumber: item.sequenceNumber,
            comment: item.comment,
            onEdit: { [weak self] in
                guard let self else { return }
                self.dismissActiveSession(cancelDraft: false)
                self.openEditPopover(annotationID: annotationID, anchorRect: anchorRect)
            },
            onDelete: { [weak self] in
                self?.deleteAnnotation(annotationID: annotationID)
            }
        )
        present(session: session, content: content, anchorRect: anchorRect)
    }

    private func present<Content: View>(
        session: BrowserAnnotationPopoverSession,
        content: Content,
        anchorRect: CGRect
    ) {
        let host = NSHostingController(rootView: content)
        host.sizingOptions = [.preferredContentSize]
        session.popover.contentViewController = host
        session.onClosedExternally = { [weak self, weak session] in
            guard let self, let session, self.popoverSession === session else { return }
            self.popoverSession = nil
            if case .create = session.purpose {
                self.cancelPendingDraft()
            }
            self.runtime?.setAnnotationEditorActive(false)
            self.needsDisplay = true
        }
        popoverSession = session
        let anchor = anchorRect.intersection(bounds).isEmpty
            ? CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1)
            : anchorRect.intersection(bounds)
        session.popover.show(relativeTo: anchor, of: self, preferredEdge: .maxX)
    }

    private func dismissActiveSession(cancelDraft: Bool, restoreFocus: Bool = true) {
        guard let session = popoverSession else { return }
        popoverSession = nil
        session.popover.close()
        if cancelDraft, case .create = session.purpose {
            cancelPendingDraft()
        }
        runtime?.setAnnotationEditorActive(false)
        needsDisplay = true
        if restoreFocus {
            window?.makeFirstResponder(self)
        }
    }

    /// A click on the overlay while a popover is open resolves the popover
    /// instead of starting a new annotation: non-empty editors commit, empty
    /// editors and detail popovers just close.
    private func resolveActiveSessionFromClickAway() {
        guard let session = popoverSession else { return }
        let comment = session.currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch session.purpose {
        case .view:
            dismissActiveSession(cancelDraft: false)
        case .create:
            if comment.isEmpty {
                dismissActiveSession(cancelDraft: true)
            } else {
                dismissActiveSession(cancelDraft: false)
                resolvePendingDraft(comment: comment)
            }
        case .edit(let annotationID):
            dismissActiveSession(cancelDraft: false)
            if comment.isEmpty == false {
                runtime?.updateAnnotationComment(annotationID: annotationID, comment: comment)
            }
        }
    }

    private func deleteAnnotation(annotationID: UUID) {
        dismissActiveSession(cancelDraft: false)
        runtime?.removeAnnotation(annotationID: annotationID)
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    // MARK: - Scroll tracking

    private func applyScrollEstimate(for event: NSEvent) {
        guard var estimate = scrollEstimatePoints else { return }
        // Line-based wheel deltas arrive in rows, not points.
        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 19
        estimate.x = max(0, estimate.x - event.scrollingDeltaX * multiplier)
        estimate.y = max(0, estimate.y - event.scrollingDeltaY * multiplier)
        scrollEstimatePoints = estimate
        needsDisplay = true
    }

    private func scheduleViewportReconcile() {
        guard isViewportReconcileInFlight == false else {
            isViewportReconcileQueued = true
            return
        }
        isViewportReconcileInFlight = true
        Task { @MainActor [weak self] in
            guard let self, let runtime = self.runtime else { return }
            let viewport = await runtime.currentAnnotationViewport()
            let zoom = runtime.annotationDisplayZoom
            self.scrollEstimatePoints = CGPoint(
                x: viewport.scrollOffset.x * zoom,
                y: viewport.scrollOffset.y * zoom
            )
            self.needsDisplay = true
            self.window?.invalidateCursorRects(for: self)
            self.isViewportReconcileInFlight = false
            if self.isViewportReconcileQueued {
                self.isViewportReconcileQueued = false
                self.scheduleViewportReconcile()
            }
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

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard runtime?.annotationState.isAnnotationModeEnabled == true else {
            return
        }

        for mark in currentDisplayMarks() {
            drawMark(mark)
        }
        if let pendingDraft {
            drawPendingDraft(pendingDraft)
        }
        drawInProgressRectangle()
    }

    private func drawMark(_ mark: BrowserAnnotationDisplayMark) {
        if case .rectangle(let rect) = mark.shape {
            drawRectangleBody(rect)
        }
        if mark.annotationID == hoveredAnnotationID {
            drawHoverHalo(around: mark.bubbleRect)
        }
        drawNumberBubble(number: mark.sequenceNumber, in: mark.bubbleRect)
    }

    private func drawPendingDraft(_ draft: PendingAnnotationDraft) {
        if draft.isRectangle {
            drawRectangleBody(draft.rectangle)
        }
        drawNumberBubble(number: draft.sequenceNumber, in: draft.bubbleRect)
    }

    private func drawInProgressRectangle() {
        guard let start = dragStartPoint,
              let current = dragCurrentPoint,
              hypot(current.x - start.x, current.y - start.y)
              > BrowserAnnotationMarkStyle.dragThreshold else {
            return
        }

        let rect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        drawRectangleBody(rect)
    }

    private func drawRectangleBody(_ rect: CGRect) {
        let path = NSBezierPath(rect: rect)
        BrowserAnnotationMarkStyle.markColor
            .withAlphaComponent(BrowserAnnotationMarkStyle.rectangleFillAlpha)
            .setFill()
        path.fill()
        path.lineWidth = BrowserAnnotationMarkStyle.rectangleLineWidth
        BrowserAnnotationMarkStyle.markColor.setStroke()
        path.stroke()
    }

    private func drawHoverHalo(around bubbleRect: CGRect) {
        let inset = -(BrowserAnnotationMarkStyle.bubbleRingWidth
            + BrowserAnnotationMarkStyle.hoverRingExtraRadius)
        let haloRect = bubbleRect.insetBy(dx: inset, dy: inset)
        BrowserAnnotationMarkStyle.markColor
            .withAlphaComponent(BrowserAnnotationMarkStyle.hoverRingAlpha)
            .setFill()
        NSBezierPath(ovalIn: haloRect).fill()
    }

    private func drawNumberBubble(number: Int, in bubbleRect: CGRect) {
        let ringWidth = BrowserAnnotationMarkStyle.bubbleRingWidth

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = BrowserAnnotationMarkStyle.shadowColor
        shadow.shadowBlurRadius = BrowserAnnotationMarkStyle.shadowBlurRadius
        shadow.shadowOffset = NSSize(
            width: BrowserAnnotationMarkStyle.shadowOffset.width,
            height: BrowserAnnotationMarkStyle.shadowOffset.height
        )
        shadow.set()
        BrowserAnnotationMarkStyle.ringColor.setFill()
        NSBezierPath(ovalIn: bubbleRect.insetBy(dx: -ringWidth, dy: -ringWidth)).fill()
        NSGraphicsContext.restoreGraphicsState()

        BrowserAnnotationMarkStyle.markColor.setFill()
        NSBezierPath(ovalIn: bubbleRect).fill()

        let text = "\(number)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: BrowserAnnotationMarkStyle.numberFont(),
            .foregroundColor: BrowserAnnotationMarkStyle.numberTextColor,
        ]
        let textSize = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(
                x: bubbleRect.midX - textSize.width * 0.5,
                y: bubbleRect.midY - textSize.height * 0.5
            ),
            withAttributes: attributes
        )
    }
}
