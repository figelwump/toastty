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
final class HelpMenuBridge: NSObject {
    private static let projectHelpURL = URL(string: "https://github.com/figelwump/toastty")!

    private let openURL: (URL) -> Void

    init(openURL: @escaping (URL) -> Void = { url in
        NSWorkspace.shared.open(url)
    }) {
        self.openURL = openURL
    }

    func installIfNeeded() {
        guard let mainMenu = NSApp.mainMenu,
              let helpItem = Self.findProjectHelpItem(in: mainMenu.items) else {
            return
        }
        guard helpItem.target !== self || helpItem.action != #selector(openProjectHelp(_:)) else {
            return
        }

        helpItem.target = self
        helpItem.action = #selector(openProjectHelp(_:))
    }

    @objc
    func openProjectHelp(_: Any?) {
        openURL(Self.projectHelpURL)
    }

    private static func findProjectHelpItem(in items: [NSMenuItem]) -> NSMenuItem? {
        for item in items {
            if item.title == "Toastty Help" {
                return item
            }

            if let submenu = item.submenu,
               let nestedItem = findProjectHelpItem(in: submenu.items) {
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

    private var isObservingMenuMutations = false
    private var isRefreshingMenuTree = false
    private var needsMenuTreeRefresh = false

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func installIfNeeded() {
        startObservingMenuMutationsIfNeeded()
        refreshMenuTree()
    }

    func menuWillOpen(_ menu: NSMenu) {
        _ = menu
        // SwiftUI/AppKit can replace sibling menus during command updates, so
        // opening any menu is an opportunity to refresh the entire tree.
        refreshMenuTree()
    }

    private func startObservingMenuMutationsIfNeeded() {
        guard isObservingMenuMutations == false else { return }
        isObservingMenuMutations = true

        let notificationCenter = NotificationCenter.default
        let observedNotifications: [Notification.Name] = [
            NSMenu.didAddItemNotification,
            NSMenu.didChangeItemNotification,
            NSMenu.didRemoveItemNotification,
            NSMenu.didBeginTrackingNotification
        ]

        for name in observedNotifications {
            notificationCenter.addObserver(
                self,
                selector: #selector(handleMenuMutationNotification(_:)),
                name: name,
                object: nil
            )
        }
    }

    @objc
    private nonisolated func handleMenuMutationNotification(_ notification: Notification) {
        _ = notification

        Task { @MainActor [weak self] in
            self?.refreshMenuTree()
        }
    }

    private func refreshMenuTree() {
        if isRefreshingMenuTree {
            needsMenuTreeRefresh = true
            return
        }

        isRefreshingMenuTree = true
        defer {
            isRefreshingMenuTree = false

            if needsMenuTreeRefresh {
                needsMenuTreeRefresh = false
                refreshMenuTree()
            }
        }

        guard let mainMenu = NSApp.mainMenu else { return }
        installDelegatesRecursively(on: mainMenu)
        Self.updateMenuVisibility(in: mainMenu)
    }

    private static func updateMenuVisibility(in menu: NSMenu) {
        for item in menu.items {
            if let submenu = item.submenu {
                updateMenuVisibility(in: submenu)
            }

            if item.isSeparatorItem == false {
                let shouldHideItem = shouldHide(item)
                if item.isHidden != shouldHideItem {
                    item.isHidden = shouldHideItem
                }
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
            let shouldHideSeparator = visibleItemsBefore == false || visibleItemsAfter == false
            if item.isHidden != shouldHideSeparator {
                item.isHidden = shouldHideSeparator
            }
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
