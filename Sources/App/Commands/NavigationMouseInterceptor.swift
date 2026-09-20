import AppKit

/// Owns the whole side-button gesture so a window switch cannot leak its release
/// into the destination terminal or web view.
struct NavigationMouseGestureState {
    enum Action: Equatable {
        case back
        case forward
        case consume
        case passThrough
    }

    private var pressedButtons: Set<Int> = []

    mutating func action(for type: NSEvent.EventType, button: Int, allowsNavigation: Bool) -> Action {
        switch type {
        case .otherMouseUp:
            return pressedButtons.remove(button) != nil ? .consume : .passThrough
        case .otherMouseDragged:
            return pressedButtons.contains(button) ? .consume : .passThrough
        case .otherMouseDown:
            guard button == 3 || button == 4 else { return .passThrough }
            guard pressedButtons.contains(button) == false else { return .consume }
            guard allowsNavigation else { return .passThrough }
            pressedButtons.insert(button)
            return button == 3 ? .back : .forward
        default:
            return .passThrough
        }
    }

    mutating func reset() {
        pressedButtons.removeAll()
    }
}

@MainActor
final class NavigationMouseInterceptor {
    private weak var store: AppStore?
    private let isBlockingOverlayPresented: @MainActor () -> Bool
    private var gesture = NavigationMouseGestureState()
    nonisolated(unsafe) private var eventMonitor: Any?
    nonisolated(unsafe) private var deactivationObserver: NSObjectProtocol?

    init(
        store: AppStore,
        isBlockingOverlayPresented: @escaping @MainActor () -> Bool = { false }
    ) {
        self.store = store
        self.isBlockingOverlayPresented = isBlockingOverlayPresented
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.otherMouseDown, .otherMouseUp, .otherMouseDragged]
        ) { [weak self] event in
            guard let self else { return event }
            let action = self.gesture.action(
                for: event.type,
                button: event.buttonNumber,
                allowsNavigation: self.allowsNavigation(event)
            )
            switch action {
            case .back:
                _ = self.store?.navigateBack()
                return nil
            case .forward:
                _ = self.store?.navigateForward()
                return nil
            case .consume:
                return nil
            case .passThrough:
                return event
            }
        }
        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.gesture.reset() }
        }
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
    }

    private func allowsNavigation(_ event: NSEvent) -> Bool {
        guard let store,
              let windowID = Self.navigationWindowID(
                eventWindow: event.window,
                keyWindow: NSApp.keyWindow,
                modalWindow: NSApp.modalWindow,
                appIsActive: NSApp.isActive,
                isBlockingOverlayPresented: isBlockingOverlayPresented()
              ),
              store.window(id: windowID) != nil,
              let contentView = event.window?.contentView else { return false }
        return contentView.bounds.contains(contentView.convert(event.locationInWindow, from: nil))
    }

    static func navigationWindowID(
        eventWindow: NSWindow?,
        keyWindow: NSWindow?,
        modalWindow: NSWindow?,
        appIsActive: Bool,
        isBlockingOverlayPresented: Bool
    ) -> UUID? {
        guard appIsActive, isBlockingOverlayPresented == false, modalWindow == nil,
              let eventWindow, eventWindow === keyWindow,
              eventWindow.sheetParent == nil, eventWindow.attachedSheet == nil,
              let rawID = eventWindow.identifier?.rawValue else { return nil }
        return UUID(uuidString: rawID)
    }
}
