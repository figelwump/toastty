import AppKit
import CoreState
import Foundation
import WebKit

private final class HistoryContextMenuEventMonitorToken: @unchecked Sendable {
    let value: Any

    init(value: Any) {
        self.value = value
    }
}

final class FocusAwareWKWebView: WKWebView {
    nonisolated static let historyBackMenuItemIdentifier = NSUserInterfaceItemIdentifier(
        "dev.toastty.web-panel.history.back"
    )
    nonisolated static let historyForwardMenuItemIdentifier = NSUserInterfaceItemIdentifier(
        "dev.toastty.web-panel.history.forward"
    )
    private nonisolated static let historyContextMenuAugmentationTimeout: TimeInterval = 2

    var interactionDidRequestFocus: (() -> Void)?
    var showsHistoryContextMenuItems = false {
        didSet {
            guard showsHistoryContextMenuItems != oldValue else { return }
            updateHistoryContextMenuEventMonitor()
        }
    }

    private var isObservingPendingContextMenu = false
    private var historyContextMenuCancellationWorkItem: DispatchWorkItem?
    nonisolated(unsafe) private var historyContextMenuEventMonitor: HistoryContextMenuEventMonitorToken?

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

    override func mouseEntered(with event: NSEvent) {
        logCursorDiagnostic("mouse-entered", event: event)
        super.mouseEntered(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        logCursorDiagnostic("mouse-moved", event: event)
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        logCursorDiagnostic("mouse-exited", event: event)
        super.mouseExited(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        logCursorDiagnostic("cursor-update-before", event: event)
        super.cursorUpdate(with: event)
        logCursorDiagnostic("cursor-update-after", event: event)
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
        logCursorDiagnostic("reset-cursor-rects-suppressed", event: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(
            self,
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
        if let historyContextMenuEventMonitor {
            DispatchQueue.main.async {
                NSEvent.removeMonitor(historyContextMenuEventMonitor.value)
            }
        }
    }

    func augmentHistoryContextMenu(_ menu: NSMenu) {
        guard showsHistoryContextMenuItems else { return }

        let historyItems = Self.historyContextMenuItems(
            target: self,
            canGoBack: canGoBack,
            canGoForward: canGoForward
        )

        let existingItemCount = menu.items.count
        if menu.items.contains(where: { $0.identifier == Self.historyBackMenuItemIdentifier }) == false {
            menu.addItem(historyItems[0])
        }
        if menu.items.contains(where: { $0.identifier == Self.historyForwardMenuItemIdentifier }) == false {
            menu.addItem(historyItems[1])
        }
        if existingItemCount > 0,
           menu.items.count > existingItemCount,
           menu.items[existingItemCount - 1].isSeparatorItem == false {
            menu.insertItem(.separator(), at: existingItemCount)
        }
    }

    static func historyContextMenuItems(
        target: AnyObject,
        canGoBack: Bool,
        canGoForward: Bool
    ) -> [NSMenuItem] {
        let backItem = NSMenuItem(
            title: "Back",
            action: #selector(navigateBackFromContextMenu(_:)),
            keyEquivalent: ""
        )
        backItem.identifier = historyBackMenuItemIdentifier
        backItem.target = target
        backItem.isEnabled = canGoBack

        let forwardItem = NSMenuItem(
            title: "Forward",
            action: #selector(navigateForwardFromContextMenu(_:)),
            keyEquivalent: ""
        )
        forwardItem.identifier = historyForwardMenuItemIdentifier
        forwardItem.target = target
        forwardItem.isEnabled = canGoForward
        return [backItem, forwardItem]
    }

    @objc private func navigateBackFromContextMenu(_ sender: Any?) {
        _ = sender
        guard canGoBack else { return }
        goBack()
    }

    @objc private func navigateForwardFromContextMenu(_ sender: Any?) {
        _ = sender
        guard canGoForward else { return }
        goForward()
    }

    func prepareToAugmentNextContextMenu() {
        guard showsHistoryContextMenuItems else { return }

        cancelPendingContextMenuAugmentation()
        isObservingPendingContextMenu = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contextMenuDidBeginTracking(_:)),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
    }

    @objc private func contextMenuDidBeginTracking(_ notification: Notification) {
        guard isObservingPendingContextMenu,
              let menu = notification.object as? NSMenu else {
            return
        }
        cancelPendingContextMenuAugmentation()
        augmentHistoryContextMenu(menu)
    }

    func cancelPendingContextMenuAugmentation() {
        historyContextMenuCancellationWorkItem?.cancel()
        historyContextMenuCancellationWorkItem = nil
        if isObservingPendingContextMenu {
            NotificationCenter.default.removeObserver(
                self,
                name: NSMenu.didBeginTrackingNotification,
                object: nil
            )
            isObservingPendingContextMenu = false
        }
    }

    func handleHistoryContextMenuGesture(
        eventType: NSEvent.EventType,
        modifierFlags: NSEvent.ModifierFlags,
        eventWindow: NSWindow?,
        hitView: NSView?
    ) {
        guard showsHistoryContextMenuItems else { return }

        // Any newer mouse gesture supersedes a pending WebKit menu. This keeps
        // a delayed context-menu response scoped to the click that requested it.
        cancelPendingContextMenuAugmentation()

        guard Self.shouldPrepareHistoryContextMenu(
            eventType: eventType,
            modifierFlags: modifierFlags,
            eventWindow: eventWindow,
            webViewWindow: window,
            hitView: hitView,
            webView: self
        ) else {
            return
        }

        interactionDidRequestFocus?()
        prepareToAugmentNextContextMenu()

        // WebKit may need an asynchronous content-process hit test before it
        // starts tracking the native menu. Keep the observer alive briefly,
        // then clear it if the page suppresses the menu or WebKit never replies.
        let cancellationWorkItem = DispatchWorkItem { [weak self] in
            self?.cancelPendingContextMenuAugmentation()
        }
        historyContextMenuCancellationWorkItem = cancellationWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.historyContextMenuAugmentationTimeout,
            execute: cancellationWorkItem
        )
    }

    static func shouldPrepareHistoryContextMenu(
        eventType: NSEvent.EventType,
        modifierFlags: NSEvent.ModifierFlags,
        eventWindow: NSWindow?,
        webViewWindow: NSWindow?,
        hitView: NSView?,
        webView: NSView
    ) -> Bool {
        let isContextMenuGesture: Bool
        switch eventType {
        case .rightMouseDown:
            isContextMenuGesture = true
        case .leftMouseDown:
            isContextMenuGesture = modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .contains(.control)
        default:
            isContextMenuGesture = false
        }

        guard isContextMenuGesture,
              let eventWindow,
              eventWindow === webViewWindow,
              let hitView else {
            return false
        }

        return hitView === webView || hitView.isDescendant(of: webView)
    }

    private func updateHistoryContextMenuEventMonitor() {
        if showsHistoryContextMenuItems {
            installHistoryContextMenuEventMonitorIfNeeded()
        } else {
            removeHistoryContextMenuEventMonitor()
            cancelPendingContextMenuAugmentation()
        }
    }

    private func installHistoryContextMenuEventMonitorIfNeeded() {
        guard historyContextMenuEventMonitor == nil else { return }

        let eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self,
                  let eventWindow = event.window,
                  let contentView = eventWindow.contentView else {
                return event
            }

            let location = contentView.convert(event.locationInWindow, from: nil)
            self.handleHistoryContextMenuGesture(
                eventType: event.type,
                modifierFlags: event.modifierFlags,
                eventWindow: eventWindow,
                hitView: contentView.hitTest(location)
            )
            return event
        }
        if let eventMonitor {
            historyContextMenuEventMonitor = HistoryContextMenuEventMonitorToken(
                value: eventMonitor
            )
        }
    }

    private func removeHistoryContextMenuEventMonitor() {
        guard let historyContextMenuEventMonitor else { return }
        NSEvent.removeMonitor(historyContextMenuEventMonitor.value)
        self.historyContextMenuEventMonitor = nil
    }

    private func logCursorDiagnostic(_ phase: String, event: NSEvent?) {
        guard CursorDiagnostics.enabled else { return }

        let windowMouseLocation = window?.mouseLocationOutsideOfEventStream
        let localMouseLocation: CGPoint
        if let windowMouseLocation {
            localMouseLocation = convert(windowMouseLocation, from: nil)
        } else if let event {
            localMouseLocation = convert(event.locationInWindow, from: nil)
        } else {
            localMouseLocation = .zero
        }

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
            "frame": DraggableInteractionLog.rectDescription(frame),
            "bounds": DraggableInteractionLog.rectDescription(bounds),
            "currentCursor": CursorDiagnostics.cursorDescription(NSCursor.current),
            "localMouseLocation": DraggableInteractionLog.pointDescription(localMouseLocation),
            "localMouseInsideBounds": "\(insideBounds)",
            "localMouseNearHorizontalEdge": "\(nearHorizontalEdge)",
            "localMouseNearVerticalEdge": "\(nearVerticalEdge)",
        ]
        if let window {
            metadata["windowNumber"] = "\(window.windowNumber)"
            metadata["windowCursorRectsEnabled"] = "\(window.areCursorRectsEnabled)"
        }
        if let windowMouseLocation {
            metadata["windowMouseLocation"] = DraggableInteractionLog.pointDescription(windowMouseLocation)
            metadata.merge(
                CursorDiagnostics.hitTestMetadata(
                    window: window,
                    windowLocation: windowMouseLocation,
                    referenceView: self
                ),
                uniquingKeysWith: { _, new in new }
            )
        }
        if let event {
            metadata["eventType"] = DraggableInteractionLog.eventTypeDescription(event.type)
            metadata["eventWindowLocation"] = DraggableInteractionLog.pointDescription(event.locationInWindow)
            metadata["eventLocalLocation"] = DraggableInteractionLog.pointDescription(
                convert(event.locationInWindow, from: nil)
            )
        }

        ToasttyLog.info(
            "web panel cursor diagnostic",
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
