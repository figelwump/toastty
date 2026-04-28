import AppKit
import CoreState
import SwiftUI

struct PointerInteractionValue: Equatable {
    let startLocation: CGPoint
    let location: CGPoint
    let translation: CGSize
}

struct PointerInteractionRegion: NSViewRepresentable {
    var name: String
    var metadata: [String: String]
    var cursor: NSCursor?
    var onBegan: (PointerInteractionValue) -> Void
    var onChanged: (PointerInteractionValue) -> Void
    var onEnded: (PointerInteractionValue) -> Void
    var onHoverChanged: (Bool) -> Void

    init(
        name: String,
        metadata: [String: String] = [:],
        cursor: NSCursor? = nil,
        onBegan: @escaping (PointerInteractionValue) -> Void = { _ in },
        onChanged: @escaping (PointerInteractionValue) -> Void,
        onEnded: @escaping (PointerInteractionValue) -> Void,
        onHoverChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.name = name
        self.metadata = metadata
        self.cursor = cursor
        self.onBegan = onBegan
        self.onChanged = onChanged
        self.onEnded = onEnded
        self.onHoverChanged = onHoverChanged
    }

    func makeNSView(context _: Context) -> PointerInteractionView {
        PointerInteractionView()
    }

    func updateNSView(_ nsView: PointerInteractionView, context _: Context) {
        nsView.logName = name
        nsView.logMetadata = metadata
        nsView.cursor = cursor
        nsView.onBegan = onBegan
        nsView.onChanged = onChanged
        nsView.onEnded = onEnded
        nsView.onHoverChanged = onHoverChanged
    }

    static func dismantleNSView(_ nsView: PointerInteractionView, coordinator _: ()) {
        nsView.invalidate()
    }
}

final class PointerInteractionView: NSView {
    private static let trackingEventMask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]

    var logName = "pointer"
    var logMetadata: [String: String] = [:]
    var usesEventTrackingLoop = true
    var onBegan: ((PointerInteractionValue) -> Void)?
    var onChanged: ((PointerInteractionValue) -> Void)?
    var onEnded: ((PointerInteractionValue) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var cursor: NSCursor? {
        didSet {
            // Cursor rects in this view rely on z-order to apply, but the
            // resize-handle's hit zone overlaps a sibling subtree (the right
            // panel content) that sits on top in NSView z-order. We rely on
            // tracking-area cursorUpdate events instead, which fire based on
            // the tracking area's bounds. If the pointer is already inside,
            // re-apply the new cursor immediately so the change takes effect
            // without waiting for the next entry.
            if isPointerInside {
                logCursorDiagnostic("cursor-did-set-reapply")
                cursor?.set()
            }
        }
    }

    private var hoverTrackingArea: NSTrackingArea?
    private var isPointerInside = false
    private var isSequenceSuppressingWindowMovement = false
    private var startWindowLocation: CGPoint?
    private var startLocation: CGPoint?
    private var dragEventCount = 0
    private var isTrackingPointerSequence = false

    override var isFlipped: Bool { true }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        suppressWindowMovementForCurrentSequence()
        beginPointerSequence(with: event)
        guard usesEventTrackingLoop else { return }
        trackPointerSequence(startingWith: event)
    }

    override func mouseDragged(with event: NSEvent) {
        handlePointerDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        finishPointerSequence(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        if let cursor {
            logCursorDiagnostic("cursor-update-set", event: event)
            cursor.set()
        } else {
            logCursorDiagnostic("cursor-update-defer", event: event)
            super.cursorUpdate(with: event)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        logCursorDiagnostic("view-did-move-to-window")
        if window == nil {
            setPointerInside(false)
            if isTrackingPointerSequence == false {
                restoreSequenceWindowMovementIfNeeded(reason: "removed-from-window")
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .enabledDuringMouseDrag, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
        logCursorDiagnostic("tracking-area-updated")
    }

    override func mouseEntered(with event: NSEvent) {
        logCursorDiagnostic("mouse-entered", event: event)
        setPointerInside(true)
    }

    override func mouseExited(with event: NSEvent) {
        logCursorDiagnostic("mouse-exited", event: event)
        setPointerInside(false)
    }

    deinit {
        let ownerID = ObjectIdentifier(self)
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                WindowMovementSuppression.restore(ownerID: ownerID, reason: "pointer-sequence")
            }
        } else {
            Task { @MainActor in
                WindowMovementSuppression.restore(ownerID: ownerID, reason: "pointer-sequence")
            }
        }
    }

    func invalidate() {
        cancelPointerSequence(reason: "invalidate")
        setPointerInside(false)
        onBegan = nil
        onChanged = nil
        onEnded = nil
        onHoverChanged = nil
    }

    private func setPointerInside(_ isInside: Bool, notify: Bool = true) {
        guard isPointerInside != isInside else { return }
        isPointerInside = isInside
        logCursorDiagnostic(isInside ? "pointer-inside-set" : "pointer-outside-set")
        if notify {
            onHoverChanged?(isInside)
        }
    }

    private func beginPointerSequence(with event: NSEvent) {
        startWindowLocation = event.locationInWindow
        startLocation = convert(event.locationInWindow, from: nil)
        dragEventCount = 0
        logInteraction("mouseDown", event: event)
        onBegan?(
            PointerInteractionValue(
                startLocation: startLocation ?? .zero,
                location: startLocation ?? .zero,
                translation: .zero
            )
        )
    }

    private func handlePointerDragged(with event: NSEvent) {
        guard let value = interactionValue(for: event) else {
            logInteraction("mouseDraggedWithoutStart", event: event)
            return
        }
        dragEventCount += 1
        if dragEventCount <= 5 || dragEventCount.isMultiple(of: 10) {
            logInteraction("mouseDragged", event: event, value: value)
        }
        onChanged?(value)
    }

    private func finishPointerSequence(with event: NSEvent) {
        guard let value = interactionValue(for: event) else {
            logInteraction("mouseUpWithoutStart", event: event)
            cancelPointerSequence(reason: "mouse-up-without-start")
            return
        }
        logInteraction("mouseUp", event: event, value: value)
        startWindowLocation = nil
        startLocation = nil
        dragEventCount = 0
        restoreSequenceWindowMovementIfNeeded(reason: "mouse-up")
        onEnded?(value)
    }

    private func trackPointerSequence(startingWith event: NSEvent) {
        guard let trackingWindow = event.window ?? window else {
            logTrackingLoop("skipped", event: event, reason: "missing-window")
            return
        }

        isTrackingPointerSequence = true
        logTrackingLoop("started", event: event)
        defer {
            isTrackingPointerSequence = false
        }

        while startWindowLocation != nil {
            let timeout = Date(timeIntervalSinceNow: 60)
            guard let nextEvent = trackingWindow.nextEvent(
                matching: Self.trackingEventMask,
                until: timeout,
                inMode: .eventTracking,
                dequeue: true
            ) else {
                logTrackingLoop("timedOut", event: event)
                cancelPointerSequence(reason: "tracking-timeout")
                return
            }

            switch nextEvent.type {
            case .leftMouseDragged:
                handlePointerDragged(with: nextEvent)

            case .leftMouseUp:
                finishPointerSequence(with: nextEvent)
                logTrackingLoop("finished", event: nextEvent)
                return

            default:
                logTrackingLoop("ignored", event: nextEvent)
            }
        }

        logTrackingLoop("endedWithoutStart", event: event)
        cancelPointerSequence(reason: "tracking-ended-without-start")
    }

    private func cancelPointerSequence(reason: String) {
        startWindowLocation = nil
        startLocation = nil
        dragEventCount = 0
        restoreSequenceWindowMovementIfNeeded(reason: reason)
    }

    private func interactionValue(for event: NSEvent) -> PointerInteractionValue? {
        guard let startWindowLocation,
              let startLocation else {
            return nil
        }

        let currentWindowLocation = event.locationInWindow
        let translation = CGSize(
            width: currentWindowLocation.x - startWindowLocation.x,
            height: startWindowLocation.y - currentWindowLocation.y
        )
        let location = CGPoint(
            x: startLocation.x + translation.width,
            y: startLocation.y + translation.height
        )
        return PointerInteractionValue(
            startLocation: startLocation,
            location: location,
            translation: translation
        )
    }

    private func suppressWindowMovementForCurrentSequence() {
        guard isSequenceSuppressingWindowMovement == false else { return }
        WindowMovementSuppression.suppress(window: window, owner: self, reason: "pointer-sequence")
        isSequenceSuppressingWindowMovement = true
        if let window {
            logWindowMovementSuppression(reason: "mouse-down", window: window)
        }
    }

    private func restoreSequenceWindowMovementIfNeeded(reason: String) {
        guard isSequenceSuppressingWindowMovement else { return }
        WindowMovementSuppression.restore(owner: self, reason: "pointer-sequence")
        isSequenceSuppressingWindowMovement = false
        if let window {
            logWindowMovementSuppression(reason: reason, window: window)
        }
    }

    private func logInteraction(
        _ phase: String,
        event: NSEvent,
        value: PointerInteractionValue? = nil
    ) {
        var metadata = logMetadata
        metadata["name"] = logName
        metadata["phase"] = phase
        metadata["eventType"] = DraggableInteractionLog.eventTypeDescription(event.type)
        metadata["windowNumber"] = "\(event.windowNumber)"
        metadata["eventWindowLocation"] = DraggableInteractionLog.pointDescription(event.locationInWindow)
        metadata["eventLocalLocation"] = DraggableInteractionLog.pointDescription(convert(event.locationInWindow, from: nil))
        metadata["frame"] = DraggableInteractionLog.rectDescription(frame)
        metadata["bounds"] = DraggableInteractionLog.rectDescription(bounds)
        metadata["mouseDownCanMoveWindow"] = "\(mouseDownCanMoveWindow)"
        metadata["dragEventCount"] = "\(dragEventCount)"
        metadata["trackingLoopActive"] = "\(isTrackingPointerSequence)"
        if let window {
            metadata["windowIsMovable"] = "\(window.isMovable)"
            metadata["windowIsMovableByWindowBackground"] = "\(window.isMovableByWindowBackground)"
        }
        if let value {
            metadata["startLocation"] = DraggableInteractionLog.pointDescription(value.startLocation)
            metadata["location"] = DraggableInteractionLog.pointDescription(value.location)
            metadata["translation"] = DraggableInteractionLog.sizeDescription(value.translation)
        }
        ToasttyLog.info("draggable pointer interaction", category: .input, metadata: metadata)
    }

    private func logTrackingLoop(
        _ phase: String,
        event: NSEvent,
        reason: String? = nil
    ) {
        var metadata = logMetadata
        metadata["name"] = logName
        metadata["phase"] = phase
        metadata["eventType"] = DraggableInteractionLog.eventTypeDescription(event.type)
        metadata["windowNumber"] = "\(event.windowNumber)"
        metadata["eventWindowLocation"] = DraggableInteractionLog.pointDescription(event.locationInWindow)
        metadata["dragEventCount"] = "\(dragEventCount)"
        if let reason {
            metadata["reason"] = reason
        }
        if let window = event.window ?? window {
            metadata["windowIsMovable"] = "\(window.isMovable)"
            metadata["windowIsMovableByWindowBackground"] = "\(window.isMovableByWindowBackground)"
        }
        ToasttyLog.info("draggable pointer tracking loop", category: .input, metadata: metadata)
    }

    private func logWindowMovementSuppression(
        reason: String,
        window: NSWindow
    ) {
        var metadata = logMetadata
        metadata["name"] = logName
        metadata["reason"] = reason
        metadata["windowNumber"] = "\(window.windowNumber)"
        metadata["windowIsMovable"] = "\(window.isMovable)"
        metadata["sequenceSuppressionActive"] = "\(isSequenceSuppressingWindowMovement)"
        ToasttyLog.info("draggable pointer window movement suppression", category: .input, metadata: metadata)
    }

    private func logCursorDiagnostic(
        _ phase: String,
        event: NSEvent? = nil
    ) {
        guard shouldLogCursorDiagnostics else { return }

        var metadata = logMetadata
        metadata["name"] = logName
        metadata["phase"] = phase
        metadata["pointerInside"] = "\(isPointerInside)"
        metadata["frame"] = DraggableInteractionLog.rectDescription(frame)
        metadata["bounds"] = DraggableInteractionLog.rectDescription(bounds)
        metadata["visibleRect"] = DraggableInteractionLog.rectDescription(visibleRect)
        metadata["targetCursor"] = cursor.map(Self.cursorDescription) ?? "nil"
        if let cursor {
            metadata["currentCursorMatchesTarget"] = "\(NSCursor.current === cursor)"
        }
        if let event {
            metadata["eventType"] = DraggableInteractionLog.eventTypeDescription(event.type)
            metadata["eventWindowLocation"] = DraggableInteractionLog.pointDescription(event.locationInWindow)
            metadata["eventLocalLocation"] = DraggableInteractionLog.pointDescription(convert(event.locationInWindow, from: nil))
        }
        if let window {
            let windowMouseLocation = window.mouseLocationOutsideOfEventStream
            let localMouseLocation = convert(windowMouseLocation, from: nil)
            metadata["windowNumber"] = "\(window.windowNumber)"
            metadata["windowCursorRectsEnabled"] = "\(window.areCursorRectsEnabled)"
            metadata["windowMouseLocation"] = DraggableInteractionLog.pointDescription(windowMouseLocation)
            metadata["localMouseLocation"] = DraggableInteractionLog.pointDescription(localMouseLocation)
            metadata["localMouseInsideBounds"] = "\(bounds.contains(localMouseLocation))"
        }

        ToasttyLog.info(
            "pointer cursor diagnostic",
            category: .input,
            metadata: metadata
        )
    }

    private var shouldLogCursorDiagnostics: Bool {
        logName == "right-panel-resize-handle"
    }

    private static func cursorDescription(_ cursor: NSCursor) -> String {
        if cursor === NSCursor.arrow {
            return "arrow"
        }
        if cursor === NSCursor.iBeam {
            return "iBeam"
        }
        if cursor === NSCursor.pointingHand {
            return "pointingHand"
        }
        if cursor === NSCursor.resizeLeftRight {
            return "resizeLeftRight"
        }
        if cursor === NSCursor.resizeUpDown {
            return "resizeUpDown"
        }
        return String(describing: cursor)
    }
}

enum DraggableInteractionLog {
    static func pointDescription(_ point: CGPoint) -> String {
        String(format: "%.1f,%.1f", point.x, point.y)
    }

    static func sizeDescription(_ size: CGSize) -> String {
        String(format: "%.1f,%.1f", size.width, size.height)
    }

    static func rectDescription(_ rect: CGRect) -> String {
        String(format: "%.1f,%.1f %.1fx%.1f", rect.minX, rect.minY, rect.width, rect.height)
    }

    static func eventTypeDescription(_ eventType: NSEvent.EventType) -> String {
        switch eventType {
        case .leftMouseDown:
            return "leftMouseDown"
        case .leftMouseDragged:
            return "leftMouseDragged"
        case .leftMouseUp:
            return "leftMouseUp"
        case .mouseMoved:
            return "mouseMoved"
        default:
            return "\(eventType.rawValue)"
        }
    }
}
