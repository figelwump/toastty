import AppKit
import CoreState
import Foundation

@MainActor
final class WindowCommandController: NSObject {
    typealias WindowProvider = @MainActor () -> NSWindow?

    private weak var store: AppStore?
    private let keyWindowProvider: WindowProvider
    private let mainWindowProvider: WindowProvider

    init(
        store: AppStore,
        keyWindowProvider: @escaping WindowProvider = { NSApp.keyWindow },
        mainWindowProvider: @escaping WindowProvider = { NSApp.mainWindow }
    ) {
        self.store = store
        self.keyWindowProvider = keyWindowProvider
        self.mainWindowProvider = mainWindowProvider
    }

    @discardableResult
    func closeWindow(preferredWindowID: UUID? = nil) -> Bool {
        guard let store, let windowID = resolveWindowID(preferredWindowID: preferredWindowID) else {
            return false
        }
        return store.send(.closeWindow(windowID: windowID))
    }

    func canCloseWindow(preferredWindowID: UUID? = nil) -> Bool {
        resolveWindowID(preferredWindowID: preferredWindowID) != nil
    }

    private func resolveWindowID(preferredWindowID: UUID?) -> UUID? {
        guard let store else { return nil }

        if let preferredWindowID {
            guard store.window(id: preferredWindowID) != nil else { return nil }
            return preferredWindowID
        }

        if let activeWindowID = activeAppKitWindowID(in: store) {
            return activeWindowID
        }

        if let selectedWindowID = store.state.selectedWindowID,
           store.window(id: selectedWindowID) != nil {
            return selectedWindowID
        }

        guard store.state.windows.count == 1 else { return nil }
        return store.state.windows.first?.id
    }

    private func activeAppKitWindowID(in store: AppStore) -> UUID? {
        if let keyWindowID = windowID(for: keyWindowProvider(), in: store) {
            return keyWindowID
        }
        return windowID(for: mainWindowProvider(), in: store)
    }

    private func windowID(for window: NSWindow?, in store: AppStore) -> UUID? {
        guard let rawValue = window?.identifier?.rawValue,
              let windowID = UUID(uuidString: rawValue),
              store.window(id: windowID) != nil else {
            return nil
        }
        return windowID
    }
}

@MainActor
final class CloseWindowMenuBridge: NSObject, NSMenuItemValidation {
    private weak var windowCommandController: WindowCommandController?

    init(windowCommandController: WindowCommandController) {
        self.windowCommandController = windowCommandController
    }

    func installIfNeeded() {
        guard let mainMenu = NSApp.mainMenu,
              let closeWindowItem = Self.findCloseWindowMenuItem(in: mainMenu.items) else {
            return
        }
        guard closeWindowItem.target !== self || closeWindowItem.action != #selector(performCloseWindow(_:)) else {
            return
        }

        closeWindowItem.target = self
        closeWindowItem.action = #selector(performCloseWindow(_:))
    }

    @objc
    func performCloseWindow(_: Any?) {
        guard windowCommandController?.closeWindow() == true else {
            ToasttyLog.warning(
                "Close Window menu action could not resolve an active window",
                category: .store
            )
            assertionFailure("Close Window menu action could not resolve an active window")
            return
        }
    }

    func validateMenuItem(_: NSMenuItem) -> Bool {
        return windowCommandController?.canCloseWindow() ?? false
    }

    private static func findCloseWindowMenuItem(in items: [NSMenuItem]) -> NSMenuItem? {
        for item in items {
            if item.keyEquivalent.lowercased() == "w",
               item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == [.command],
               (item.action == #selector(NSWindow.performClose(_:)) || item.action == nil) {
                return item
            }

            if let submenu = item.submenu,
               let nestedItem = findCloseWindowMenuItem(in: submenu.items) {
                return nestedItem
            }
        }

        return nil
    }
}
