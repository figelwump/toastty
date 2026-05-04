import AppKit
import CoreState
import SwiftUI

enum CursorDiagnostics {
    static let environmentKey = "TOASTTY_BOUNDARY_CURSOR_DIAGNOSTICS"
    static let enabled = truthy(ProcessInfo.processInfo.environment[environmentKey])

    static func cursorDescription(_ cursor: NSCursor) -> String {
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

    @MainActor
    static func hitTestMetadata(
        window: NSWindow?,
        windowLocation: CGPoint,
        referenceView: NSView?
    ) -> [String: String] {
        guard let contentView = window?.contentView else {
            return ["windowHitView": "nil"]
        }

        let contentLocation = contentView.convert(windowLocation, from: nil)
        let hitView = contentView.hitTest(contentLocation)
        return [
            "windowHitView": viewDescription(hitView),
            "windowHitViewHierarchy": viewHierarchyDescription(hitView, stopAt: referenceView),
        ]
    }

    @MainActor
    static func viewDescription(_ view: NSView?) -> String {
        guard let view else { return "nil" }
        return String(describing: type(of: view))
    }

    @MainActor
    static func viewHierarchyDescription(
        _ view: NSView?,
        stopAt: NSView? = nil,
        maxDepth: Int = 8
    ) -> String {
        var currentView = view
        var descriptions: [String] = []
        var depth = 0

        while let view = currentView, depth < maxDepth {
            descriptions.append(viewDescription(view))
            if let stopAt, view === stopAt {
                break
            }
            currentView = view.superview
            depth += 1
        }

        return descriptions.joined(separator: " <- ")
    }

    private static func truthy(_ value: String?) -> Bool {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return normalized == "1" || normalized == "true" || normalized == "yes" || normalized == "on"
    }
}

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
    private static let cursorOwnershipInterval: TimeInterval = 1.0 / 120.0

    var usesEventTrackingLoop = true
    var currentLocalMouseLocationProvider: (() -> CGPoint?)?
    var backingScaleFactorProvider: (() -> CGFloat?)?
    #if DEBUG
    var currentCursorProvider: () -> NSCursor = { NSCursor.current }
    var cursorSetter: (NSCursor) -> Void = { $0.set() }
    #endif
    private(set) var boundaryTrackingAreaRebuildCount = 0
    private(set) var deferredCursorReassertionCount = 0
    var hasPendingCursorReassertion: Bool {
        pendingCursorReassertionDescriptorID != nil
    }
    var hasScheduledCursorOwnershipCheck: Bool {
        isCursorOwnershipCheckScheduled
    }

    #if DEBUG
    func performCursorReassertionForTesting(descriptorID: String) {
        pendingCursorReassertionDescriptorID = descriptorID
        performPendingCursorReassertion()
    }

    func performCursorOwnershipCheckForTesting() {
        performCursorOwnershipCheck()
    }
    #endif

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
    private var pendingCursorReassertionDescriptorID: String?
    private var isCursorReassertionScheduled = false
    private var cursorOwnershipDescriptorID: String?
    private var isCursorOwnershipCheckScheduled = false
    private var cursorOwnershipSampleCount = 0
    private var lastCursorOwnershipSnapshot: BoundaryCursorOwnershipSnapshot?
    private(set) var cursorOwnershipReassertionCount = 0

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
        stopCursorOwnership()
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
        logCursorDiagnostic("reset-cursor-rects")
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
            let descriptor = descriptor(at: currentLocation)
            logCursorDiagnostic(
                "mouse-exited-current-location-inside",
                descriptor: descriptor,
                event: event,
                location: currentLocation
            )
            setHoveredDescriptor(descriptor)
            return
        }

        let descriptor = descriptor(at: eventLocation)
        logCursorDiagnostic("mouse-exited", descriptor: descriptor, event: event, location: eventLocation)
        setHoveredDescriptor(descriptor)
    }

    override func cursorUpdate(with event: NSEvent) {
        let (descriptor, location, locationSource) = cursorDescriptor(for: event)
        if let descriptor,
           let cursor = descriptor.cursor {
            logCursorDiagnostic(
                "cursor-update-set",
                descriptor: descriptor,
                event: event,
                location: location,
                extraMetadata: ["locationSource": locationSource]
            )
            setCursor(cursor)
            setHoveredDescriptor(descriptor)
            return
        }

        logCursorDiagnostic(
            "cursor-update-defer",
            descriptor: descriptor,
            event: event,
            location: location,
            extraMetadata: ["locationSource": locationSource]
        )
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
            logCursorDiagnostic("view-did-move-to-window-removed")
            setHoveredDescriptor(nil)
            if isTrackingBoundarySequence == false {
                cancelBoundarySequence(
                    reason: "removed-from-window",
                    notifyEnded: true,
                    deliversCallbacksImmediately: true
                )
            }
        } else {
            logCursorDiagnostic("view-did-move-to-window-attached")
            refreshBoundaryInteractionRegionsIfNeeded(force: true)
            reconcileHoverAfterDescriptorUpdate(deliversCallbacksImmediately: true)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        logCursorDiagnostic("view-did-change-backing-properties-before-refresh")
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
        let descriptor = descriptor(at: location)
        logCursorDiagnostic("mouse-hover", descriptor: descriptor, event: event, location: location)
        setHoveredDescriptor(descriptor)
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
                logCursorDiagnostic("hover-same-reapply-cursor", descriptor: descriptor)
                if let cursor = descriptor.cursor {
                    setCursor(cursor)
                }
                scheduleCursorReassertion(for: descriptor)
                startCursorOwnership(for: descriptor)
            } else {
                cancelCursorReassertion()
                stopCursorOwnership()
            }
            return
        }

        let previous = hoveredDescriptor
        logCursorDiagnostic(
            "hover-change",
            descriptor: descriptor,
            extraMetadata: [
                "previousDescriptorID": previous?.id ?? "nil",
                "nextDescriptorID": nextID ?? "nil",
            ]
        )
        hoveredDescriptorID = nextID
        hoveredDescriptor = descriptor
        if let descriptor {
            if let cursor = descriptor.cursor {
                setCursor(cursor)
            }
            scheduleCursorReassertion(for: descriptor)
            startCursorOwnership(for: descriptor)
        } else {
            cancelCursorReassertion()
            stopCursorOwnership()
        }
        deliverCallback(immediately: deliversCallbacksImmediately) {
            previous?.onHoverChanged(false)
            descriptor?.onHoverChanged(true)
        }
    }

    private func scheduleCursorReassertion(for descriptor: BoundaryInteractionDescriptor) {
        guard descriptor.cursor != nil else {
            cancelCursorReassertion()
            return
        }

        pendingCursorReassertionDescriptorID = descriptor.id
        guard isCursorReassertionScheduled == false else { return }
        isCursorReassertionScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.performPendingCursorReassertion()
        }
    }

    private func cancelCursorReassertion() {
        pendingCursorReassertionDescriptorID = nil
    }

    private func performPendingCursorReassertion() {
        isCursorReassertionScheduled = false
        guard let descriptorID = pendingCursorReassertionDescriptorID else { return }
        pendingCursorReassertionDescriptorID = nil

        guard let location = currentLocalMouseLocation(),
              bounds.contains(location),
              let descriptor = descriptor(at: location),
              descriptor.id == descriptorID,
              let cursor = descriptor.cursor else {
            return
        }

        deferredCursorReassertionCount += 1
        logCursorDiagnostic(
            "deferred-cursor-reassert",
            descriptor: descriptor,
            location: location
        )
        setCursor(cursor)
    }

    private func startCursorOwnership(for descriptor: BoundaryInteractionDescriptor) {
        guard descriptor.cursor != nil else {
            stopCursorOwnership()
            return
        }

        if cursorOwnershipDescriptorID != descriptor.id {
            cursorOwnershipSampleCount = 0
            lastCursorOwnershipSnapshot = nil
        }
        cursorOwnershipDescriptorID = descriptor.id
        scheduleCursorOwnershipCheck()
    }

    private func stopCursorOwnership() {
        cursorOwnershipDescriptorID = nil
        lastCursorOwnershipSnapshot = nil
    }

    private func scheduleCursorOwnershipCheck() {
        guard cursorOwnershipDescriptorID != nil,
              isCursorOwnershipCheckScheduled == false else {
            return
        }

        isCursorOwnershipCheckScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.cursorOwnershipInterval) { [weak self] in
            self?.performCursorOwnershipCheck()
        }
    }

    private func performCursorOwnershipCheck() {
        isCursorOwnershipCheckScheduled = false
        guard let descriptorID = cursorOwnershipDescriptorID else {
            return
        }

        guard let location = currentLocalMouseLocation(),
              bounds.contains(location),
              let descriptor = descriptor(at: location),
              descriptor.id == descriptorID,
              let targetCursor = descriptor.cursor else {
            stopCursorOwnership()
            return
        }

        cursorOwnershipSampleCount += 1
        let currentCursor = currentCursorForOwnership()
        let currentCursorMatchesTarget = currentCursor === targetCursor
        if currentCursorMatchesTarget == false {
            cursorOwnershipReassertionCount += 1
            setCursor(targetCursor)
        }

        logCursorOwnershipSampleIfNeeded(
            descriptor: descriptor,
            targetCursor: targetCursor,
            currentCursor: currentCursor,
            currentCursorMatchesTarget: currentCursorMatchesTarget,
            location: location
        )

        scheduleCursorOwnershipCheck()
    }

    private func logCursorOwnershipSampleIfNeeded(
        descriptor: BoundaryInteractionDescriptor,
        targetCursor: NSCursor,
        currentCursor: NSCursor,
        currentCursorMatchesTarget: Bool,
        location: CGPoint
    ) {
        guard CursorDiagnostics.enabled else { return }

        let windowMouseLocation = window?.mouseLocationOutsideOfEventStream
        var metadata: [String: String] = [
            "descriptorID": descriptor.id,
            "descriptorCursor": CursorDiagnostics.cursorDescription(targetCursor),
            "currentCursor": CursorDiagnostics.cursorDescription(currentCursor),
            "currentCursorMatchesDescriptor": "\(currentCursorMatchesTarget)",
            "reassertedCursor": "\(currentCursorMatchesTarget == false)",
            "sampleCount": "\(cursorOwnershipSampleCount)",
            "localMouseLocation": Self.pointDescription(location),
            "bounds": Self.rectDescription(bounds),
            "descriptorHitFrame": Self.rectDescription(descriptor.hitFrame),
            "descriptorEffectiveHitFrame": effectiveHitFrame(for: descriptor.hitFrame)
                .map(Self.rectDescription) ?? "nil",
            "overlayHitView": CursorDiagnostics.viewDescription(hitTest(location)),
        ]
        if let windowMouseLocation {
            metadata["windowMouseLocation"] = Self.pointDescription(windowMouseLocation)
            metadata.merge(
                CursorDiagnostics.hitTestMetadata(
                    window: window,
                    windowLocation: windowMouseLocation,
                    referenceView: self
                ),
                uniquingKeysWith: { _, new in new }
            )
        }
        for (key, value) in descriptor.metadata {
            metadata["descriptor.\(key)"] = value
        }

        let snapshot = BoundaryCursorOwnershipSnapshot(
            descriptorID: descriptor.id,
            currentCursorID: ObjectIdentifier(currentCursor),
            currentCursorMatchesDescriptor: currentCursorMatchesTarget,
            windowHitViewHierarchy: metadata["windowHitViewHierarchy"] ?? "nil"
        )
        if snapshot != lastCursorOwnershipSnapshot || snapshot.currentCursorMatchesDescriptor == false {
            ToasttyLog.info(
                "boundary cursor ownership sample",
                category: .input,
                metadata: metadata
            )
            lastCursorOwnershipSnapshot = snapshot
        }
    }

    private func setCursor(_ cursor: NSCursor) {
        #if DEBUG
        cursorSetter(cursor)
        #else
        cursor.set()
        #endif
    }

    private func currentCursorForOwnership() -> NSCursor {
        #if DEBUG
        currentCursorProvider()
        #else
        NSCursor.current
        #endif
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
        logCursorDiagnostic(
            force ? "refresh-regions-forced" : "refresh-regions-changed",
            extraMetadata: [
                "specCount": "\(nextSpecs.count)",
                "didChange": "\(didChange)",
            ]
        )
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
        logCursorDiagnostic(
            "tracking-areas-rebuilt",
            extraMetadata: [
                "trackingAreaCount": "\(boundaryTrackingAreas.count)",
                "rebuildCount": "\(boundaryTrackingAreaRebuildCount)",
            ]
        )
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

    private func cursorDescriptor(for event: NSEvent) -> (BoundaryInteractionDescriptor?, CGPoint, String) {
        let eventLocation = localLocation(for: event)
        let eventDescriptor = descriptor(at: eventLocation)

        if let currentLocation = currentLocalMouseLocation() {
            lastKnownLocalMouseLocation = currentLocation
            if bounds.contains(currentLocation) {
                if let currentDescriptor = descriptor(at: currentLocation) {
                    let source = eventDescriptor?.id == currentDescriptor.id
                        ? "current-window-location"
                        : "current-window-location-corrected"
                    return (currentDescriptor, currentLocation, source)
                }

                if eventDescriptor != nil {
                    return (nil, currentLocation, "current-window-location-outside-descriptor")
                }
            } else if eventDescriptor != nil {
                return (nil, currentLocation, "current-window-location-outside-bounds")
            }
        }

        if let eventDescriptor {
            return (eventDescriptor, eventLocation, "event-location")
        }

        return (nil, eventLocation, "none")
    }

    private func logCursorDiagnostic(
        _ phase: String,
        descriptor: BoundaryInteractionDescriptor? = nil,
        event: NSEvent? = nil,
        location: CGPoint? = nil,
        extraMetadata: [String: String] = [:]
    ) {
        guard CursorDiagnostics.enabled else { return }

        var metadata = extraMetadata
        metadata["phase"] = phase
        metadata["frame"] = Self.rectDescription(frame)
        metadata["bounds"] = Self.rectDescription(bounds)
        metadata["visibleRect"] = Self.rectDescription(visibleRect)
        metadata["hoveredDescriptorID"] = hoveredDescriptorID ?? "nil"
        metadata["activeDescriptorID"] = activeDescriptorID ?? "nil"
        metadata["descriptorCount"] = "\(orderedDescriptors.count)"
        metadata["trackingAreaCount"] = "\(boundaryTrackingAreas.count)"
        metadata["rebuildCount"] = "\(boundaryTrackingAreaRebuildCount)"
        metadata["pendingCursorReassertionDescriptorID"] = pendingCursorReassertionDescriptorID ?? "nil"
        metadata["isCursorReassertionScheduled"] = "\(isCursorReassertionScheduled)"
        metadata["deferredCursorReassertionCount"] = "\(deferredCursorReassertionCount)"
        metadata["backingScaleFactor"] = String(format: "%.3f", backingScaleFactor())
        metadata["currentCursor"] = CursorDiagnostics.cursorDescription(NSCursor.current)

        if let descriptor {
            metadata["descriptorID"] = descriptor.id
            metadata["descriptorHitFrame"] = Self.rectDescription(descriptor.hitFrame)
            metadata["descriptorEffectiveHitFrame"] = effectiveHitFrame(for: descriptor.hitFrame)
                .map(Self.rectDescription) ?? "nil"
            metadata["descriptorCursor"] = descriptor.cursor.map(CursorDiagnostics.cursorDescription) ?? "nil"
            if let cursor = descriptor.cursor {
                metadata["currentCursorMatchesDescriptor"] = "\(NSCursor.current === cursor)"
            }
            for (key, value) in descriptor.metadata {
                metadata["descriptor.\(key)"] = value
            }
        }

        if let event {
            metadata["eventType"] = Self.eventTypeDescription(event.type)
            metadata["eventWindowLocation"] = Self.pointDescription(event.locationInWindow)
            let eventLocalLocation = convert(event.locationInWindow, from: nil)
            metadata["eventLocalLocation"] = Self.pointDescription(eventLocalLocation)
            metadata["eventDescriptorID"] = self.descriptor(at: eventLocalLocation)?.id ?? "nil"
        }

        if let location {
            metadata["resolvedLocalLocation"] = Self.pointDescription(location)
            metadata["resolvedDescriptorID"] = self.descriptor(at: location)?.id ?? "nil"
        }

        if let window {
            let windowMouseLocation = window.mouseLocationOutsideOfEventStream
            let localMouseLocation = convert(windowMouseLocation, from: nil)
            metadata["windowNumber"] = "\(window.windowNumber)"
            metadata["windowBackingScaleFactor"] = String(format: "%.3f", window.backingScaleFactor)
            metadata["windowCursorRectsEnabled"] = "\(window.areCursorRectsEnabled)"
            metadata["windowMouseLocation"] = Self.pointDescription(windowMouseLocation)
            metadata["currentLocalMouseLocation"] = Self.pointDescription(localMouseLocation)
            metadata["currentLocalMouseInsideBounds"] = "\(bounds.contains(localMouseLocation))"
            metadata["currentDescriptorID"] = self.descriptor(at: localMouseLocation)?.id ?? "nil"
            if let screen = window.screen {
                metadata["screenName"] = screen.localizedName
                metadata["screenFrame"] = Self.rectDescription(screen.frame)
                metadata["screenBackingScaleFactor"] = String(format: "%.3f", screen.backingScaleFactor)
            }
        }

        ToasttyLog.info(
            "boundary cursor diagnostic",
            category: .input,
            metadata: metadata
        )
    }

    private static func pointDescription(_ point: CGPoint) -> String {
        String(format: "%.1f,%.1f", point.x, point.y)
    }

    private static func rectDescription(_ rect: CGRect) -> String {
        String(format: "%.1f,%.1f %.1fx%.1f", rect.minX, rect.minY, rect.width, rect.height)
    }

    private static func eventTypeDescription(_ eventType: NSEvent.EventType) -> String {
        switch eventType {
        case .leftMouseDown:
            return "leftMouseDown"
        case .leftMouseDragged:
            return "leftMouseDragged"
        case .leftMouseUp:
            return "leftMouseUp"
        case .mouseEntered:
            return "mouseEntered"
        case .mouseExited:
            return "mouseExited"
        case .mouseMoved:
            return "mouseMoved"
        case .cursorUpdate:
            return "cursorUpdate"
        default:
            return "\(eventType.rawValue)"
        }
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

private struct BoundaryCursorOwnershipSnapshot: Equatable {
    let descriptorID: String
    let currentCursorID: ObjectIdentifier
    let currentCursorMatchesDescriptor: Bool
    let windowHitViewHierarchy: String
}

struct BoundaryResizeHandleVisual: View {
    let highlighted: Bool
    let appIsActive: Bool
    let width: CGFloat

    var body: some View {
        ZStack {
            Rectangle()
                .fill(fillColor)
                .frame(width: width)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.12), value: highlighted)
    }

    private var fillColor: Color {
        highlighted
            ? ToastyTheme.accent.opacity(appIsActive ? 0.9 : 0.55)
            : ToastyTheme.hairline
    }
}
