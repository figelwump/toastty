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
    var suppressesWindowMovementWhileHovered: Bool
    var onBegan: (PointerInteractionValue) -> Void
    var onChanged: (PointerInteractionValue) -> Void
    var onEnded: (PointerInteractionValue) -> Void
    var onHoverChanged: (Bool) -> Void

    init(
        name: String,
        metadata: [String: String] = [:],
        cursor: NSCursor? = nil,
        suppressesWindowMovementWhileHovered: Bool = false,
        onBegan: @escaping (PointerInteractionValue) -> Void = { _ in },
        onChanged: @escaping (PointerInteractionValue) -> Void,
        onEnded: @escaping (PointerInteractionValue) -> Void,
        onHoverChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.name = name
        self.metadata = metadata
        self.cursor = cursor
        self.suppressesWindowMovementWhileHovered = suppressesWindowMovementWhileHovered
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
        nsView.suppressesWindowMovementWhileHovered = suppressesWindowMovementWhileHovered
        nsView.onBegan = onBegan
        nsView.onChanged = onChanged
        nsView.onEnded = onEnded
        nsView.onHoverChanged = onHoverChanged
    }

    static func dismantleNSView(_ nsView: PointerInteractionView, coordinator _: ()) {
        nsView.logLifecycleDiagnostic("dismantleNSView")
        nsView.invalidate()
    }
}

private final class PointerWindowMovementSuppressionOwner: NSObject, @unchecked Sendable {}

final class PointerInteractionView: NSView {
    private static let trackingEventMask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]

    private enum WindowMovementRestoreTiming {
        case immediate
        case deferred
    }

    var logName = "pointer"
    var logMetadata: [String: String] = [:]
    var usesEventTrackingLoop = true
    var suppressesWindowMovementWhileHovered = false {
        didSet {
            guard suppressesWindowMovementWhileHovered != oldValue else { return }
            if suppressesWindowMovementWhileHovered, isPointerInside {
                suppressWindowMovementForHover()
            } else if suppressesWindowMovementWhileHovered == false {
                restoreHoverWindowMovementIfNeeded()
            }
        }
    }
    var onBegan: ((PointerInteractionValue) -> Void)?
    var onChanged: ((PointerInteractionValue) -> Void)?
    var onEnded: ((PointerInteractionValue) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var cursor: NSCursor? {
        didSet {
            // If the pointer is already inside, re-apply the new cursor so a
            // SwiftUI update takes effect without waiting for the next entry.
            if isPointerInside {
                logCursorDiagnostic("cursor-did-set-reapply")
                cursor?.set()
            }
        }
    }

    private var hoverTrackingArea: NSTrackingArea?
    private var sequenceWindowMovementSuppressionOwner = PointerWindowMovementSuppressionOwner()
    private var hoverWindowMovementSuppressionOwner = PointerWindowMovementSuppressionOwner()
    private var isPointerInside = false
    private var isSequenceSuppressingWindowMovement = false
    private var pointerSequenceGeneration = 0
    private weak var pointerSequenceWindow: NSWindow?
    private var startWindowFrame: CGRect?
    private var startScreenLocation: CGPoint?
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
            cancelPointerSequence(reason: "removed-from-window", restoreTiming: .deferred)
            clearPointerHoverForTeardown()
        } else if suppressesWindowMovementWhileHovered, isPointerInside {
            suppressWindowMovementForHover()
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
        let sequenceOwner = sequenceWindowMovementSuppressionOwner
        let hoverOwner = hoverWindowMovementSuppressionOwner
        Self.scheduleWindowMovementRestore(owner: sequenceOwner, reason: "pointer-sequence")
        Self.scheduleWindowMovementRestore(owner: hoverOwner, reason: "pointer-hover")
    }

    func invalidate() {
        logLifecycleDiagnostic("invalidate")
        // SwiftUI calls dismantleNSView → invalidate while it is still walking
        // its view graph. Synchronously mutating window.isMovable /
        // isMovableByWindowBackground / styleMask here triggers KVO observers
        // installed by SwiftUI (LazyPreventsWindowDragFeature) and re-enters
        // the graph on a torn-down node. Defer the restore one runloop turn so
        // dismantle completes first.
        cancelPointerSequence(reason: "invalidate", restoreTiming: .deferred)
        clearPointerHoverForTeardown()
        onBegan = nil
        onChanged = nil
        onEnded = nil
        onHoverChanged = nil
    }

    private func setPointerInside(_ isInside: Bool, notify: Bool = true) {
        guard isPointerInside != isInside else { return }
        isPointerInside = isInside
        logCursorDiagnostic(isInside ? "pointer-inside-set" : "pointer-outside-set")
        if suppressesWindowMovementWhileHovered {
            if isInside {
                suppressWindowMovementForHover()
            } else {
                restoreHoverWindowMovementIfNeeded()
            }
        }
        if notify {
            onHoverChanged?(isInside)
        }
    }

    private func beginPointerSequence(with event: NSEvent) {
        pointerSequenceGeneration &+= 1
        let sequenceWindow = event.window ?? window
        pointerSequenceWindow = sequenceWindow
        startWindowFrame = sequenceWindow?.frame
        startScreenLocation = sequenceWindow?.convertPoint(toScreen: event.locationInWindow)
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
        restoreSuppressedWindowFrameIfNeeded(reason: "mouse-dragged")
        onChanged?(value)
    }

    private func finishPointerSequence(with event: NSEvent) {
        guard let value = interactionValue(for: event) else {
            logInteraction("mouseUpWithoutStart", event: event)
            cancelPointerSequence(reason: "mouse-up-without-start")
            return
        }
        logInteraction("mouseUp", event: event, value: value)
        restoreSuppressedWindowFrameIfNeeded(reason: "mouse-up")
        clearPointerSequenceState()
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

    private func cancelPointerSequence(
        reason: String,
        restoreTiming: WindowMovementRestoreTiming = .immediate
    ) {
        switch restoreTiming {
        case .immediate:
            restoreSuppressedWindowFrameIfNeeded(reason: reason)
            clearPointerSequenceState()
            restoreSequenceWindowMovementIfNeeded(reason: reason)

        case .deferred:
            schedulePointerSequenceWindowMovementRestore(reason: reason)
        }
    }

    private func schedulePointerSequenceWindowMovementRestore(reason: String) {
        guard isSequenceSuppressingWindowMovement else {
            clearPointerSequenceState()
            return
        }

        let sequenceOwner = sequenceWindowMovementSuppressionOwner
        let sequenceWindow = pointerSequenceWindow ?? window
        let sequenceStartWindowFrame = startWindowFrame
        let sequenceLogName = logName
        let sequenceLogMetadata = logMetadata
        let sequenceGeneration = pointerSequenceGeneration

        sequenceWindowMovementSuppressionOwner = PointerWindowMovementSuppressionOwner()
        isSequenceSuppressingWindowMovement = false
        clearPointerSequenceState()

        DispatchQueue.main.async {
            [
                weak self,
                sequenceOwner,
                sequenceWindow,
                sequenceStartWindowFrame,
                sequenceLogName,
                sequenceLogMetadata,
                sequenceGeneration,
            ] in
            MainActor.assumeIsolated {
                if self?.pointerSequenceGeneration == sequenceGeneration {
                    Self.restoreSuppressedWindowFrameIfNeeded(
                        window: sequenceWindow,
                        startWindowFrame: sequenceStartWindowFrame,
                        reason: reason,
                        logName: sequenceLogName,
                        logMetadata: sequenceLogMetadata
                    )
                }
                WindowMovementSuppression.restore(owner: sequenceOwner, reason: "pointer-sequence")
            }
        }
    }

    private func clearPointerHoverForTeardown() {
        guard isPointerInside else { return }
        isPointerInside = false
        logCursorDiagnostic("pointer-outside-set")
        onHoverChanged?(false)
        if suppressesWindowMovementWhileHovered {
            scheduleHoverWindowMovementRestore()
        }
    }

    private func clearPointerSequenceState() {
        pointerSequenceWindow = nil
        startWindowFrame = nil
        startScreenLocation = nil
        startWindowLocation = nil
        startLocation = nil
        dragEventCount = 0
    }

    private func interactionValue(for event: NSEvent) -> PointerInteractionValue? {
        guard let startLocation else {
            return nil
        }

        let translation: CGSize
        if let startScreenLocation,
           let eventWindow = event.window ?? pointerSequenceWindow ?? window {
            let currentScreenLocation = eventWindow.convertPoint(toScreen: event.locationInWindow)
            translation = CGSize(
                width: currentScreenLocation.x - startScreenLocation.x,
                height: startScreenLocation.y - currentScreenLocation.y
            )
        } else if let startWindowLocation {
            let currentWindowLocation = event.locationInWindow
            translation = CGSize(
                width: currentWindowLocation.x - startWindowLocation.x,
                height: startWindowLocation.y - currentWindowLocation.y
            )
        } else {
            return nil
        }

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
        WindowMovementSuppression.suppress(
            window: window,
            owner: sequenceWindowMovementSuppressionOwner,
            reason: "pointer-sequence"
        )
        isSequenceSuppressingWindowMovement = true
        if let window {
            logWindowMovementSuppression(reason: "mouse-down", window: window)
        }
    }

    private func suppressWindowMovementForHover() {
        WindowMovementSuppression.suppress(
            window: window,
            owner: hoverWindowMovementSuppressionOwner,
            reason: "pointer-hover",
            options: .movement
        )
        if let window {
            logWindowMovementSuppression(reason: "pointer-hover-enter", window: window)
        }
    }

    private func restoreHoverWindowMovementIfNeeded() {
        WindowMovementSuppression.restore(owner: hoverWindowMovementSuppressionOwner, reason: "pointer-hover")
    }

    private func scheduleHoverWindowMovementRestore() {
        let hoverOwner = hoverWindowMovementSuppressionOwner
        hoverWindowMovementSuppressionOwner = PointerWindowMovementSuppressionOwner()
        Self.scheduleWindowMovementRestore(owner: hoverOwner, reason: "pointer-hover")
    }

    private nonisolated static func scheduleWindowMovementRestore(
        owner: PointerWindowMovementSuppressionOwner,
        reason: String
    ) {
        // Run on the next main-runloop turn so SwiftUI's dismantleNSView is
        // already off the stack before we mutate window properties (KVO from
        // those mutations re-enters SwiftUI's graph and crashes if dismantle
        // is still in progress).
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                WindowMovementSuppression.restore(owner: owner, reason: reason)
            }
        }
    }

    private func restoreSequenceWindowMovementIfNeeded(reason: String) {
        guard isSequenceSuppressingWindowMovement else { return }
        WindowMovementSuppression.restore(owner: sequenceWindowMovementSuppressionOwner, reason: "pointer-sequence")
        isSequenceSuppressingWindowMovement = false
        if let window = pointerSequenceWindow ?? window {
            logWindowMovementSuppression(reason: reason, window: window)
        }
    }

    private func restoreSuppressedWindowFrameIfNeeded(reason: String) {
        guard isSequenceSuppressingWindowMovement else {
            return
        }

        Self.restoreSuppressedWindowFrameIfNeeded(
            window: pointerSequenceWindow ?? window,
            startWindowFrame: startWindowFrame,
            reason: reason,
            logName: logName,
            logMetadata: logMetadata
        )
    }

    private static func restoreSuppressedWindowFrameIfNeeded(
        window: NSWindow?,
        startWindowFrame: CGRect?,
        reason: String,
        logName: String,
        logMetadata: [String: String]
    ) {
        guard let startWindowFrame,
              let window,
              framesEqual(window.frame, startWindowFrame) == false else {
            return
        }

        let driftedFrame = window.frame
        window.setFrame(startWindowFrame, display: true)
        logSuppressedWindowFrameRestore(
            name: logName,
            metadata: logMetadata,
            reason: reason,
            driftedFrame: driftedFrame,
            restoredFrame: startWindowFrame
        )
    }

    private static func framesEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < 0.5 &&
            abs(lhs.origin.y - rhs.origin.y) < 0.5 &&
            abs(lhs.size.width - rhs.size.width) < 0.5 &&
            abs(lhs.size.height - rhs.size.height) < 0.5
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
            metadata["windowFrame"] = DraggableInteractionLog.rectDescription(window.frame)
            let eventScreenLocation = window.convertPoint(toScreen: event.locationInWindow)
            metadata["eventScreenLocation"] = DraggableInteractionLog.pointDescription(eventScreenLocation)
            if let startScreenLocation {
                metadata["screenTranslation"] = DraggableInteractionLog.sizeDescription(
                    CGSize(
                        width: eventScreenLocation.x - startScreenLocation.x,
                        height: eventScreenLocation.y - startScreenLocation.y
                    )
                )
            }
            if let startWindowFrame {
                metadata["startWindowFrame"] = DraggableInteractionLog.rectDescription(startWindowFrame)
                metadata["windowFrameDelta"] = DraggableInteractionLog.sizeDescription(
                    CGSize(
                        width: window.frame.minX - startWindowFrame.minX,
                        height: window.frame.minY - startWindowFrame.minY
                    )
                )
            }
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
        metadata["startWindowLocationMissing"] = "\(startWindowLocation == nil)"
        if let reason {
            metadata["reason"] = reason
        }
        if let window = event.window ?? window {
            metadata["windowIsMovable"] = "\(window.isMovable)"
            metadata["windowIsMovableByWindowBackground"] = "\(window.isMovableByWindowBackground)"
            metadata["windowFrame"] = DraggableInteractionLog.rectDescription(window.frame)
        }
        ToasttyLog.info("draggable pointer tracking loop", category: .input, metadata: metadata)
    }

    func logLifecycleDiagnostic(_ phase: String) {
        var metadata = logMetadata
        metadata["name"] = logName
        metadata["phase"] = phase
        metadata["sequenceSuppressionActive"] = "\(isSequenceSuppressingWindowMovement)"
        metadata["trackingLoopActive"] = "\(isTrackingPointerSequence)"
        metadata["dragEventCount"] = "\(dragEventCount)"
        metadata["startWindowLocationMissing"] = "\(startWindowLocation == nil)"
        metadata["mouseDownCanMoveWindow"] = "\(mouseDownCanMoveWindow)"
        metadata["frame"] = DraggableInteractionLog.rectDescription(frame)
        metadata["bounds"] = DraggableInteractionLog.rectDescription(bounds)
        if let window {
            metadata["windowNumber"] = "\(window.windowNumber)"
            metadata["windowIsMovable"] = "\(window.isMovable)"
            metadata["windowIsMovableByWindowBackground"] = "\(window.isMovableByWindowBackground)"
            metadata["windowFrame"] = DraggableInteractionLog.rectDescription(window.frame)
        }
        ToasttyLog.debug("draggable pointer lifecycle", category: .input, metadata: metadata)
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
        metadata["windowIsMovableByWindowBackground"] = "\(window.isMovableByWindowBackground)"
        metadata["windowFrame"] = DraggableInteractionLog.rectDescription(window.frame)
        if let startWindowFrame {
            metadata["startWindowFrame"] = DraggableInteractionLog.rectDescription(startWindowFrame)
            metadata["windowFrameDelta"] = DraggableInteractionLog.sizeDescription(
                CGSize(
                    width: window.frame.minX - startWindowFrame.minX,
                    height: window.frame.minY - startWindowFrame.minY
                )
            )
        }
        metadata["sequenceSuppressionActive"] = "\(isSequenceSuppressingWindowMovement)"
        ToasttyLog.debug("draggable pointer window movement suppression", category: .input, metadata: metadata)
    }

    private static func logSuppressedWindowFrameRestore(
        name: String,
        metadata baseMetadata: [String: String],
        reason: String,
        driftedFrame: CGRect,
        restoredFrame: CGRect
    ) {
        var metadata = baseMetadata
        metadata["name"] = name
        metadata["reason"] = reason
        metadata["driftedFrame"] = DraggableInteractionLog.rectDescription(driftedFrame)
        metadata["restoredFrame"] = DraggableInteractionLog.rectDescription(restoredFrame)
        metadata["frameDelta"] = DraggableInteractionLog.sizeDescription(
            CGSize(
                width: driftedFrame.minX - restoredFrame.minX,
                height: driftedFrame.minY - restoredFrame.minY
            )
        )
        metadata["sizeDelta"] = DraggableInteractionLog.sizeDescription(
            CGSize(
                width: driftedFrame.width - restoredFrame.width,
                height: driftedFrame.height - restoredFrame.height
            )
        )
        ToasttyLog.debug("draggable pointer restored suppressed window frame", category: .input, metadata: metadata)
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
        false
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
