import AppKit

/// Keeps the comment's keyboard focus across app activation, including when
/// AppKit moves the popover content into a detached window.
final class BrowserAnnotationCommentInputView: NSTextView {
    weak var parentWindow: NSWindow?

    private var hasRequestedInitialFocus = false
    private weak var windowToRestore: NSWindow?
    private var deactivationEventTimestamp: TimeInterval = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSApplication.willResignActiveNotification, object: nil)
        center.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
        windowToRestore = nil
        guard let window else { return }

        center.addObserver(self, selector: #selector(applicationWillResignActive),
                           name: NSApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationDidBecomeActive),
                           name: NSApplication.didBecomeActiveNotification, object: nil)

        guard hasRequestedInitialFocus == false else { return }
        hasRequestedInitialFocus = true
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            // The popover panel does not become key on its own.
            window.makeKey()
            window.makeFirstResponder(self)
            let endLocation = (self.string as NSString).length
            self.setSelectedRange(NSRange(location: endLocation, length: 0))
            self.updateInsertionPointStateAndRestartTimer(true)
        }
    }

    @objc private func applicationWillResignActive() {
        captureFocusBeforeApplicationDeactivation()
    }

    @objc private func applicationDidBecomeActive() {
        // Restore synchronously. A deferred restore could overtake a user's
        // click after activation. Activation can also precede the mouse event.
        restoreFocusAfterApplicationActivation(
            keyWindow: NSApp.keyWindow,
            modalWindow: NSApp.modalWindow,
            activatingEvent: NSApp.currentEvent,
            mouseDownWindowNumber: NSEvent.pressedMouseButtons == 0 ? nil : NSWindow.windowNumber(
                at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0
            )
        )
    }

    func captureFocusBeforeApplicationDeactivation() {
        deactivationEventTimestamp = NSApp.currentEvent?.timestamp ?? 0
        windowToRestore = window.flatMap {
            $0.isKeyWindow && $0.firstResponder === self ? $0 : nil
        }
    }

    func restoreFocusAfterApplicationActivation(
        keyWindow: NSWindow?,
        modalWindow: NSWindow?,
        activatingEvent: NSEvent?,
        mouseDownWindowNumber: Int? = nil
    ) {
        let previousWindow = windowToRestore
        windowToRestore = nil
        guard let previousWindow,
              window === previousWindow,
              previousWindow.isVisible,
              previousWindow.isMiniaturized == false,
              previousWindow.canBecomeKey,
              isHiddenOrHasHiddenAncestor == false,
              let parentWindow,
              parentWindow.attachedSheet == nil,
              previousWindow.attachedSheet == nil,
              modalWindow == nil,
              keyWindow == nil || keyWindow === previousWindow || keyWindow === parentWindow else {
            return
        }

        if let mouseDownWindowNumber, mouseDownWindowNumber != previousWindow.windowNumber {
            return
        }

        // currentEvent can still be an old click from before deactivation.
        // Only an activating click into another window overrides the snapshot.
        if let activatingEvent,
           activatingEvent.timestamp > deactivationEventTimestamp,
           [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(activatingEvent.type),
           activatingEvent.window !== previousWindow {
            return
        }

        previousWindow.makeKey()
        if previousWindow.firstResponder !== self {
            previousWindow.makeFirstResponder(self)
        }
        // Do not reapply initial selection: AppKit retains the draft's cursor
        // and selection while the app is inactive.
    }
}
