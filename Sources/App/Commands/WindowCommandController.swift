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
        // Toastty intentionally maps File > Close Panel and Cmd+W to panel close.
        focusedPanelCommandController.closeFocusedPanel().consumesShortcut
    }

    func canCloseWindow() -> Bool {
        focusedPanelCommandController.canCloseFocusedPanel()
    }
}

@MainActor
final class CloseWorkspaceCommandController {
    private let store: AppStore

    init(store: AppStore) {
        self.store = store
    }

    @discardableResult
    func closeWorkspace() -> Bool {
        // Toastty intentionally maps File > Close Workspace and Cmd+Shift+W to
        // the selected workspace, but still routes through the shared
        // confirmation flow instead of closing immediately. AppKit bridge
        // actions do not carry SwiftUI's focused scene value, so this falls
        // back to the store's selected window/workspace context.
        store.closeSelectedWorkspaceFromCommand(preferredWindowID: nil)
    }

    func canCloseWorkspace() -> Bool {
        store.commandSelection(preferredWindowID: nil) != nil
    }
}

@MainActor
final class CloseWindowMenuBridge: NSObject, NSMenuItemValidation {
    private static let closePanelMenuItemTitle = "Close Panel"
    private let windowCommandController: WindowCommandController

    init(windowCommandController: WindowCommandController) {
        self.windowCommandController = windowCommandController
    }

    func installIfNeeded() {
        guard let mainMenu = NSApp.mainMenu,
              let closeWindowItem = Self.findCloseWindowMenuItem(in: mainMenu.items) else {
            return
        }
        if closeWindowItem.title != Self.closePanelMenuItemTitle {
            closeWindowItem.title = Self.closePanelMenuItemTitle
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
                "Close Panel menu action could not resolve a focused panel",
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
               (
                   item.action == #selector(NSWindow.performClose(_:)) ||
                   item.action == #selector(CloseWindowMenuBridge.performCloseWindow(_:)) ||
                   item.action == nil ||
                   item.title == closePanelMenuItemTitle
               ) {
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
final class CloseWorkspaceMenuBridge: NSObject, NSMenuItemValidation {
    private static let fileMenuTitle = "File"
    private static let systemCloseAllMenuItemTitle = "Close All"
    private static let closeWorkspaceMenuItemTitle = "Close Workspace"
    private let closeWorkspaceCommandController: CloseWorkspaceCommandController

    init(closeWorkspaceCommandController: CloseWorkspaceCommandController) {
        self.closeWorkspaceCommandController = closeWorkspaceCommandController
    }

    func installIfNeeded() {
        guard let mainMenu = NSApp.mainMenu,
              let closeWorkspaceItem = Self.findCloseWorkspaceMenuItem(in: mainMenu.items) else {
            return
        }
        if closeWorkspaceItem.title != Self.closeWorkspaceMenuItemTitle {
            closeWorkspaceItem.title = Self.closeWorkspaceMenuItemTitle
        }
        guard closeWorkspaceItem.target !== self ||
            closeWorkspaceItem.action != #selector(performCloseWorkspace(_:)) else {
            return
        }

        closeWorkspaceItem.target = self
        closeWorkspaceItem.action = #selector(performCloseWorkspace(_:))
    }

    @objc
    func performCloseWorkspace(_: Any?) {
        guard closeWorkspaceCommandController.closeWorkspace() == true else {
            ToasttyLog.warning(
                "Close Workspace menu action could not resolve a selected workspace",
                category: .store
            )
            return
        }
    }

    func validateMenuItem(_: NSMenuItem) -> Bool {
        closeWorkspaceCommandController.canCloseWorkspace()
    }

    private static func findCloseWorkspaceMenuItem(
        in items: [NSMenuItem],
        inFileMenu: Bool = false
    ) -> NSMenuItem? {
        for item in items {
            // Menu titles and actions can vary across localized system menus, so
            // identify the standard Close All slot by its keyboard equivalent,
            // but constrain the search to File menu items that still resemble
            // the system slot we are retargeting.
            let modifiers = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
            if item.keyEquivalent.lowercased() == "w",
               inFileMenu,
               (modifiers == [.command, .shift] || modifiers == [.shift]),
               (item.title == systemCloseAllMenuItemTitle || item.title == closeWorkspaceMenuItemTitle) {
                return item
            }

            if let submenu = item.submenu,
               let nestedItem = findCloseWorkspaceMenuItem(
                    in: submenu.items,
                    inFileMenu: inFileMenu || item.title == fileMenuTitle
               ) {
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
final class SparkleMenuBridge: NSObject, NSMenuItemValidation {
    private static let menuItemTitle = "Check for Updates..."
    private static let menuItemSymbolName = "arrow.triangle.2.circlepath"

    private let canCheckForUpdates: () -> Bool
    private let performCheckForUpdates: () -> Void

    init(
        canCheckForUpdates: @escaping () -> Bool,
        performCheckForUpdates: @escaping () -> Void
    ) {
        self.canCheckForUpdates = canCheckForUpdates
        self.performCheckForUpdates = performCheckForUpdates
    }

    convenience init(sparkleUpdaterBridge: SparkleUpdaterBridge) {
        self.init(
            canCheckForUpdates: { sparkleUpdaterBridge.canCheckForUpdates },
            performCheckForUpdates: { sparkleUpdaterBridge.checkForUpdates() }
        )
    }

    func installIfNeeded() {
        guard let mainMenu = NSApp.mainMenu,
              let appMenu = Self.findAppMenu(in: mainMenu.items) else {
            return
        }

        let menuItem: NSMenuItem
        if let existingMenuItem = Self.findCheckForUpdatesMenuItem(in: appMenu.items) {
            menuItem = existingMenuItem
        } else {
            menuItem = NSMenuItem(title: Self.menuItemTitle, action: nil, keyEquivalent: "")
            appMenu.insertItem(menuItem, at: Self.insertionIndex(in: appMenu.items))
        }

        menuItem.target = self
        menuItem.action = #selector(checkForUpdates(_:))
        menuItem.image = Self.makeMenuItemImage()
        menuItem.isEnabled = canCheckForUpdates()
    }

    @objc
    func checkForUpdates(_: Any?) {
        performCheckForUpdates()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.title == Self.menuItemTitle else {
            return true
        }

        return canCheckForUpdates()
    }

    private static func findAppMenu(in items: [NSMenuItem]) -> NSMenu? {
        for item in items {
            if item.title == "Apple" {
                continue
            }
            guard let submenu = item.submenu else { continue }
            if submenu.items.contains(where: { $0.title.hasPrefix("About ") }) {
                return submenu
            }
        }

        return nil
    }

    private static func findCheckForUpdatesMenuItem(in items: [NSMenuItem]) -> NSMenuItem? {
        items.first(where: { $0.title == menuItemTitle })
    }

    private static func insertionIndex(in items: [NSMenuItem]) -> Int {
        guard let aboutItemIndex = items.firstIndex(where: { $0.title.hasPrefix("About ") }) else {
            return 0
        }

        return aboutItemIndex + 1
    }

    private static func makeMenuItemImage() -> NSImage? {
        let image = NSImage(
            systemSymbolName: menuItemSymbolName,
            accessibilityDescription: menuItemTitle
        )
        image?.isTemplate = true
        return image
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
    private var onMenuTreeRefresh: (() -> Void)?

    init(onMenuTreeRefresh: (() -> Void)? = nil) {
        self.onMenuTreeRefresh = onMenuTreeRefresh
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func setOnMenuTreeRefresh(_ onMenuTreeRefresh: (() -> Void)?) {
        self.onMenuTreeRefresh = onMenuTreeRefresh
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
        onMenuTreeRefresh?()
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
