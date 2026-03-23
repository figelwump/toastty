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
        // Toastty maps the File > Close Panel menu item to panel close. The
        // Cmd+W shortcut itself is owned by the app-level local monitor.
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
        // Toastty intentionally maps the File > Close Workspace menu item to
        // the selected workspace, while the Cmd+Shift+W shortcut is owned by
        // the Workspace menu command in ToasttyCommandMenus. AppKit bridge
        // actions do not carry SwiftUI's focused scene value, so File-menu
        // invocations fall back to the store's selected window/workspace
        // context and still route through the shared confirmation flow.
        store.closeSelectedWorkspaceFromCommand(preferredWindowID: nil)
    }

    func canCloseWorkspace() -> Bool {
        store.commandSelection(preferredWindowID: nil) != nil
    }
}

@MainActor
final class SplitLayoutCommandController {
    private let store: AppStore

    init(store: AppStore) {
        self.store = store
    }

    func canSplit(preferredWindowID: UUID?) -> Bool {
        commandSelection(preferredWindowID: preferredWindowID)?.workspace.focusedPanelID != nil
    }

    @discardableResult
    func split(direction: SlotSplitDirection, preferredWindowID: UUID?) -> Bool {
        guard let workspaceID = commandSelection(preferredWindowID: preferredWindowID)?.workspace.id else {
            return false
        }
        return store.send(.splitFocusedSlotInDirection(workspaceID: workspaceID, direction: direction))
    }

    func canFocusSplit(preferredWindowID: UUID?) -> Bool {
        commandSelection(preferredWindowID: preferredWindowID)?.workspace.focusedPanelID != nil
    }

    @discardableResult
    func focusSplit(direction: SlotFocusDirection, preferredWindowID: UUID?) -> Bool {
        guard let workspaceID = commandSelection(preferredWindowID: preferredWindowID)?.workspace.id else {
            return false
        }
        return store.send(.focusSlot(workspaceID: workspaceID, direction: direction))
    }

    func canAdjustSplitLayout(preferredWindowID: UUID?) -> Bool {
        guard let workspace = commandSelection(preferredWindowID: preferredWindowID)?.workspace else {
            return false
        }
        guard workspace.focusedPanelModeActive != true else {
            return false
        }
        return workspace.focusedPanelID != nil
    }

    @discardableResult
    func resizeSplit(direction: SplitResizeDirection, preferredWindowID: UUID?) -> Bool {
        guard let workspaceID = commandSelection(preferredWindowID: preferredWindowID)?.workspace.id else {
            return false
        }
        return store.send(.resizeFocusedSlotSplit(workspaceID: workspaceID, direction: direction, amount: 1))
    }

    @discardableResult
    func equalizeSplits(preferredWindowID: UUID?) -> Bool {
        guard let workspaceID = commandSelection(preferredWindowID: preferredWindowID)?.workspace.id else {
            return false
        }
        return store.send(.equalizeLayoutSplits(workspaceID: workspaceID))
    }

    private func commandSelection(preferredWindowID: UUID?) -> WindowCommandSelection? {
        store.commandSelection(preferredWindowID: preferredWindowID)
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
        if closeWindowItem.keyEquivalent.isEmpty == false {
            closeWindowItem.keyEquivalent = ""
        }
        if closeWindowItem.keyEquivalentModifierMask.isEmpty == false {
            closeWindowItem.keyEquivalentModifierMask = []
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
            let modifiers = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
            let matchesSystemCloseSlot = item.keyEquivalent.lowercased() == "w" &&
                modifiers == [.command] &&
                (
                    item.action == #selector(NSWindow.performClose(_:)) ||
                    item.action == #selector(CloseWindowMenuBridge.performCloseWindow(_:)) ||
                    item.action == nil ||
                    item.title == closePanelMenuItemTitle
                )
            let matchesRetargetedClosePanelItem = item.title == closePanelMenuItemTitle &&
                item.action == #selector(CloseWindowMenuBridge.performCloseWindow(_:))

            if matchesSystemCloseSlot || matchesRetargetedClosePanelItem {
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
final class FileSplitMenuBridge: NSObject, NSMenuItemValidation {
    private let splitLayoutCommandController: SplitLayoutCommandController
    private lazy var splitRightItem = makeManagedItem()
    private lazy var splitLeftItem = makeManagedItem()
    private lazy var splitDownItem = makeManagedItem()
    private lazy var splitUpItem = makeManagedItem()
    private lazy var separatorItem = NSMenuItem.toasttyManagedSeparator(marker: .fileSplit)
    private lazy var ownedItems = [
        splitRightItem,
        splitLeftItem,
        splitDownItem,
        splitUpItem,
        separatorItem,
    ]

    init(splitLayoutCommandController: SplitLayoutCommandController) {
        self.splitLayoutCommandController = splitLayoutCommandController
    }

    func installIfNeeded() {
        guard let mainMenu = NSApp.mainMenu,
              let fileMenu = Self.findFileMenu(in: mainMenu.items) else {
            return
        }

        restoreOwnedItems()
        ensureOwnedItemsAttached(to: fileMenu, insertionIndex: Self.insertionIndex(in: fileMenu))
    }

    @objc
    func splitRight(_: Any?) {
        _ = splitLayoutCommandController.split(direction: .right, preferredWindowID: nil)
    }

    @objc
    func splitLeft(_: Any?) {
        _ = splitLayoutCommandController.split(direction: .left, preferredWindowID: nil)
    }

    @objc
    func splitDown(_: Any?) {
        _ = splitLayoutCommandController.split(direction: .down, preferredWindowID: nil)
    }

    @objc
    func splitUp(_: Any?) {
        _ = splitLayoutCommandController.split(direction: .up, preferredWindowID: nil)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(splitRight(_:)),
            #selector(splitLeft(_:)),
            #selector(splitDown(_:)),
            #selector(splitUp(_:)):
            return splitLayoutCommandController.canSplit(preferredWindowID: nil)
        default:
            return true
        }
    }

    private func restoreOwnedItems() {
        configureMenuItem(
            splitRightItem,
            title: "Split Right",
            action: #selector(splitRight(_:)),
            shortcut: ToasttyKeyboardShortcuts.splitHorizontal
        )
        configureMenuItem(
            splitLeftItem,
            title: "Split Left",
            action: #selector(splitLeft(_:))
        )
        configureMenuItem(
            splitDownItem,
            title: "Split Down",
            action: #selector(splitDown(_:)),
            shortcut: ToasttyKeyboardShortcuts.splitVertical
        )
        configureMenuItem(
            splitUpItem,
            title: "Split Up",
            action: #selector(splitUp(_:))
        )
        separatorItem.representedObject = ManagedMenuSectionMarker.fileSplit.rawValue
    }

    private func ensureOwnedItemsAttached(to menu: NSMenu, insertionIndex: Int) {
        guard menu.containsItemsIdentical(to: ownedItems, at: insertionIndex) == false else {
            return
        }

        detachOwnedItemsFromCurrentMenus()
        menu.removeManagedItems(marker: .fileSplit)
        for (offset, item) in ownedItems.enumerated() {
            menu.insertItem(item, at: min(insertionIndex + offset, menu.items.count))
        }
    }

    private func detachOwnedItemsFromCurrentMenus() {
        for item in ownedItems {
            item.menu?.removeItem(item)
        }
    }

    private func makeManagedItem() -> NSMenuItem {
        let item = NSMenuItem.toasttyManagedItem(
            title: "",
            action: nil,
            keyEquivalent: "",
            marker: .fileSplit
        )
        item.isEnabled = true
        return item
    }

    private func configureMenuItem(
        _ item: NSMenuItem,
        title: String,
        action: Selector,
        shortcut: ToasttyKeyboardShortcut? = nil
    ) {
        item.title = title
        item.action = action
        item.keyEquivalent = shortcut?.keyEquivalentString ?? ""
        item.keyEquivalentModifierMask = shortcut?.keyEquivalentModifierMask ?? []
        item.target = self
        item.representedObject = ManagedMenuSectionMarker.fileSplit.rawValue
        item.submenu = nil
        item.isEnabled = true
    }

    private static func insertionIndex(in menu: NSMenu) -> Int {
        let unmanagedItems = menu.items.filter {
            $0.representedObject as? String != ManagedMenuSectionMarker.fileSplit.rawValue
        }
        guard let closeItemIndex = unmanagedItems.firstIndex(where: { item in
            item.keyEquivalent.lowercased() == "w" &&
                item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == [.command]
        }) else {
            return unmanagedItems.count
        }

        return closeItemIndex
    }

    private static func findFileMenu(in items: [NSMenuItem]) -> NSMenu? {
        if let standardFileMenu = firstTopLevelMenu(in: items, where: { menu in
            menu.items.contains { item in
                item.keyEquivalent.lowercased() == "w" &&
                    item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == [.command]
            }
        }) {
            return standardFileMenu
        }

        return items.first(where: { $0.title == "File" })?.submenu
    }
}

@MainActor
final class CloseWorkspaceMenuBridge: NSObject, NSMenuItemValidation {
    private static let systemCloseAllMenuItemTitle = "Close All"
    private static let closeWorkspaceMenuItemTitle = "Close Workspace"
    private let closeWorkspaceCommandController: CloseWorkspaceCommandController

    init(closeWorkspaceCommandController: CloseWorkspaceCommandController) {
        self.closeWorkspaceCommandController = closeWorkspaceCommandController
    }

    func installIfNeeded() {
        guard let mainMenu = NSApp.mainMenu,
              let fileMenu = Self.findFileMenu(in: mainMenu.items),
              let closeWorkspaceItem = Self.findCloseWorkspaceMenuItem(in: fileMenu.items) else {
            return
        }
        if closeWorkspaceItem.title != Self.closeWorkspaceMenuItemTitle {
            closeWorkspaceItem.title = Self.closeWorkspaceMenuItemTitle
        }
        // The actual Cmd+Shift+W binding lives on the Workspace menu command.
        // Clear the File menu slot's key equivalent so it cannot steal the
        // shortcut before SwiftUI resolves the focused workspace command.
        if closeWorkspaceItem.keyEquivalent.isEmpty == false {
            closeWorkspaceItem.keyEquivalent = ""
        }
        if closeWorkspaceItem.keyEquivalentModifierMask.isEmpty == false {
            closeWorkspaceItem.keyEquivalentModifierMask = []
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

    private static func findCloseWorkspaceMenuItem(in items: [NSMenuItem]) -> NSMenuItem? {
        for item in items {
            // Menu titles and actions can vary across localized system menus, so
            // identify the standard Close All slot by its keyboard equivalent
            // inside the menu that already contains the standard Close/Close All
            // slots. Once retargeted, continue to match the item by title even
            // after its shortcut is cleared so refreshes can reattach the bridge.
            let modifiers = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
            let matchesSystemCloseAllSlot = item.keyEquivalent.lowercased() == "w" &&
                (modifiers == [.command, .shift] || modifiers == [.shift]) &&
                (item.title == systemCloseAllMenuItemTitle || item.title == closeWorkspaceMenuItemTitle)
            let matchesRetargetedCloseWorkspaceItem = item.title == closeWorkspaceMenuItemTitle &&
                item.action == #selector(CloseWorkspaceMenuBridge.performCloseWorkspace(_:))

            if matchesSystemCloseAllSlot || matchesRetargetedCloseWorkspaceItem {
                return item
            }

            if let submenu = item.submenu,
               let nestedItem = findCloseWorkspaceMenuItem(in: submenu.items) {
                return nestedItem
            }
        }

        return nil
    }

    private static func findFileMenu(in items: [NSMenuItem]) -> NSMenu? {
        if let standardFileMenu = firstTopLevelMenu(in: items, where: { menu in
            menu.items.contains { item in
                item.keyEquivalent.lowercased() == "w" &&
                    item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == [.command]
            }
        }) {
            return standardFileMenu
        }

        return items.first(where: { $0.title == "File" })?.submenu
    }
}

@MainActor
final class WindowSplitMenuBridge: NSObject, NSMenuItemValidation {
    private static let navigateSplitsMenuTitle = "Navigate Splits"
    private static let resizeSplitsMenuTitle = "Resize Splits"

    private let splitLayoutCommandController: SplitLayoutCommandController
    private lazy var separatorItem = NSMenuItem.toasttyManagedSeparator(marker: .windowSplit)
    private lazy var selectPreviousItem = makeManagedItem()
    private lazy var selectNextItem = makeManagedItem()
    private lazy var navigateItem = makeManagedItem()
    private lazy var resizeItem = makeManagedItem()
    private lazy var ownedItems = [
        separatorItem,
        selectPreviousItem,
        selectNextItem,
        navigateItem,
        resizeItem,
    ]
    private lazy var navigateMenu = NSMenu(title: Self.navigateSplitsMenuTitle)
    private lazy var navigateUpItem = makeManagedItem()
    private lazy var navigateDownItem = makeManagedItem()
    private lazy var navigateLeftItem = makeManagedItem()
    private lazy var navigateRightItem = makeManagedItem()
    private lazy var ownedNavigateItems = [
        navigateUpItem,
        navigateDownItem,
        navigateLeftItem,
        navigateRightItem,
    ]
    private lazy var resizeMenu = NSMenu(title: Self.resizeSplitsMenuTitle)
    private lazy var equalizeItem = makeManagedItem()
    private lazy var resizeSeparatorItem = NSMenuItem.toasttyManagedSeparator(marker: .windowSplit)
    private lazy var resizeLeftItem = makeManagedItem()
    private lazy var resizeRightItem = makeManagedItem()
    private lazy var resizeUpItem = makeManagedItem()
    private lazy var resizeDownItem = makeManagedItem()
    private lazy var ownedResizeItems = [
        equalizeItem,
        resizeSeparatorItem,
        resizeLeftItem,
        resizeRightItem,
        resizeUpItem,
        resizeDownItem,
    ]

    init(splitLayoutCommandController: SplitLayoutCommandController) {
        self.splitLayoutCommandController = splitLayoutCommandController
    }

    func installIfNeeded() {
        guard let mainMenu = NSApp.mainMenu,
              let windowMenu = Self.findWindowMenu(in: mainMenu.items) else {
            return
        }

        restoreOwnedItems()
        ensureOwnedItemsAttached(to: windowMenu, insertionIndex: Self.insertionIndex(in: windowMenu))
    }

    @objc
    func selectPreviousSplit(_: Any?) {
        _ = splitLayoutCommandController.focusSplit(direction: .previous, preferredWindowID: nil)
    }

    @objc
    func selectNextSplit(_: Any?) {
        _ = splitLayoutCommandController.focusSplit(direction: .next, preferredWindowID: nil)
    }

    @objc
    func navigateUp(_: Any?) {
        _ = splitLayoutCommandController.focusSplit(direction: .up, preferredWindowID: nil)
    }

    @objc
    func navigateDown(_: Any?) {
        _ = splitLayoutCommandController.focusSplit(direction: .down, preferredWindowID: nil)
    }

    @objc
    func navigateLeft(_: Any?) {
        _ = splitLayoutCommandController.focusSplit(direction: .left, preferredWindowID: nil)
    }

    @objc
    func navigateRight(_: Any?) {
        _ = splitLayoutCommandController.focusSplit(direction: .right, preferredWindowID: nil)
    }

    @objc
    func equalizeSplits(_: Any?) {
        _ = splitLayoutCommandController.equalizeSplits(preferredWindowID: nil)
    }

    @objc
    func resizeLeft(_: Any?) {
        _ = splitLayoutCommandController.resizeSplit(direction: .left, preferredWindowID: nil)
    }

    @objc
    func resizeRight(_: Any?) {
        _ = splitLayoutCommandController.resizeSplit(direction: .right, preferredWindowID: nil)
    }

    @objc
    func resizeUp(_: Any?) {
        _ = splitLayoutCommandController.resizeSplit(direction: .up, preferredWindowID: nil)
    }

    @objc
    func resizeDown(_: Any?) {
        _ = splitLayoutCommandController.resizeSplit(direction: .down, preferredWindowID: nil)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(selectPreviousSplit(_:)),
            #selector(selectNextSplit(_:)),
            #selector(navigateUp(_:)),
            #selector(navigateDown(_:)),
            #selector(navigateLeft(_:)),
            #selector(navigateRight(_:)):
            return splitLayoutCommandController.canFocusSplit(preferredWindowID: nil)

        case #selector(equalizeSplits(_:)),
            #selector(resizeLeft(_:)),
            #selector(resizeRight(_:)),
            #selector(resizeUp(_:)),
            #selector(resizeDown(_:)):
            return splitLayoutCommandController.canAdjustSplitLayout(preferredWindowID: nil)

        default:
            return true
        }
    }

    private func restoreOwnedItems() {
        let focusEnabled = splitLayoutCommandController.canFocusSplit(preferredWindowID: nil)
        let layoutEnabled = splitLayoutCommandController.canAdjustSplitLayout(preferredWindowID: nil)

        separatorItem.representedObject = ManagedMenuSectionMarker.windowSplit.rawValue
        configureMenuItem(
            selectPreviousItem,
            title: "Select Previous Split",
            action: #selector(selectPreviousSplit(_:)),
            shortcut: ToasttyKeyboardShortcuts.focusPreviousPane
        )
        configureMenuItem(
            selectNextItem,
            title: "Select Next Split",
            action: #selector(selectNextSplit(_:)),
            shortcut: ToasttyKeyboardShortcuts.focusNextPane
        )

        navigateMenu.title = Self.navigateSplitsMenuTitle
        navigateMenu.autoenablesItems = true
        resizeMenu.title = Self.resizeSplitsMenuTitle
        resizeMenu.autoenablesItems = true

        configureMenuItem(navigateUpItem, title: "Navigate Up", action: #selector(navigateUp(_:)))
        configureMenuItem(navigateDownItem, title: "Navigate Down", action: #selector(navigateDown(_:)))
        configureMenuItem(navigateLeftItem, title: "Navigate Left", action: #selector(navigateLeft(_:)))
        configureMenuItem(navigateRightItem, title: "Navigate Right", action: #selector(navigateRight(_:)))
        ensureOwnedSubmenuItemsAttached(ownedNavigateItems, to: navigateMenu)

        configureMenuItem(
            equalizeItem,
            title: "Equalize Splits",
            action: #selector(equalizeSplits(_:)),
            shortcut: ToasttyKeyboardShortcuts.equalizeSplits
        )
        resizeSeparatorItem.representedObject = ManagedMenuSectionMarker.windowSplit.rawValue
        configureMenuItem(
            resizeLeftItem,
            title: "Resize Left",
            action: #selector(resizeLeft(_:)),
            shortcut: ToasttyKeyboardShortcuts.resizeSplitLeft
        )
        configureMenuItem(
            resizeRightItem,
            title: "Resize Right",
            action: #selector(resizeRight(_:)),
            shortcut: ToasttyKeyboardShortcuts.resizeSplitRight
        )
        configureMenuItem(
            resizeUpItem,
            title: "Resize Up",
            action: #selector(resizeUp(_:)),
            shortcut: ToasttyKeyboardShortcuts.resizeSplitUp
        )
        configureMenuItem(
            resizeDownItem,
            title: "Resize Down",
            action: #selector(resizeDown(_:)),
            shortcut: ToasttyKeyboardShortcuts.resizeSplitDown
        )
        ensureOwnedSubmenuItemsAttached(ownedResizeItems, to: resizeMenu)

        configureSubmenuRoot(
            title: Self.navigateSplitsMenuTitle,
            item: navigateItem,
            submenu: navigateMenu,
            isEnabled: focusEnabled
        )

        configureSubmenuRoot(
            title: Self.resizeSplitsMenuTitle,
            item: resizeItem,
            submenu: resizeMenu,
            isEnabled: layoutEnabled
        )
    }

    private func configureSubmenuRoot(
        title: String,
        item: NSMenuItem,
        submenu: NSMenu,
        isEnabled: Bool
    ) {
        item.title = title
        item.action = nil
        item.keyEquivalent = ""
        item.keyEquivalentModifierMask = []
        item.target = nil
        item.representedObject = ManagedMenuSectionMarker.windowSplit.rawValue
        item.submenu = submenu
        item.isEnabled = isEnabled
    }

    private func ensureOwnedItemsAttached(to menu: NSMenu, insertionIndex: Int) {
        guard menu.containsItemsIdentical(to: ownedItems, at: insertionIndex) == false else {
            return
        }

        detachOwnedItemsFromCurrentMenus(ownedItems)
        menu.removeManagedItems(marker: .windowSplit)
        for (offset, item) in ownedItems.enumerated() {
            menu.insertItem(item, at: min(insertionIndex + offset, menu.items.count))
        }
    }

    private func ensureOwnedSubmenuItemsAttached(_ items: [NSMenuItem], to menu: NSMenu) {
        guard menu.containsExactlyItemsIdentical(to: items) == false else {
            return
        }

        detachOwnedItemsFromCurrentMenus(items)
        menu.removeManagedItems(marker: .windowSplit)
        for (index, item) in items.enumerated() {
            menu.insertItem(item, at: index)
        }
    }

    private func detachOwnedItemsFromCurrentMenus(_ items: [NSMenuItem]) {
        for item in items {
            item.menu?.removeItem(item)
        }
    }

    private func makeManagedItem() -> NSMenuItem {
        let item = NSMenuItem.toasttyManagedItem(
            title: "",
            action: nil,
            keyEquivalent: "",
            marker: .windowSplit
        )
        item.isEnabled = true
        return item
    }

    private func configureMenuItem(
        _ item: NSMenuItem,
        title: String,
        action: Selector,
        shortcut: ToasttyKeyboardShortcut? = nil
    ) {
        item.title = title
        item.action = action
        item.keyEquivalent = shortcut?.keyEquivalentString ?? ""
        item.keyEquivalentModifierMask = shortcut?.keyEquivalentModifierMask ?? []
        item.target = self
        item.representedObject = ManagedMenuSectionMarker.windowSplit.rawValue
        item.submenu = nil
        item.isEnabled = true
    }

    private static func insertionIndex(in menu: NSMenu) -> Int {
        let unmanagedItems = menu.items.filter {
            $0.representedObject as? String != ManagedMenuSectionMarker.windowSplit.rawValue
        }
        guard let lastSeparatorIndex = unmanagedItems.lastIndex(where: \.isSeparatorItem) else {
            return unmanagedItems.count
        }
        return lastSeparatorIndex
    }

    private static func findWindowMenu(in items: [NSMenuItem]) -> NSMenu? {
        firstTopLevelMenu(in: items) { menu in
            menu.items.contains { item in
                item.keyEquivalent.lowercased() == "m" &&
                    item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == [.command]
            }
        }
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
    private static let menuItemImage = makeMenuItemImage()

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

        if menuItem.target !== self {
            menuItem.target = self
        }
        if menuItem.action != #selector(checkForUpdates(_:)) {
            menuItem.action = #selector(checkForUpdates(_:))
        }
        if menuItem.image !== Self.menuItemImage {
            menuItem.image = Self.menuItemImage
        }

        let isCheckForUpdatesEnabled = canCheckForUpdates()
        if menuItem.isEnabled != isCheckForUpdatesEnabled {
            menuItem.isEnabled = isCheckForUpdatesEnabled
        }
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
    private var needsDynamicMenuBridgeRefresh = false
    private var onOwnedMenuSectionRefreshRequested: (() -> Void)?
    private var onDynamicMenuBridgeRefreshRequested: (() -> Void)?

    init(
        onOwnedMenuSectionRefreshRequested: (() -> Void)? = nil,
        onDynamicMenuBridgeRefreshRequested: (() -> Void)? = nil
    ) {
        self.onOwnedMenuSectionRefreshRequested = onOwnedMenuSectionRefreshRequested
        self.onDynamicMenuBridgeRefreshRequested = onDynamicMenuBridgeRefreshRequested
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func setOnOwnedMenuSectionRefreshRequested(_ onOwnedMenuSectionRefreshRequested: (() -> Void)?) {
        self.onOwnedMenuSectionRefreshRequested = onOwnedMenuSectionRefreshRequested
    }

    func setOnDynamicMenuBridgeRefreshRequested(_ onDynamicMenuBridgeRefreshRequested: (() -> Void)?) {
        self.onDynamicMenuBridgeRefreshRequested = onDynamicMenuBridgeRefreshRequested
    }

    func installIfNeeded() {
        startObservingMenuMutationsIfNeeded()
        refreshMenuTree(reinstallDynamicMenuBridges: true)
    }

    func menuWillOpen(_ menu: NSMenu) {
        // SwiftUI/AppKit can replace sibling menus directly under the app's
        // main menu during command updates, so opening one of those menus is
        // an opportunity to refresh the entire tree. Nested submenus should
        // not trigger bridge reinsertion while AppKit is tracking them.
        let shouldReinstallDynamicMenuBridges = {
            guard let mainMenu = NSApp.mainMenu else { return false }
            return menu.supermenu === mainMenu
        }()
        refreshMenuTree(reinstallDynamicMenuBridges: shouldReinstallDynamicMenuBridges)
    }

    private func startObservingMenuMutationsIfNeeded() {
        guard isObservingMenuMutations == false else { return }
        isObservingMenuMutations = true

        let notificationCenter = NotificationCenter.default
        let observedNotifications: [Notification.Name] = [
            NSMenu.didAddItemNotification,
            NSMenu.didChangeItemNotification,
            NSMenu.didRemoveItemNotification
        ]
        // Mutation notifications refresh hidden items and delegates, but must
        // not reinstall dynamic bridges or recursively churn the menu tree.
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
            self?.refreshMenuTree(reinstallDynamicMenuBridges: false)
        }
    }

    private func refreshMenuTree(reinstallDynamicMenuBridges: Bool) {
        if isRefreshingMenuTree {
            needsMenuTreeRefresh = true
            needsDynamicMenuBridgeRefresh = needsDynamicMenuBridgeRefresh || reinstallDynamicMenuBridges
            return
        }

        isRefreshingMenuTree = true
        defer {
            isRefreshingMenuTree = false

            if needsMenuTreeRefresh {
                // Preserve whether any nested refresh requested dynamic bridge
                // reinstall before coalescing into the next refresh pass.
                let shouldRefreshDynamicMenuBridges = needsDynamicMenuBridgeRefresh
                needsMenuTreeRefresh = false
                needsDynamicMenuBridgeRefresh = false
                refreshMenuTree(reinstallDynamicMenuBridges: shouldRefreshDynamicMenuBridges)
            }
        }

        guard let mainMenu = NSApp.mainMenu else { return }
        installDelegatesRecursively(on: mainMenu)
        Self.updateMenuVisibility(in: mainMenu)
        onOwnedMenuSectionRefreshRequested?()
        if reinstallDynamicMenuBridges {
            onDynamicMenuBridgeRefreshRequested?()
        }
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

private enum ManagedMenuSectionMarker: String {
    case fileSplit = "toastty.file-split-menu"
    case windowSplit = "toastty.window-split-menu"
}

private extension NSMenu {
    func removeManagedItems(marker: ManagedMenuSectionMarker) {
        items
            .enumerated()
            .reversed()
            .filter { _, item in
                item.representedObject as? String == marker.rawValue
            }
            .forEach { index, _ in
                removeItem(at: index)
            }
    }

    func containsItemsIdentical(to expected: [NSMenuItem], at startIndex: Int) -> Bool {
        guard startIndex >= 0, startIndex + expected.count <= items.count else {
            return false
        }

        return zip(items[startIndex ..< startIndex + expected.count], expected).allSatisfy { actual, expected in
            actual === expected
        }
    }

    func containsExactlyItemsIdentical(to expected: [NSMenuItem]) -> Bool {
        containsItemsIdentical(to: expected, at: 0) && items.count == expected.count
    }
}

private extension NSMenuItem {
    static func toasttyManagedItem(
        title: String,
        action: Selector?,
        keyEquivalent: String,
        marker: ManagedMenuSectionMarker
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.representedObject = marker.rawValue
        return item
    }

    static func toasttyManagedSeparator(marker: ManagedMenuSectionMarker) -> NSMenuItem {
        let item = NSMenuItem.separator()
        item.representedObject = marker.rawValue
        return item
    }
}

private extension ToasttyKeyboardShortcut {
    var keyEquivalentString: String {
        String(key.character)
    }

    var keyEquivalentModifierMask: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) {
            flags.insert(.command)
        }
        if modifiers.contains(.control) {
            flags.insert(.control)
        }
        if modifiers.contains(.option) {
            flags.insert(.option)
        }
        if modifiers.contains(.shift) {
            flags.insert(.shift)
        }
        return flags
    }
}

private extension NSObject {
    static func firstTopLevelMenu(
        in items: [NSMenuItem],
        where predicate: (NSMenu) -> Bool
    ) -> NSMenu? {
        items.compactMap(\.submenu).first(where: predicate)
    }
}
