import AppKit
import SwiftUI

enum BoundaryInteractionAxis: Equatable {
    case vertical
    case horizontal
}

struct BoundaryInteractionValue: Equatable {
    let descriptorID: String
    let startLocation: CGPoint
    let location: CGPoint
    let translation: CGSize
}

struct BoundaryInteractionDescriptor {
    let id: String
    let hitFrame: CGRect
    let visualFrame: CGRect?
    let axis: BoundaryInteractionAxis
    let cursor: NSCursor?
    let accessibilityLabel: String?
    let accessibilityIdentifier: String?
    let metadata: [String: String]
    let onBegan: (BoundaryInteractionValue) -> Void
    let onChanged: (BoundaryInteractionValue) -> Void
    let onEnded: (BoundaryInteractionValue) -> Void
    let onHoverChanged: (Bool) -> Void

    init(
        id: String,
        hitFrame: CGRect,
        visualFrame: CGRect? = nil,
        axis: BoundaryInteractionAxis,
        cursor: NSCursor? = nil,
        accessibilityLabel: String? = nil,
        accessibilityIdentifier: String? = nil,
        metadata: [String: String] = [:],
        onBegan: @escaping (BoundaryInteractionValue) -> Void = { _ in },
        onChanged: @escaping (BoundaryInteractionValue) -> Void = { _ in },
        onEnded: @escaping (BoundaryInteractionValue) -> Void = { _ in },
        onHoverChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.id = id
        self.hitFrame = hitFrame
        self.visualFrame = visualFrame
        self.axis = axis
        self.cursor = cursor
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityIdentifier = accessibilityIdentifier
        self.metadata = metadata
        self.onBegan = onBegan
        self.onChanged = onChanged
        self.onEnded = onEnded
        self.onHoverChanged = onHoverChanged
    }
}

struct BoundaryInteractionOverlay: NSViewRepresentable {
    var descriptors: [BoundaryInteractionDescriptor]

    func makeNSView(context _: Context) -> BoundaryInteractionOverlayView {
        BoundaryInteractionOverlayView()
    }

    func updateNSView(_ nsView: BoundaryInteractionOverlayView, context _: Context) {
        nsView.updateDescriptors(descriptors, deliversCallbacksImmediately: false)
    }

    static func dismantleNSView(_ nsView: BoundaryInteractionOverlayView, coordinator _: ()) {
        nsView.invalidate(deliversCallbacksImmediately: false)
    }
}

final class BoundaryInteractionOverlayView: NSView {
    private static let trackingEventMask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
    private nonisolated static let windowMovementSuppressionReason = "boundary-interaction"

    var usesEventTrackingLoop = true
    var currentLocalMouseLocationProvider: (() -> CGPoint?)?
    var backingScaleFactorProvider: (() -> CGFloat?)?
    private(set) var boundaryTrackingAreaRebuildCount = 0

    private var orderedDescriptors: [BoundaryInteractionDescriptor] = []
    private var descriptorsByID: [String: BoundaryInteractionDescriptor] = [:]
    private var interactionSpecs: [BoundaryInteractionSpec] = []
    private var boundaryTrackingAreas: [NSTrackingArea] = []
    private var hoveredDescriptorID: String?
    private var hoveredDescriptor: BoundaryInteractionDescriptor?
    private var activeDescriptorID: String?
    private var capturedDescriptor: BoundaryInteractionDescriptor?
    private var startLocation: CGPoint?
    private var startWindowLocation: CGPoint?
    private var lastInteractionValue: BoundaryInteractionValue?
    private var lastKnownLocalMouseLocation: CGPoint?
    private var isSequenceSuppressingWindowMovement = false
    private var isTrackingBoundarySequence = false

    override var isFlipped: Bool { true }

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        postsFrameChangedNotifications = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    func updateDescriptors(
        _ descriptors: [BoundaryInteractionDescriptor],
        deliversCallbacksImmediately: Bool = true
    ) {
        orderedDescriptors = descriptors
            .filter { Self.validHitFrame($0.hitFrame) != nil }
        descriptorsByID.removeAll(keepingCapacity: true)
        for descriptor in orderedDescriptors {
            descriptorsByID[descriptor.id] = descriptor
        }

        updateAccessibility()
        refreshBoundaryInteractionRegionsIfNeeded()
        reconcileHoverAfterDescriptorUpdate(deliversCallbacksImmediately: deliversCallbacksImmediately)
        reconcileActiveDescriptorAfterDescriptorUpdate(deliversCallbacksImmediately: deliversCallbacksImmediately)
    }

    func invalidate(deliversCallbacksImmediately: Bool = true) {
        cancelBoundarySequence(
            reason: "invalidate",
            notifyEnded: true,
            deliversCallbacksImmediately: deliversCallbacksImmediately
        )
        setHoveredDescriptor(nil, deliversCallbacksImmediately: deliversCallbacksImmediately)
        removeBoundaryTrackingAreas()
        orderedDescriptors = []
        descriptorsByID = [:]
        interactionSpecs = []
        onAccessibilityUpdateAfterInvalidation()
    }

    func descriptorID(at location: CGPoint) -> String? {
        descriptor(at: location)?.id
    }

    func effectiveHitFrame(forDescriptorID id: String) -> CGRect? {
        guard let descriptor = orderedDescriptors.last(where: { $0.id == id }) else { return nil }
        return effectiveHitFrame(for: descriptor.hitFrame)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isHidden == false,
              alphaValue > 0.01,
              bounds.contains(point),
              descriptor(at: point) != nil else {
            return nil
        }

        return self
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for descriptor in orderedDescriptors {
            guard let cursor = descriptor.cursor,
                  let hitFrame = clippedEffectiveHitFrame(for: descriptor.hitFrame) else {
                continue
            }
            addCursorRect(hitFrame, cursor: cursor)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        rebuildBoundaryTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        let eventLocation = localLocation(for: event)
        if let currentLocation = currentLocalMouseLocation(),
           bounds.contains(currentLocation) {
            lastKnownLocalMouseLocation = currentLocation
            setHoveredDescriptor(descriptor(at: currentLocation))
            return
        }

        setHoveredDescriptor(descriptor(at: eventLocation))
    }

    override func cursorUpdate(with event: NSEvent) {
        let location = localLocation(for: event)
        if let descriptor = descriptor(at: location),
           let cursor = descriptor.cursor {
            cursor.set()
            setHoveredDescriptor(descriptor)
            return
        }

        setHoveredDescriptor(nil)
        super.cursorUpdate(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let location = localLocation(for: event)
        guard let descriptor = descriptor(at: location) else {
            super.mouseDown(with: event)
            return
        }

        setHoveredDescriptor(descriptor)
        beginBoundarySequence(with: event, descriptor: descriptor)
        guard usesEventTrackingLoop else { return }
        trackBoundarySequence(startingWith: event)
    }

    override func mouseDragged(with event: NSEvent) {
        handleBoundaryDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        finishBoundarySequence(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            setHoveredDescriptor(nil)
            if isTrackingBoundarySequence == false {
                cancelBoundarySequence(
                    reason: "removed-from-window",
                    notifyEnded: true,
                    deliversCallbacksImmediately: true
                )
            }
        } else {
            refreshBoundaryInteractionRegionsIfNeeded(force: true)
            reconcileHoverAfterDescriptorUpdate(deliversCallbacksImmediately: true)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshBoundaryInteractionRegionsIfNeeded(force: true)
        reconcileHoverAfterDescriptorUpdate(deliversCallbacksImmediately: true)
    }

    deinit {
        let ownerID = ObjectIdentifier(self)
        let reason = Self.windowMovementSuppressionReason
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                WindowMovementSuppression.restore(ownerID: ownerID, reason: reason)
            }
        } else {
            Task { @MainActor in
                WindowMovementSuppression.restore(ownerID: ownerID, reason: reason)
            }
        }
    }

    private func descriptor(at location: CGPoint) -> BoundaryInteractionDescriptor? {
        orderedDescriptors.reversed().first { descriptor in
            guard let hitFrame = effectiveHitFrame(for: descriptor.hitFrame) else { return false }
            return hitFrame.contains(location)
        }
    }

    private func updateHover(with event: NSEvent) {
        let location = localLocation(for: event)
        setHoveredDescriptor(descriptor(at: location))
    }

    private func reconcileHoverAfterDescriptorUpdate(deliversCallbacksImmediately: Bool) {
        guard let location = currentLocalMouseLocation() ?? lastKnownLocalMouseLocation,
              bounds.contains(location) else {
            setHoveredDescriptor(nil, deliversCallbacksImmediately: deliversCallbacksImmediately)
            return
        }

        lastKnownLocalMouseLocation = location
        setHoveredDescriptor(
            descriptor(at: location),
            deliversCallbacksImmediately: deliversCallbacksImmediately
        )
    }

    private func reconcileActiveDescriptorAfterDescriptorUpdate(deliversCallbacksImmediately: Bool) {
        guard let activeDescriptorID,
              descriptorsByID[activeDescriptorID] == nil else {
            return
        }

        cancelBoundarySequence(
            reason: "descriptor-removed",
            notifyEnded: true,
            deliversCallbacksImmediately: deliversCallbacksImmediately
        )
    }

    private func setHoveredDescriptor(
        _ descriptor: BoundaryInteractionDescriptor?,
        deliversCallbacksImmediately: Bool = true
    ) {
        let nextID = descriptor?.id
        guard hoveredDescriptorID != nextID else {
            if let descriptor {
                hoveredDescriptor = descriptor
                descriptor.cursor?.set()
            }
            return
        }

        let previous = hoveredDescriptor
        hoveredDescriptorID = nextID
        hoveredDescriptor = descriptor
        descriptor?.cursor?.set()
        deliverCallback(immediately: deliversCallbacksImmediately) {
            previous?.onHoverChanged(false)
            descriptor?.onHoverChanged(true)
        }
    }

    private func beginBoundarySequence(
        with event: NSEvent,
        descriptor: BoundaryInteractionDescriptor
    ) {
        activeDescriptorID = descriptor.id
        capturedDescriptor = descriptor
        startWindowLocation = event.locationInWindow
        startLocation = localLocation(for: event)
        lastInteractionValue = boundaryValue(
            descriptorID: descriptor.id,
            startLocation: startLocation ?? .zero,
            location: startLocation ?? .zero
        )
        suppressWindowMovementForCurrentSequence()
        if let lastInteractionValue {
            descriptor.onBegan(lastInteractionValue)
        }
    }

    private func handleBoundaryDragged(with event: NSEvent) {
        guard let activeDescriptorID else { return }
        guard let descriptor = descriptorsByID[activeDescriptorID] else {
            cancelBoundarySequence(reason: "descriptor-missing-during-drag", notifyEnded: true)
            return
        }
        guard let value = interactionValue(for: event) else {
            cancelBoundarySequence(reason: "drag-without-start", notifyEnded: true)
            return
        }

        lastInteractionValue = value
        descriptor.onChanged(value)
    }

    private func finishBoundarySequence(with event: NSEvent) {
        guard let activeDescriptorID else { return }
        let descriptor = descriptorsByID[activeDescriptorID] ?? capturedDescriptor
        guard let value = interactionValue(for: event),
              let descriptor else {
            cancelBoundarySequence(reason: "mouse-up-without-start", notifyEnded: true)
            return
        }

        clearBoundarySequenceState()
        restoreSequenceWindowMovementIfNeeded(reason: "mouse-up")
        descriptor.onEnded(value)
    }

    private func trackBoundarySequence(startingWith event: NSEvent) {
        guard let trackingWindow = event.window ?? window else {
            cancelBoundarySequence(
                reason: "missing-window",
                notifyEnded: true,
                deliversCallbacksImmediately: true
            )
            return
        }

        isTrackingBoundarySequence = true
        defer {
            isTrackingBoundarySequence = false
        }

        while activeDescriptorID != nil {
            let timeout = Date(timeIntervalSinceNow: 60)
            guard let nextEvent = trackingWindow.nextEvent(
                matching: Self.trackingEventMask,
                until: timeout,
                inMode: .eventTracking,
                dequeue: true
            ) else {
                cancelBoundarySequence(
                    reason: "tracking-timeout",
                    notifyEnded: true,
                    deliversCallbacksImmediately: true
                )
                return
            }

            switch nextEvent.type {
            case .leftMouseDragged:
                handleBoundaryDragged(with: nextEvent)

            case .leftMouseUp:
                finishBoundarySequence(with: nextEvent)
                return

            default:
                break
            }
        }
    }

    private func cancelBoundarySequence(
        reason _: String,
        notifyEnded: Bool,
        deliversCallbacksImmediately: Bool = true
    ) {
        guard activeDescriptorID != nil ||
            startLocation != nil ||
            startWindowLocation != nil else {
            restoreSequenceWindowMovementIfNeeded(reason: "cancel-without-active-sequence")
            return
        }

        let descriptor = capturedDescriptor
        let value = lastInteractionValue
        clearBoundarySequenceState()
        restoreSequenceWindowMovementIfNeeded(reason: "cancel")
        if notifyEnded,
           let descriptor,
           let value {
            deliverCallback(immediately: deliversCallbacksImmediately) {
                descriptor.onEnded(value)
            }
        }
    }

    private func clearBoundarySequenceState() {
        activeDescriptorID = nil
        capturedDescriptor = nil
        startLocation = nil
        startWindowLocation = nil
        lastInteractionValue = nil
    }

    private func interactionValue(for event: NSEvent) -> BoundaryInteractionValue? {
        guard let activeDescriptorID,
              let startLocation else {
            return nil
        }

        return boundaryValue(
            descriptorID: activeDescriptorID,
            startLocation: startLocation,
            location: localLocation(for: event)
        )
    }

    private func boundaryValue(
        descriptorID: String,
        startLocation: CGPoint,
        location: CGPoint
    ) -> BoundaryInteractionValue {
        BoundaryInteractionValue(
            descriptorID: descriptorID,
            startLocation: startLocation,
            location: location,
            translation: CGSize(
                width: location.x - startLocation.x,
                height: location.y - startLocation.y
            )
        )
    }

    private func localLocation(for event: NSEvent) -> CGPoint {
        let location = convert(event.locationInWindow, from: nil)
        lastKnownLocalMouseLocation = location
        return location
    }

    private func currentLocalMouseLocation() -> CGPoint? {
        if let currentLocalMouseLocationProvider {
            return currentLocalMouseLocationProvider()
        }
        guard let window else { return nil }
        return convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    private func suppressWindowMovementForCurrentSequence() {
        guard isSequenceSuppressingWindowMovement == false else { return }
        guard window != nil else { return }
        WindowMovementSuppression.suppress(
            window: window,
            owner: self,
            reason: Self.windowMovementSuppressionReason
        )
        isSequenceSuppressingWindowMovement = true
    }

    private func restoreSequenceWindowMovementIfNeeded(reason _: String) {
        guard isSequenceSuppressingWindowMovement else { return }
        WindowMovementSuppression.restore(owner: self, reason: Self.windowMovementSuppressionReason)
        isSequenceSuppressingWindowMovement = false
    }

    private func removeBoundaryTrackingAreas() {
        for trackingArea in boundaryTrackingAreas {
            removeTrackingArea(trackingArea)
        }
        boundaryTrackingAreas.removeAll()
    }

    private func refreshBoundaryInteractionRegionsIfNeeded(force: Bool = false) {
        let nextSpecs = interactionSpecs(for: orderedDescriptors)
        let didChange = interactionSpecs != nextSpecs
        interactionSpecs = nextSpecs

        guard force || didChange else { return }
        rebuildBoundaryTrackingAreas()
        window?.invalidateCursorRects(for: self)
    }

    private func rebuildBoundaryTrackingAreas() {
        removeBoundaryTrackingAreas()
        boundaryTrackingAreaRebuildCount += 1

        for descriptor in orderedDescriptors {
            guard let hitFrame = clippedEffectiveHitFrame(for: descriptor.hitFrame) else { continue }
            let trackingArea = NSTrackingArea(
                rect: hitFrame,
                options: [
                    .activeAlways,
                    .enabledDuringMouseDrag,
                    .mouseEnteredAndExited,
                    .mouseMoved,
                    .cursorUpdate,
                ],
                owner: self,
                userInfo: ["id": descriptor.id]
            )
            addTrackingArea(trackingArea)
            boundaryTrackingAreas.append(trackingArea)
        }
    }

    private func updateAccessibility() {
        guard orderedDescriptors.count == 1,
              let descriptor = orderedDescriptors.first else {
            onAccessibilityUpdateAfterInvalidation()
            return
        }

        setAccessibilityElement(true)
        setAccessibilityLabel(descriptor.accessibilityLabel)
        setAccessibilityIdentifier(descriptor.accessibilityIdentifier)
    }

    private func onAccessibilityUpdateAfterInvalidation() {
        setAccessibilityElement(false)
        setAccessibilityLabel(nil)
        setAccessibilityIdentifier(nil)
    }

    private func deliverCallback(
        immediately: Bool,
        _ callback: @escaping () -> Void
    ) {
        if immediately {
            callback()
        } else {
            DispatchQueue.main.async {
                callback()
            }
        }
    }

    private func interactionSpecs(
        for descriptors: [BoundaryInteractionDescriptor]
    ) -> [BoundaryInteractionSpec] {
        descriptors.compactMap { descriptor in
            guard let hitFrame = effectiveHitFrame(for: descriptor.hitFrame) else { return nil }
            return BoundaryInteractionSpec(
                id: descriptor.id,
                hitFrame: hitFrame,
                axis: descriptor.axis,
                cursorID: descriptor.cursor.map(ObjectIdentifier.init),
                accessibilityLabel: descriptor.accessibilityLabel,
                accessibilityIdentifier: descriptor.accessibilityIdentifier
            )
        }
    }

    private func clippedEffectiveHitFrame(for frame: CGRect) -> CGRect? {
        guard let effectiveFrame = effectiveHitFrame(for: frame) else { return nil }
        let clippedFrame = bounds.intersection(effectiveFrame)
        guard clippedFrame.isNull == false,
              clippedFrame.isInfinite == false,
              clippedFrame.isEmpty == false else {
            return nil
        }
        return clippedFrame
    }

    private func effectiveHitFrame(for frame: CGRect) -> CGRect? {
        guard let standardized = Self.validHitFrame(frame) else { return nil }

        let scale = backingScaleFactor()
        let minX = floor(standardized.minX * scale) / scale
        let minY = floor(standardized.minY * scale) / scale
        let maxX = ceil(standardized.maxX * scale) / scale
        let maxY = ceil(standardized.maxY * scale) / scale
        let alignedFrame = CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        ).standardized
        return Self.validHitFrame(alignedFrame) ?? standardized
    }

    private func backingScaleFactor() -> CGFloat {
        let candidate = backingScaleFactorProvider?() ??
            window?.backingScaleFactor ??
            NSScreen.main?.backingScaleFactor ??
            1
        guard candidate.isFinite,
              candidate > 0 else {
            return 1
        }
        return candidate
    }

    private static func validHitFrame(_ frame: CGRect) -> CGRect? {
        let standardized = frame.standardized
        guard standardized.isNull == false,
              standardized.isInfinite == false,
              standardized.isEmpty == false else {
            return nil
        }
        return standardized
    }
}

private struct BoundaryInteractionSpec: Equatable {
    let id: String
    let hitFrame: CGRect
    let axis: BoundaryInteractionAxis
    let cursorID: ObjectIdentifier?
    let accessibilityLabel: String?
    let accessibilityIdentifier: String?
}
