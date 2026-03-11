import AppKit
import CoreState

@MainActor
final class WindowCommandController: NSObject {
    private let focusedPanelCommandController: FocusedPanelCommandController

    init(
        focusedPanelCommandController: FocusedPanelCommandController
    ) {
        self.focusedPanelCommandController = focusedPanelCommandController
    }

    @discardableResult
    func closeWindow() -> Bool {
        // Toastty intentionally maps File > Close Window and Cmd+W to panel close.
        focusedPanelCommandController.closeFocusedPanel().consumesShortcut
    }

    func canCloseWindow() -> Bool {
        focusedPanelCommandController.canCloseFocusedPanel()
    }
}

@MainActor
final class CloseWindowMenuBridge: NSObject, NSMenuItemValidation {
    private let windowCommandController: WindowCommandController

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
        guard windowCommandController.closeWindow() == true else {
            ToasttyLog.warning(
                "Close Window menu action could not resolve a focused panel",
                category: .store
            )
            return
        }
    }

    func validateMenuItem(_: NSMenuItem) -> Bool {
        return windowCommandController.canCloseWindow()
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

@MainActor
final class HiddenSystemMenuItemsBridge: NSObject, NSMenuDelegate {
    private static let hiddenMenuActionNames: Set<String> = [
        NSStringFromSelector(#selector(NSResponder.newWindowForTab(_:))),
        NSStringFromSelector(#selector(NSWindow.toggleTabBar(_:))),
        NSStringFromSelector(#selector(NSWindow.toggleTabOverview(_:)))
    ]

    private static let hiddenMenuTitles: Set<String> = [
        "New Window",
        "Show Tab Bar",
        "Show All Tabs"
    ]

    func installIfNeeded() {
        guard let mainMenu = NSApp.mainMenu else { return }
        installDelegatesRecursively(on: mainMenu)
        Self.updateMenuVisibility(in: mainMenu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        installDelegatesRecursively(on: menu)
        Self.updateMenuVisibility(in: menu)
    }

    private static func updateMenuVisibility(in menu: NSMenu) {
        for item in menu.items {
            if let submenu = item.submenu {
                updateMenuVisibility(in: submenu)
            }

            if item.isSeparatorItem == false {
                item.isHidden = shouldHide(item)
            }
        }

        updateSeparatorVisibility(in: menu)
    }

    private static func shouldHide(_ item: NSMenuItem) -> Bool {
        if let action = item.action,
           hiddenMenuActionNames.contains(NSStringFromSelector(action)) {
            return true
        }

        return hiddenMenuTitles.contains(item.title)
    }

    private static func updateSeparatorVisibility(in menu: NSMenu) {
        for (index, item) in menu.items.enumerated() where item.isSeparatorItem {
            let visibleItemsBefore = menu.items[..<index].contains(where: {
                $0.isHidden == false && $0.isSeparatorItem == false
            })
            let visibleItemsAfter = menu.items.dropFirst(index + 1).contains(where: {
                $0.isHidden == false && $0.isSeparatorItem == false
            })
            item.isHidden = visibleItemsBefore == false || visibleItemsAfter == false
        }
    }

    private func installDelegatesRecursively(on menu: NSMenu) {
        if menu.delegate !== self {
            menu.delegate = self
        }

        for item in menu.items {
            if let submenu = item.submenu {
                installDelegatesRecursively(on: submenu)
            }
        }
    }
}
