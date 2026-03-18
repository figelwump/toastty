import AppKit
import Foundation
import UniformTypeIdentifiers
#if TOASTTY_HAS_GHOSTTY_KIT
import CoreState
import GhosttyKit
#endif

private extension NSView {
    var hasHiddenAncestor: Bool {
        var ancestor = superview
        while let current = ancestor {
            if current.isHidden {
                return true
            }
            ancestor = current.superview
        }
        return false
    }
}

final class TerminalHostView: NSView {
    var resolveImageFileDrop: (([URL]) -> PreparedImageFileDrop?)?
    var performImageFileDrop: ((PreparedImageFileDrop) -> Bool)?
    /// Gives the owning controller a chance to reclaim AppKit first responder
    /// when the host view finishes attaching or becomes visible again.
    var requestFirstResponderIfNeeded: (() -> Void)?
    private var pendingImageFileDrop: PreparedImageFileDrop?
    private var pendingVisibilitySyncTask: Task<Void, Never>?
    private var mouseTrackingArea: NSTrackingArea?
    private weak var observedWindow: NSWindow?
    private var windowOcclusionObserver: NSObjectProtocol?
    private var lastKnownSurfaceVisibility: Bool?
    private(set) var isEffectivelyVisible = false
    var applicationIsActiveProvider: () -> Bool = { NSApp.isActive }

    private static let imageFileURLReadOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true,
        .urlReadingContentsConformToTypes: [UTType.image.identifier],
    ]

    #if TOASTTY_HAS_GHOSTTY_KIT
    private var lastLoggedVisibilityTraceSnapshot: VisibilityTraceSnapshot?

    enum GhosttyMouseCursorStyle: Equatable {
        case `default`
        case grabIdle
        case grabActive
        case horizontalText
        case verticalText
        case link
        case resizeLeft
        case resizeRight
        case resizeUp
        case resizeDown
        case resizeUpDown
        case resizeLeftRight
        case contextMenu
        case crosshair
        case operationNotAllowed

        var nsCursor: NSCursor {
            switch self {
            case .default:
                return .arrow
            case .grabIdle:
                return .openHand
            case .grabActive:
                return .closedHand
            case .horizontalText:
                return .iBeam
            case .verticalText:
                return .iBeamCursorForVerticalLayout
            case .link:
                return .pointingHand
            case .resizeLeft:
                if #available(macOS 15.0, *) {
                    return .columnResize(directions: .left)
                }
                return .resizeLeft
            case .resizeRight:
                if #available(macOS 15.0, *) {
                    return .columnResize(directions: .right)
                }
                return .resizeRight
            case .resizeUp:
                if #available(macOS 15.0, *) {
                    return .rowResize(directions: .up)
                }
                return .resizeUp
            case .resizeDown:
                if #available(macOS 15.0, *) {
                    return .rowResize(directions: .down)
                }
                return .resizeDown
            case .resizeUpDown:
                if #available(macOS 15.0, *) {
                    return .rowResize
                }
                return .resizeUpDown
            case .resizeLeftRight:
                if #available(macOS 15.0, *) {
                    return .columnResize
                }
                return .resizeLeftRight
            case .contextMenu:
                return .contextualMenu
            case .crosshair:
                return .crosshair
            case .operationNotAllowed:
                return .operationNotAllowed
            }
        }
    }

    private var ghosttySurface: ghostty_surface_t?
    /// Tracks the last focus value sent to Ghostty to avoid redundant calls.
    /// Each `ghostty_surface_set_focus` call restarts the internal cursor blink
    /// timer; calling it on every layout pass causes irregular blinking and
    /// input jitter. `nil` means the live surface's current focus is unknown,
    /// which can happen when a reused surface is remounted into a new host.
    private var lastAppliedSurfaceFocus: Bool?
    private var rightMousePressWasForwarded = false
    private var ghosttyMouseCursorStyle: GhosttyMouseCursorStyle = .horizontalText
    private var ghosttyMouseCursorVisible = true
    private var ghosttyMouseOverLinkURL: String?

    struct VisibilityTraceSnapshot: Equatable {
        let hasWindow: Bool
        let isHidden: Bool
        let hasHiddenAncestor: Bool
        let windowVisible: Bool
        let selfAlphaThousandths: Int
        let minAncestorAlphaThousandths: Int
        let minChainAlphaThousandths: Int

        var logicallyVisibleIgnoringTransparency: Bool {
            hasWindow && isHidden == false && hasHiddenAncestor == false && windowVisible
        }

        var visuallyTransparent: Bool {
            minChainAlphaThousandths <= 10
        }

        var resolvedVisible: Bool {
            logicallyVisibleIgnoringTransparency && visuallyTransparent == false
        }
    }
    #endif

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        syncLayerContentsScale()
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        #if TOASTTY_HAS_GHOSTTY_KIT
        if result {
            synchronizeGhosttySurfaceFocusFromApplicationState()
        }
        #endif
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        #if TOASTTY_HAS_GHOSTTY_KIT
        if result {
            syncSurfaceFocus(
                false,
                reason: "resign_first_responder"
            )
        }
        #endif
        return result
    }

    override var isHidden: Bool {
        didSet {
            #if TOASTTY_HAS_GHOSTTY_KIT
            syncSurfaceVisibility(reason: "hidden_changed")
            #else
            isEffectivelyVisible = window != nil && isHidden == false && hasHiddenAncestor == false
            #endif
        }
    }

    @MainActor deinit {
        #if TOASTTY_HAS_GHOSTTY_KIT
        pendingVisibilitySyncTask?.cancel()
        if let windowOcclusionObserver {
            NotificationCenter.default.removeObserver(windowOcclusionObserver)
        }
        #endif
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        #if TOASTTY_HAS_GHOSTTY_KIT
        lastLoggedVisibilityTraceSnapshot = nil
        syncSurfaceVisibility(reason: "superview_changed")
        syncGhosttyCursorOwner()
        #else
        isEffectivelyVisible = window != nil && isHidden == false && hasHiddenAncestor == false
        #endif
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        #if TOASTTY_HAS_GHOSTTY_KIT
        updateWindowOcclusionObservation()
        syncLayerContentsScale()
        lastLoggedVisibilityTraceSnapshot = nil
        syncSurfaceVisibility(reason: "window_changed")
        syncGhosttyCursorOwner()
        #else
        syncLayerContentsScale()
        isEffectivelyVisible = window != nil && isHidden == false && hasHiddenAncestor == false
        #endif
        requestFirstResponderIfNeeded?()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncLayerContentsScale()
    }

    override func updateTrackingAreas() {
        if let mouseTrackingArea {
            removeTrackingArea(mouseTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [
                .mouseEnteredAndExited,
                .mouseMoved,
                .inVisibleRect,
                .activeAlways,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        mouseTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    #if TOASTTY_HAS_GHOSTTY_KIT
    func setGhosttySurface(_ surface: ghostty_surface_t?) {
        let surfaceChanged = ghosttySurface != surface
        ghosttySurface = surface
        lastAppliedSurfaceFocus = nil
        rightMousePressWasForwarded = false
        pendingImageFileDrop = nil
        lastKnownSurfaceVisibility = nil
        if surfaceChanged {
            ghosttyMouseCursorStyle = .horizontalText
            ghosttyMouseCursorVisible = true
            ghosttyMouseOverLinkURL = nil
            syncGhosttyCursorOwner()
        }
        lastLoggedVisibilityTraceSnapshot = nil
        syncSurfaceVisibility(reason: "surface_assignment")
    }

    /// Updates Ghostty surface focus only when the value actually changes.
    /// Returns `true` if focus was applied (i.e. it changed), `false` if
    /// it was a no-op.
    @discardableResult
    func syncSurfaceFocus(
        _ focused: Bool,
        reason: String
    ) -> Bool {
        guard let ghosttySurface else {
            lastAppliedSurfaceFocus = nil
            return false
        }
        guard lastAppliedSurfaceFocus != focused else {
            return false
        }
        lastAppliedSurfaceFocus = focused
        // Focus transitions intentionally avoid forcing an immediate surface
        // refresh here. Doing so injects extra render work into active typing
        // flows and regressed cursor stability in terminal UIs like Codex and
        // Claude Code. Ghostty's normal render loop picks up the focus change.
        ghostty_surface_set_focus(ghosttySurface, focused)
        ToasttyLog.debug(
            "Updated Ghostty surface focus",
            category: .ghostty,
            metadata: [
                "focused": focused ? "true" : "false",
                "reason": reason,
                "host_effectively_visible": isEffectivelyVisible ? "true" : "false",
            ]
        )
        return true
    }

    private func updateWindowOcclusionObservation() {
        guard observedWindow !== window else {
            return
        }

        stopObservingWindowOcclusion()
        observedWindow = window

        guard let window else {
            return
        }

        windowOcclusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncSurfaceVisibility(reason: "window_occlusion_changed")
            }
        }
    }

    private func stopObservingWindowOcclusion() {
        if let windowOcclusionObserver {
            NotificationCenter.default.removeObserver(windowOcclusionObserver)
        }
        windowOcclusionObserver = nil
        observedWindow = nil
    }

    func resolvedGhosttySurfaceFocusState() -> Bool {
        isEffectivelyVisible &&
            applicationIsActiveProvider() &&
            window?.isKeyWindow == true &&
            window?.firstResponder === self
    }

    @discardableResult
    func synchronizeGhosttySurfaceFocusFromApplicationState() -> Bool {
        let focused = resolvedGhosttySurfaceFocusState()
        syncSurfaceFocus(
            focused,
            reason: "application_state"
        )
        return focused
    }

    func setGhosttyMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        assert(Thread.isMainThread)
        guard let nextCursorStyle = Self.ghosttyMouseCursorStyle(for: shape),
              nextCursorStyle != ghosttyMouseCursorStyle else {
            return
        }
        ghosttyMouseCursorStyle = nextCursorStyle
        syncGhosttyCursorOwner()
    }

    private func resolvedSurfaceVisibility() -> Bool {
        visibilityTraceSnapshot().resolvedVisible
    }

    @discardableResult
    func synchronizePresentationVisibility(reason: String) -> Bool {
        syncSurfaceVisibility(reason: reason)
        return isEffectivelyVisible
    }

    private func syncSurfaceVisibility(reason: String) {
        let traceSnapshot = visibilityTraceSnapshot()
        logVisibilityTraceIfNeeded(traceSnapshot, reason: reason)
        let visible = traceSnapshot.resolvedVisible
        if shouldDeferInvisibleVisibilityUpdate(visible: visible) {
            scheduleDeferredVisibilitySync()
            return
        }

        pendingVisibilitySyncTask?.cancel()
        pendingVisibilitySyncTask = nil
        applySurfaceVisibility(traceSnapshot: traceSnapshot, reason: reason)
    }

    private func shouldDeferInvisibleVisibilityUpdate(visible: Bool) -> Bool {
        guard visible == false else {
            return false
        }
        guard window == nil,
              isHidden == false,
              hasHiddenAncestor == false,
              lastKnownSurfaceVisibility == true else {
            return false
        }
        return true
    }

    private func scheduleDeferredVisibilitySync() {
        pendingVisibilitySyncTask?.cancel()
        pendingVisibilitySyncTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.pendingVisibilitySyncTask = nil
            let traceSnapshot = self.visibilityTraceSnapshot()
            self.logVisibilityTraceIfNeeded(traceSnapshot, reason: "deferred_window_reattach_check")
            self.applySurfaceVisibility(
                traceSnapshot: traceSnapshot,
                reason: "deferred_window_reattach_check"
            )
        }
    }

    private func applySurfaceVisibility(traceSnapshot: VisibilityTraceSnapshot, reason: String) {
        let visible = traceSnapshot.resolvedVisible
        let previousVisible = lastKnownSurfaceVisibility
        isEffectivelyVisible = visible
        if visible {
            requestFirstResponderIfNeeded?()
        }

        guard let ghosttySurface else {
            lastKnownSurfaceVisibility = nil
            return
        }
        guard lastKnownSurfaceVisibility != visible else {
            return
        }

        lastKnownSurfaceVisibility = visible
        ghostty_surface_set_occlusion(ghosttySurface, visible)
        if visible {
            let shouldRestoreFocus = applicationIsActiveProvider() &&
                window?.isKeyWindow == true &&
                window?.firstResponder === self
            syncSurfaceFocus(
                shouldRestoreFocus,
                reason: "visibility_restoration"
            )
            GhosttyRuntimeManager.shared.requestImmediateTick()
            ghostty_surface_refresh(ghosttySurface)
        } else {
            syncSurfaceFocus(
                false,
                reason: "visibility_hidden"
            )
        }

        ToasttyLog.debug(
            "Updated Ghostty surface occlusion",
            category: .ghostty,
            metadata: [
                "previous_visible": previousVisible.map { $0 ? "true" : "false" } ?? "nil",
                "visible": visible ? "true" : "false",
                "reason": reason,
                "restored_focus": visible &&
                    applicationIsActiveProvider() &&
                    window?.isKeyWindow == true &&
                    window?.firstResponder === self ? "true" : "false",
                "has_window": traceSnapshot.hasWindow ? "true" : "false",
                "is_hidden": traceSnapshot.isHidden ? "true" : "false",
                "has_hidden_ancestor": traceSnapshot.hasHiddenAncestor ? "true" : "false",
                "window_visible": traceSnapshot.windowVisible ? "true" : "false",
                "self_alpha_thousandths": String(traceSnapshot.selfAlphaThousandths),
                "min_ancestor_alpha_thousandths": String(traceSnapshot.minAncestorAlphaThousandths),
                "min_chain_alpha_thousandths": String(traceSnapshot.minChainAlphaThousandths),
            ]
        )
    }

    func visibilityTraceSnapshot() -> VisibilityTraceSnapshot {
        let hasWindow = window != nil
        let windowVisible = window?.occlusionState.contains(.visible) == true
        let selfAlphaThousandths = Self.alphaThousandths(alphaValue)
        let minAncestorAlphaThousandths = minimumAncestorAlphaThousandths()
        let minChainAlphaThousandths = min(selfAlphaThousandths, minAncestorAlphaThousandths)
        return VisibilityTraceSnapshot(
            hasWindow: hasWindow,
            isHidden: isHidden,
            hasHiddenAncestor: hasHiddenAncestor,
            windowVisible: windowVisible,
            selfAlphaThousandths: selfAlphaThousandths,
            minAncestorAlphaThousandths: minAncestorAlphaThousandths,
            minChainAlphaThousandths: minChainAlphaThousandths
        )
    }

    private func minimumAncestorAlphaThousandths() -> Int {
        var result = 1_000
        var ancestor = superview
        while let current = ancestor {
            result = min(result, Self.alphaThousandths(current.alphaValue))
            ancestor = current.superview
        }
        return result
    }

    private static func alphaThousandths(_ alpha: CGFloat) -> Int {
        Int((max(0, min(1, alpha)) * 1_000).rounded())
    }

    private func logVisibilityTraceIfNeeded(_ traceSnapshot: VisibilityTraceSnapshot, reason: String) {
        guard lastLoggedVisibilityTraceSnapshot != traceSnapshot else {
            return
        }
        lastLoggedVisibilityTraceSnapshot = traceSnapshot

        let message: String
        if traceSnapshot.logicallyVisibleIgnoringTransparency && traceSnapshot.visuallyTransparent {
            message = "Ghostty surface treated as hidden because host alpha chain is effectively transparent"
        } else {
            message = "Resolved Ghostty surface visibility state"
        }

        ToasttyLog.debug(
            message,
            category: .ghostty,
            metadata: [
                "reason": reason,
                "resolved_visible": traceSnapshot.resolvedVisible ? "true" : "false",
                "has_window": traceSnapshot.hasWindow ? "true" : "false",
                "window_visible": traceSnapshot.windowVisible ? "true" : "false",
                "is_hidden": traceSnapshot.isHidden ? "true" : "false",
                "has_hidden_ancestor": traceSnapshot.hasHiddenAncestor ? "true" : "false",
                "self_alpha_thousandths": String(traceSnapshot.selfAlphaThousandths),
                "min_ancestor_alpha_thousandths": String(traceSnapshot.minAncestorAlphaThousandths),
                "min_chain_alpha_thousandths": String(traceSnapshot.minChainAlphaThousandths),
            ]
        )
    }

    func setGhosttyMouseVisibility(_ visibility: ghostty_action_mouse_visibility_e) {
        assert(Thread.isMainThread)
        let nextVisible: Bool
        switch visibility {
        case GHOSTTY_MOUSE_VISIBLE:
            nextVisible = true
        case GHOSTTY_MOUSE_HIDDEN:
            nextVisible = false
        default:
            return
        }
        guard nextVisible != ghosttyMouseCursorVisible else {
            return
        }
        ghosttyMouseCursorVisible = nextVisible
        syncGhosttyCursorOwner()
    }

    func setGhosttyMouseOverLink(_ url: String?) {
        assert(Thread.isMainThread)
        let normalizedURL = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextURL = normalizedURL?.isEmpty == false ? normalizedURL : nil
        guard nextURL != ghosttyMouseOverLinkURL else {
            return
        }
        ghosttyMouseOverLinkURL = nextURL
        syncGhosttyCursorOwner()
    }

    func syncGhosttyCursorOwner() {
        guard let terminalSurfaceScrollView = enclosingScrollView as? TerminalSurfaceScrollView else {
            return
        }
        terminalSurfaceScrollView.applyGhosttyCursor(
            style: effectiveGhosttyMouseCursorStyle(),
            visible: ghosttyMouseCursorVisible
        )
    }

    private func effectiveGhosttyMouseCursorStyle() -> GhosttyMouseCursorStyle {
        if ghosttyMouseOverLinkURL != nil {
            return .link
        }
        return ghosttyMouseCursorStyle
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let imageFileURLs = Self.imageFileURLs(from: sender.draggingPasteboard)
        guard imageFileURLs.isEmpty == false else {
            pendingImageFileDrop = nil
            return []
        }
        guard let preparedDrop = resolveImageFileDrop?(imageFileURLs) else {
            pendingImageFileDrop = nil
            return []
        }
        pendingImageFileDrop = preparedDrop
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        pendingImageFileDrop != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let pendingImageFileDrop else {
            return false
        }
        self.pendingImageFileDrop = nil

        focusHostViewIfNeeded()
        return performImageFileDrop?(pendingImageFileDrop) ?? false
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        pendingImageFileDrop = nil
        super.draggingExited(sender)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        pendingImageFileDrop = nil
        super.concludeDragOperation(sender)
    }

    override func mouseDown(with event: NSEvent) {
        focusHostViewIfNeeded()
        guard forwardMouseButton(
            event,
            state: GHOSTTY_MOUSE_PRESS,
            button: GHOSTTY_MOUSE_LEFT
        ) else {
            super.mouseDown(with: event)
            return
        }
    }

    override func mouseUp(with event: NSEvent) {
        let handled = forwardMouseButton(
            event,
            state: GHOSTTY_MOUSE_RELEASE,
            button: GHOSTTY_MOUSE_LEFT
        )
        if let ghosttySurface {
            ghostty_surface_mouse_pressure(ghosttySurface, 0, 0)
        }
        guard handled else {
            super.mouseUp(with: event)
            return
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let ghosttySurface else {
            rightMousePressWasForwarded = false
            super.rightMouseDown(with: event)
            return
        }
        focusHostViewIfNeeded()
        guard shouldForwardRawRightMouseEvents(surface: ghosttySurface) else {
            rightMousePressWasForwarded = false
            super.rightMouseDown(with: event)
            return
        }
        let handled = forwardMouseButton(
            event,
            state: GHOSTTY_MOUSE_PRESS,
            button: GHOSTTY_MOUSE_RIGHT
        )
        rightMousePressWasForwarded = handled
        guard handled else {
            super.rightMouseDown(with: event)
            return
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let ghosttySurface else {
            rightMousePressWasForwarded = false
            super.rightMouseUp(with: event)
            return
        }
        let shouldForward = rightMousePressWasForwarded
            || shouldForwardRawRightMouseEvents(surface: ghosttySurface)
        rightMousePressWasForwarded = false
        guard shouldForward else {
            super.rightMouseUp(with: event)
            return
        }
        guard forwardMouseButton(
            event,
            state: GHOSTTY_MOUSE_RELEASE,
            button: GHOSTTY_MOUSE_RIGHT
        ) else {
            super.rightMouseUp(with: event)
            return
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        focusHostViewIfNeeded()
        let button = Self.ghosttyMouseButton(for: event.buttonNumber)
        guard forwardMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: button) else {
            super.otherMouseDown(with: event)
            return
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        let button = Self.ghosttyMouseButton(for: event.buttonNumber)
        guard forwardMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: button) else {
            super.otherMouseUp(with: event)
            return
        }
    }

    override func mouseEntered(with event: NSEvent) {
        #if TOASTTY_HAS_GHOSTTY_KIT
        _ = forwardMousePosition(event)
        #endif
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        #if TOASTTY_HAS_GHOSTTY_KIT
        setGhosttyMouseOverLink(nil)
        if NSEvent.pressedMouseButtons == 0,
           let ghosttySurface {
            let mods = Self.ghosttyModifierFlags(for: event.modifierFlags)
            ghostty_surface_mouse_pos(ghosttySurface, -1, -1, mods)
        }
        #endif
        super.mouseExited(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        guard forwardMousePosition(event) else {
            super.mouseMoved(with: event)
            return
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard forwardMousePosition(event) else {
            super.mouseDragged(with: event)
            return
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard forwardMousePosition(event) else {
            super.rightMouseDragged(with: event)
            return
        }
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard forwardMousePosition(event) else {
            super.otherMouseDragged(with: event)
            return
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let ghosttySurface else {
            super.scrollWheel(with: event)
            return
        }
        var deltaX = event.scrollingDeltaX
        var deltaY = event.scrollingDeltaY
        let hasPrecision = event.hasPreciseScrollingDeltas

        if hasPrecision {
            // Match Ghostty's native host behavior to preserve trackpad scroll feel.
            deltaX *= 2
            deltaY *= 2
        }

        let mods = Self.ghosttyScrollModifierFlags(
            precision: hasPrecision,
            momentumPhase: event.momentumPhase
        )
        ghostty_surface_mouse_scroll(
            ghosttySurface,
            Double(deltaX),
            Double(deltaY),
            mods
        )
    }

    override func pressureChange(with event: NSEvent) {
        guard let ghosttySurface else {
            super.pressureChange(with: event)
            return
        }
        ghostty_surface_mouse_pressure(
            ghosttySurface,
            UInt32(max(event.stage, 0)),
            Double(event.pressure)
        )
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let ghosttySurface else {
            return super.menu(for: event)
        }
        guard !shouldForwardRawRightMouseEvents(surface: ghosttySurface) else {
            return nil
        }

        focusHostViewIfNeeded()

        let menu = NSMenu(title: "Terminal")
        menu.autoenablesItems = false

        let copyItem = NSMenuItem(
            title: "Copy",
            action: #selector(copy(_:)),
            keyEquivalent: ""
        )
        copyItem.target = self
        copyItem.isEnabled = hasCopyableSelection(on: ghosttySurface)
        menu.addItem(copyItem)

        let pasteItem = NSMenuItem(
            title: "Paste",
            action: #selector(paste(_:)),
            keyEquivalent: ""
        )
        pasteItem.target = self
        pasteItem.isEnabled = Self.hasStringContentInPasteboard()
        menu.addItem(pasteItem)

        return menu
    }

    @objc func copy(_ sender: Any?) {
        guard let ghosttySurface,
              hasCopyableSelection(on: ghosttySurface) else {
            return
        }
        if invokeGhosttyBindingAction("copy_to_clipboard", on: ghosttySurface) {
            return
        }
        _ = copySelectionToPasteboard()
    }

    @objc func paste(_ sender: Any?) {
        guard let ghosttySurface else { return }
        _ = invokeGhosttyBindingAction("paste_from_clipboard", on: ghosttySurface)
    }

    override func keyDown(with event: NSEvent) {
        guard handleKeyEvent(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS) else {
            super.keyDown(with: event)
            return
        }
    }

    override func keyUp(with event: NSEvent) {
        guard handleKeyEvent(event, action: GHOSTTY_ACTION_RELEASE) else {
            super.keyUp(with: event)
            return
        }
    }

    override func flagsChanged(with event: NSEvent) {
        #if TOASTTY_HAS_GHOSTTY_KIT
        guard let action = Self.ghosttyModifierActionForFlagsChanged(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags
        ) else {
            super.flagsChanged(with: event)
            return
        }

        // Apply the modifier transition first so stationary pointer hover
        // state re-evaluates against Ghostty's current modifier set.
        let handled = handleKeyEvent(event, action: action)

        // FlagsChanged events can carry stale or zero-origin locationInWindow
        // values, so use the window's live mouse location instead of the event's.
        _ = forwardCurrentMousePosition(modifierFlags: event.modifierFlags)
        guard handled else {
            super.flagsChanged(with: event)
            return
        }
        #else
        super.flagsChanged(with: event)
        #endif
    }

    private func handleKeyEvent(_ event: NSEvent, action: ghostty_input_action_e) -> Bool {
        guard let ghosttySurface else {
            ToasttyLog.debug(
                "Dropped key event because Ghostty surface is unavailable",
                category: .input,
                metadata: [
                    "key_code": String(event.keyCode),
                    "action": Self.ghosttyInputActionName(action),
                ]
            )
            return false
        }

        let mods = Self.ghosttyModifierFlags(for: event.modifierFlags)
        // Translation mods are only for keyboard-layout text translation (for example
        // option-as-alt) and should not strip control/command from the actual key event.
        let translationMods = ghostty_surface_key_translation_mods(ghosttySurface, mods)
        var keyEvent = ghostty_input_key_s(
            action: action,
            mods: mods,
            consumed_mods: Self.ghosttyConsumedModifierFlags(forTranslationMods: translationMods),
            keycode: UInt32(event.keyCode),
            text: nil,
            unshifted_codepoint: 0,
            composing: false
        )

        keyEvent.unshifted_codepoint = Self.ghosttyUnshiftedCodepoint(for: event)

        let text = Self.ghosttyText(for: event)
        let handled: Bool
        if let text, !text.isEmpty {
            handled = text.withCString { pointer in
                keyEvent.text = pointer
                return ghostty_surface_key(ghosttySurface, keyEvent)
            }
        } else {
            handled = ghostty_surface_key(ghosttySurface, keyEvent)
        }

        ToasttyLog.debug(
            "Forwarded key event to Ghostty surface",
            category: .input,
            metadata: [
                "handled": handled ? "true" : "false",
                "key_code": String(event.keyCode),
                "action": Self.ghosttyInputActionName(action),
                "modifiers": Self.modifierDescription(event.modifierFlags),
                "text_length": String(text?.count ?? 0),
            ]
        )

        return handled
    }

    private func focusHostViewIfNeeded() {
        guard let window else { return }
        guard window.firstResponder !== self else { return }
        window.makeFirstResponder(self)
    }

    private func shouldForwardRawRightMouseEvents(surface: ghostty_surface_t) -> Bool {
        ghostty_surface_mouse_captured(surface)
    }

    @discardableResult
    private func forwardMouseButton(
        _ event: NSEvent,
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e
    ) -> Bool {
        guard let ghosttySurface else { return false }
        forwardMousePosition(event, surface: ghosttySurface)
        let mods = Self.ghosttyModifierFlags(for: event.modifierFlags)
        return ghostty_surface_mouse_button(ghosttySurface, state, button, mods)
    }

    @discardableResult
    private func forwardMousePosition(_ event: NSEvent) -> Bool {
        guard let ghosttySurface else { return false }
        forwardMousePosition(event, surface: ghosttySurface)
        return true
    }

    private func forwardMousePosition(_ event: NSEvent, surface: ghostty_surface_t) {
        let point = convert(event.locationInWindow, from: nil)
        let y = bounds.height - point.y
        let mods = Self.ghosttyModifierFlags(for: event.modifierFlags)
        ghostty_surface_mouse_pos(surface, point.x, y, mods)
    }

    /// Forwards the current mouse position using the window's live cursor
    /// location rather than an event's potentially stale `locationInWindow`.
    /// Useful for non-mouse events (e.g. `flagsChanged`) where the event
    /// position may not reflect where the pointer actually is.
    @discardableResult
    private func forwardCurrentMousePosition(
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        guard let ghosttySurface, let window else { return false }
        let windowPoint = window.mouseLocationOutsideOfEventStream
        let point = convert(windowPoint, from: nil)
        let y = bounds.height - point.y
        let mods = Self.ghosttyModifierFlags(for: modifierFlags)
        ghostty_surface_mouse_pos(ghosttySurface, point.x, y, mods)
        return true
    }

    @discardableResult
    private func copySelectionToPasteboard() -> Bool {
        guard let ghosttySurface,
              hasCopyableSelection(on: ghosttySurface),
              let selectedText = selectedText(from: ghosttySurface),
              selectedText.isEmpty == false else {
            return false
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(selectedText, forType: .string)
        return true
    }

    private func selectedText(from surface: ghostty_surface_t) -> String? {
        var textPayload = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &textPayload) else {
            return nil
        }
        defer {
            ghostty_surface_free_text(surface, &textPayload)
        }
        guard let textPointer = textPayload.text else {
            return nil
        }

        let bytePointer = UnsafeRawPointer(textPointer).assumingMemoryBound(to: UInt8.self)
        let buffer = UnsafeBufferPointer(start: bytePointer, count: Int(textPayload.text_len))
        return String(decoding: buffer, as: UTF8.self)
    }

    private func hasCopyableSelection(on surface: ghostty_surface_t) -> Bool {
        guard ghostty_surface_has_selection(surface),
              let selectedText = selectedText(from: surface),
              selectedText.isEmpty == false else {
            return false
        }
        return true
    }

    @discardableResult
    private func invokeGhosttyBindingAction(_ action: String, on surface: ghostty_surface_t) -> Bool {
        let cString = action.utf8CString
        let handled = cString.withUnsafeBufferPointer { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress else { return false }
            let byteCount = max(buffer.count - 1, 0) // drop C-string null terminator
            guard byteCount > 0 else { return false }
            return ghostty_surface_binding_action(surface, baseAddress, uintptr_t(byteCount))
        }
        if handled == false {
            ToasttyLog.warning(
                "Ghostty context-menu action not handled",
                category: .ghostty,
                metadata: ["action": action]
            )
        }
        return handled
    }

    private static func imageFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        guard let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: imageFileURLReadOptions
        ) as? [URL] else {
            return []
        }
        return objects.map(\.standardizedFileURL)
    }

    private static func hasStringContentInPasteboard() -> Bool {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            return false
        }
        return text.isEmpty == false
    }

    private static func ghosttyModifierFlags(for flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        if flags.contains(.numericPad) { raw |= GHOSTTY_MODS_NUM.rawValue }
        let rawFlags = flags.rawValue
        if rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { raw |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0 { raw |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0 { raw |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0 { raw |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }

    private static func ghosttyConsumedModifierFlags(
        forTranslationMods translationMods: ghostty_input_mods_e
    ) -> ghostty_input_mods_e {
        var raw = translationMods.rawValue
        // These never participate in text translation, so keep them active on the
        // key event instead of marking them consumed.
        raw &= ~GHOSTTY_MODS_CTRL.rawValue
        raw &= ~GHOSTTY_MODS_CTRL_RIGHT.rawValue
        raw &= ~GHOSTTY_MODS_SUPER.rawValue
        raw &= ~GHOSTTY_MODS_SUPER_RIGHT.rawValue
        return ghostty_input_mods_e(rawValue: raw)
    }

    private static func ghosttyMouseButton(for buttonNumber: Int) -> ghostty_input_mouse_button_e {
        switch buttonNumber {
        case 0:
            return GHOSTTY_MOUSE_LEFT
        case 1:
            return GHOSTTY_MOUSE_RIGHT
        case 2:
            return GHOSTTY_MOUSE_MIDDLE
        case 3:
            return GHOSTTY_MOUSE_EIGHT
        case 4:
            return GHOSTTY_MOUSE_NINE
        case 5:
            return GHOSTTY_MOUSE_SIX
        case 6:
            return GHOSTTY_MOUSE_SEVEN
        case 7:
            return GHOSTTY_MOUSE_FOUR
        case 8:
            return GHOSTTY_MOUSE_FIVE
        case 9:
            return GHOSTTY_MOUSE_TEN
        case 10:
            return GHOSTTY_MOUSE_ELEVEN
        default:
            return GHOSTTY_MOUSE_UNKNOWN
        }
    }

    private static func ghosttyScrollModifierFlags(
        precision: Bool,
        momentumPhase: NSEvent.Phase
    ) -> ghostty_input_scroll_mods_t {
        var rawValue: Int32 = 0
        if precision {
            rawValue |= 0b0000_0001
        }
        rawValue |= ghosttyMouseMomentumRawValue(for: momentumPhase) << 1
        return ghostty_input_scroll_mods_t(rawValue)
    }

    private static func ghosttyMouseMomentumRawValue(for phase: NSEvent.Phase) -> Int32 {
        switch phase {
        case .began:
            return Int32(GHOSTTY_MOUSE_MOMENTUM_BEGAN.rawValue)
        case .stationary:
            return Int32(GHOSTTY_MOUSE_MOMENTUM_STATIONARY.rawValue)
        case .changed:
            return Int32(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue)
        case .ended:
            return Int32(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue)
        case .cancelled:
            return Int32(GHOSTTY_MOUSE_MOMENTUM_CANCELLED.rawValue)
        case .mayBegin:
            return Int32(GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN.rawValue)
        default:
            return Int32(GHOSTTY_MOUSE_MOMENTUM_NONE.rawValue)
        }
    }

    private static func ghosttyText(for event: NSEvent) -> String? {
        // FlagsChanged events (modifier-only) have no character data;
        // accessing .characters on them triggers an NSEvent assertion.
        guard event.type == .keyDown || event.type == .keyUp else { return nil }
        guard let characters = event.characters else { return nil }

        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }

            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return characters
    }

    static func ghosttyUnshiftedCodepoint(
        eventType: NSEvent.EventType,
        characterProvider: () -> String?
    ) -> UInt32 {
        switch eventType {
        case .keyDown, .keyUp:
            return characterProvider()?.unicodeScalars.first?.value ?? 0
        default:
            return 0
        }
    }

    private static func ghosttyUnshiftedCodepoint(for event: NSEvent) -> UInt32 {
        ghosttyUnshiftedCodepoint(eventType: event.type) {
            event.characters(byApplyingModifiers: [])
        }
    }

    #if TOASTTY_HAS_GHOSTTY_KIT
    static func ghosttyModifierActionForFlagsChanged(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> ghostty_input_action_e? {
        let changedModifierRawValue: UInt32
        switch keyCode {
        case 0x39:
            changedModifierRawValue = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C:
            changedModifierRawValue = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E:
            changedModifierRawValue = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D:
            changedModifierRawValue = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36:
            changedModifierRawValue = GHOSTTY_MODS_SUPER.rawValue
        default:
            return nil
        }

        let mods = ghosttyModifierFlags(for: modifierFlags)
        guard mods.rawValue & changedModifierRawValue != 0 else {
            return GHOSTTY_ACTION_RELEASE
        }

        let sidePressed: Bool
        switch keyCode {
        case 0x3C:
            sidePressed = modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
        case 0x3E:
            sidePressed = modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
        case 0x3D:
            sidePressed = modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
        case 0x36:
            sidePressed = modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
        default:
            sidePressed = true
        }

        return sidePressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
    }

    static func ghosttyMouseCursorStyle(
        for shape: ghostty_action_mouse_shape_e
    ) -> GhosttyMouseCursorStyle? {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT:
            return .default
        case GHOSTTY_MOUSE_SHAPE_TEXT:
            return .horizontalText
        case GHOSTTY_MOUSE_SHAPE_GRAB:
            return .grabIdle
        case GHOSTTY_MOUSE_SHAPE_GRABBING:
            return .grabActive
        case GHOSTTY_MOUSE_SHAPE_POINTER:
            return .link
        case GHOSTTY_MOUSE_SHAPE_W_RESIZE:
            return .resizeLeft
        case GHOSTTY_MOUSE_SHAPE_E_RESIZE:
            return .resizeRight
        case GHOSTTY_MOUSE_SHAPE_N_RESIZE:
            return .resizeUp
        case GHOSTTY_MOUSE_SHAPE_S_RESIZE:
            return .resizeDown
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE:
            return .resizeUpDown
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE:
            return .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT:
            return .verticalText
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU:
            return .contextMenu
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
            return .crosshair
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED:
            return .operationNotAllowed
        default:
            return nil
        }
    }

    #endif

    private static func modifierDescription(_ flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.command) { parts.append("command") }
        if flags.contains(.option) { parts.append("option") }
        if flags.contains(.control) { parts.append("control") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.capsLock) { parts.append("capsLock") }
        if flags.contains(.numericPad) { parts.append("numericPad") }
        return parts.joined(separator: ",")
    }

    private static func ghosttyInputActionName(_ action: ghostty_input_action_e) -> String {
        switch action {
        case GHOSTTY_ACTION_PRESS:
            return "press"
        case GHOSTTY_ACTION_RELEASE:
            return "release"
        case GHOSTTY_ACTION_REPEAT:
            return "repeat"
        default:
            return "unknown(\(action.rawValue))"
        }
    }
    #endif

    private func syncLayerContentsScale() {
        let scale = window?.screen?.backingScaleFactor
            ?? window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
        layer?.contentsScale = max(scale, 1)
    }
}
