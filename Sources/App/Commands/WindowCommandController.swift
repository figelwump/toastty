import AppKit
import CoreState

@MainActor
final class WindowCommandController: NSObject {
    private let store: AppStore
    private let focusedPanelCommandController: FocusedPanelCommandController
    private let preferredWindowIDProvider: () -> UUID?

    init(
        store: AppStore,
        focusedPanelCommandController: FocusedPanelCommandController,
        preferredWindowIDProvider: @escaping () -> UUID? = { nil }
    ) {
        self.store = store
        self.focusedPanelCommandController = focusedPanelCommandController
        self.preferredWindowIDProvider = preferredWindowIDProvider
    }

    @discardableResult
    func closeWindow() -> Bool {
        guard let workspaceID = currentCommandSelection()?.workspace.id else {
            return false
        }
        return focusedPanelCommandController.closeFocusedPanel(in: workspaceID).consumesShortcut
    }

    func canCloseWindow() -> Bool {
        guard let workspaceID = currentCommandSelection()?.workspace.id else {
            return false
        }
        return focusedPanelCommandController.canCloseFocusedPanel(in: workspaceID)
    }

    private func currentKeyWindowID() -> UUID? {
        preferredWindowIDProvider()
    }

    private func currentCommandSelection() -> WindowCommandSelection? {
        guard let preferredWindowID = currentKeyWindowID() else {
            return nil
        }
        return store.commandSelection(preferredWindowID: preferredWindowID)
    }
}

@MainActor
final class CloseWorkspaceCommandController {
    private let store: AppStore
    private let preferredWindowIDProvider: () -> UUID?

    init(
        store: AppStore,
        preferredWindowIDProvider: @escaping () -> UUID? = { nil }
    ) {
        self.store = store
        self.preferredWindowIDProvider = preferredWindowIDProvider
    }

    @discardableResult
    func closeWorkspace() -> Bool {
        guard let preferredWindowID = currentKeyWindowID() else {
            return false
        }
        return store.closeSelectedWorkspaceFromCommand(preferredWindowID: preferredWindowID)
    }

    func canCloseWorkspace() -> Bool {
        guard let preferredWindowID = currentKeyWindowID() else {
            return false
        }
        return store.commandSelection(preferredWindowID: preferredWindowID) != nil
    }

    private func currentKeyWindowID() -> UUID? {
        preferredWindowIDProvider()
    }
}

@MainActor
final class CreateWorkspaceCommandController {
    private let store: AppStore
    private let preferredWindowIDProvider: () -> UUID?

    init(
        store: AppStore,
        preferredWindowIDProvider: @escaping () -> UUID? = { nil }
    ) {
        self.store = store
        self.preferredWindowIDProvider = preferredWindowIDProvider
    }

    @discardableResult
    func createWorkspace() -> Bool {
        guard let preferredWindowID = currentKeyWindowID() else {
            return false
        }
        return store.createWorkspaceFromCommand(preferredWindowID: preferredWindowID)
    }

    func canCreateWorkspace() -> Bool {
        guard let preferredWindowID = currentKeyWindowID() else {
            return false
        }
        return store.canCreateWorkspaceFromCommand(preferredWindowID: preferredWindowID)
    }

    private func currentKeyWindowID() -> UUID? {
        preferredWindowIDProvider()
    }
}

@MainActor
final class RenameWorkspaceCommandController {
    private let store: AppStore
    private let preferredWindowIDProvider: () -> UUID?

    init(
        store: AppStore,
        preferredWindowIDProvider: @escaping () -> UUID? = { nil }
    ) {
        self.store = store
        self.preferredWindowIDProvider = preferredWindowIDProvider
    }

    @discardableResult
    func renameWorkspace() -> Bool {
        guard let preferredWindowID = currentKeyWindowID() else {
            return false
        }
        return store.renameSelectedWorkspaceFromCommand(preferredWindowID: preferredWindowID)
    }

    func canRenameWorkspace() -> Bool {
        guard let preferredWindowID = currentKeyWindowID() else {
            return false
        }
        return store.commandSelection(preferredWindowID: preferredWindowID) != nil
    }

    private func currentKeyWindowID() -> UUID? {
        preferredWindowIDProvider()
    }
}

@MainActor
final class WorkspaceTabCommandController {
    private let store: AppStore
    private let sessionRuntimeStore: SessionRuntimeStore
    private let preferredWindowIDProvider: () -> UUID?

    init(
        store: AppStore,
        sessionRuntimeStore: SessionRuntimeStore,
        preferredWindowIDProvider: @escaping () -> UUID? = { nil }
    ) {
        self.store = store
        self.sessionRuntimeStore = sessionRuntimeStore
        self.preferredWindowIDProvider = preferredWindowIDProvider
    }

    func canRenameSelectedTab() -> Bool {
        guard let preferredWindowID = currentKeyWindowID() else {
            return false
        }
        return store.canRenameSelectedWorkspaceTabFromCommand(preferredWindowID: preferredWindowID)
    }

    @discardableResult
    func renameSelectedTab() -> Bool {
        guard let preferredWindowID = currentKeyWindowID() else {
            return false
        }
        return store.renameSelectedWorkspaceTabFromCommand(preferredWindowID: preferredWindowID)
    }

    func canSelectAdjacentTab() -> Bool {
        guard let preferredWindowID = currentKeyWindowID() else {
            return false
        }
        guard let workspace = store.commandSelection(preferredWindowID: preferredWindowID)?.workspace else {
            return false
        }
        return workspace.orderedTabs.count > 1
    }

    @discardableResult
    func selectAdjacentTab(_ direction: TabNavigationDirection) -> Bool {
        guard let preferredWindowID = currentKeyWindowID() else {
            return false
        }
        return store.selectAdjacentWorkspaceTab(
            preferredWindowID: preferredWindowID,
            direction: direction
        )
    }

    func canFocusNextUnreadOrActivePanel() -> Bool {
        guard let preferredWindowID = currentKeyWindowID() else {
            return false
        }
        return store.canFocusNextUnreadOrActivePanelFromCommand(
            preferredWindowID: preferredWindowID,
            sessionRuntimeStore: sessionRuntimeStore
        )
    }

    @discardableResult
    func focusNextUnreadOrActivePanel() -> Bool {
        guard let preferredWindowID = currentKeyWindowID() else {
            return false
        }
        return store.focusNextUnreadOrActivePanelFromCommand(
            preferredWindowID: preferredWindowID,
            sessionRuntimeStore: sessionRuntimeStore
        )
    }

    private func currentKeyWindowID() -> UUID? {
        preferredWindowIDProvider()
    }
}

@MainActor
final class SplitLayoutCommandController {
    static let appOwnedResizeAmount = 5

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
        if workspace.focusedPanelModeActive {
            return workspace.focusModeSubtree?.root.allSlotInfos.count ?? 0 > 1
        }
        return workspace.focusedPanelID != nil
    }

    @discardableResult
    func resizeSplit(direction: SplitResizeDirection, preferredWindowID: UUID?) -> Bool {
        guard let workspaceID = commandSelection(preferredWindowID: preferredWindowID)?.workspace.id else {
            return false
        }
        return store.send(
            .resizeFocusedSlotSplit(
                workspaceID: workspaceID,
                direction: direction,
                amount: Self.appOwnedResizeAmount
            )
        )
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
final class WorkspaceMenuBridge: NSObject, NSMenuItemValidation {
    private enum ItemTitle {
        static let newWorkspace = "New Workspace"
        static let renameWorkspace = "Rename Workspace"
        static let closeWorkspace = "Close Workspace"
        static let renameTab = "Rename Tab"
        static let selectPreviousTab = "Select Previous Tab"
        static let selectNextTab = "Select Next Tab"
        static let jumpToNextUnreadOrActive = "Jump to Next Unread or Active"
    }

    private let createWorkspaceCommandController: CreateWorkspaceCommandController
    private let renameWorkspaceCommandController: RenameWorkspaceCommandController
    private let closeWorkspaceCommandController: CloseWorkspaceCommandController
    private let workspaceTabCommandController: WorkspaceTabCommandController

    init(
        createWorkspaceCommandController: CreateWorkspaceCommandController,
        renameWorkspaceCommandController: RenameWorkspaceCommandController,
        closeWorkspaceCommandController: CloseWorkspaceCommandController,
        workspaceTabCommandController: WorkspaceTabCommandController
    ) {
        self.createWorkspaceCommandController = createWorkspaceCommandController
        self.renameWorkspaceCommandController = renameWorkspaceCommandController
        self.closeWorkspaceCommandController = closeWorkspaceCommandController
        self.workspaceTabCommandController = workspaceTabCommandController
    }

    func installIfNeeded() {
        guard let mainMenu = NSApp.mainMenu,
              let workspaceMenu = Self.findWorkspaceMenu(in: mainMenu.items) else {
            return
        }

        configureItem(
            titled: ItemTitle.newWorkspace,
            action: #selector(createWorkspace(_:)),
            in: workspaceMenu
        )
        configureItem(
            titled: ItemTitle.renameWorkspace,
            action: #selector(renameWorkspace(_:)),
            in: workspaceMenu
        )
        configureItem(
            titled: ItemTitle.closeWorkspace,
            action: #selector(closeWorkspace(_:)),
            in: workspaceMenu
        )
        configureItem(
            titled: ItemTitle.renameTab,
            action: #selector(renameSelectedTab(_:)),
            in: workspaceMenu
        )
        configureItem(
            titled: ItemTitle.selectPreviousTab,
            action: #selector(selectPreviousTab(_:)),
            in: workspaceMenu
        )
        configureItem(
            titled: ItemTitle.selectNextTab,
            action: #selector(selectNextTab(_:)),
            in: workspaceMenu
        )
        configureItem(
            titled: ItemTitle.jumpToNextUnreadOrActive,
            action: #selector(focusNextUnreadOrActivePanel(_:)),
            in: workspaceMenu
        )
    }

    @objc
    func createWorkspace(_: Any?) {
        _ = createWorkspaceCommandController.createWorkspace()
    }

    @objc
    func renameWorkspace(_: Any?) {
        _ = renameWorkspaceCommandController.renameWorkspace()
    }

    @objc
    func closeWorkspace(_: Any?) {
        _ = closeWorkspaceCommandController.closeWorkspace()
    }

    @objc
    func renameSelectedTab(_: Any?) {
        _ = workspaceTabCommandController.renameSelectedTab()
    }

    @objc
    func selectPreviousTab(_: Any?) {
        _ = workspaceTabCommandController.selectAdjacentTab(.previous)
    }

    @objc
    func selectNextTab(_: Any?) {
        _ = workspaceTabCommandController.selectAdjacentTab(.next)
    }

    @objc
    func focusNextUnreadOrActivePanel(_: Any?) {
        _ = workspaceTabCommandController.focusNextUnreadOrActivePanel()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(createWorkspace(_:)):
            return createWorkspaceCommandController.canCreateWorkspace()

        case #selector(renameWorkspace(_:)):
            return renameWorkspaceCommandController.canRenameWorkspace()

        case #selector(closeWorkspace(_:)):
            return closeWorkspaceCommandController.canCloseWorkspace()

        case #selector(renameSelectedTab(_:)):
            return workspaceTabCommandController.canRenameSelectedTab()

        case #selector(selectPreviousTab(_:)),
            #selector(selectNextTab(_:)):
            return workspaceTabCommandController.canSelectAdjacentTab()

        case #selector(focusNextUnreadOrActivePanel(_:)):
            return workspaceTabCommandController.canFocusNextUnreadOrActivePanel()

        default:
            return true
        }
    }

    private func configureItem(titled title: String, action: Selector, in menu: NSMenu) {
        guard let item = menu.items.first(where: { $0.title == title }) else {
            return
        }
        item.target = self
        item.action = action
        item.isEnabled = true
    }

    private static func findWorkspaceMenu(in items: [NSMenuItem]) -> NSMenu? {
        items.first(where: { $0.title == "Workspace" })?.submenu
    }
}

@MainActor
final class FileCloseMenuBridge: NSObject, NSMenuItemValidation {
    private let windowCommandController: WindowCommandController
    private let closeWorkspaceCommandController: CloseWorkspaceCommandController
    private lazy var closePanelItem = makeManagedItem(title: "Close Panel", action: #selector(performCloseWindow(_:)))
    private lazy var closeWorkspaceItem = makeManagedItem(
        title: "Close Workspace",
        action: #selector(performCloseWorkspace(_:))
    )
    private lazy var ownedItems = [closePanelItem, closeWorkspaceItem]

    init(
        windowCommandController: WindowCommandController,
        closeWorkspaceCommandController: CloseWorkspaceCommandController
    ) {
        self.windowCommandController = windowCommandController
        self.closeWorkspaceCommandController = closeWorkspaceCommandController
    }

    func installIfNeeded() {
        guard let mainMenu = NSApp.mainMenu,
              let fileMenu = Self.findFileMenu(in: mainMenu.items) else {
            return
        }

        let insertionIndex = Self.insertionIndex(in: fileMenu)
        restoreOwnedItems()
        ensureOwnedItemsAttached(to: fileMenu, insertionIndex: insertionIndex)
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

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(performCloseWindow(_:)):
            return windowCommandController.canCloseWindow()
        case #selector(performCloseWorkspace(_:)):
            return closeWorkspaceCommandController.canCloseWorkspace()
        default:
            return true
        }
    }

    private func restoreOwnedItems() {
        configureManagedItem(closePanelItem, title: "Close Panel", action: #selector(performCloseWindow(_:)))
        configureManagedItem(
            closeWorkspaceItem,
            title: "Close Workspace",
            action: #selector(performCloseWorkspace(_:))
        )
    }

    private func configureManagedItem(_ item: NSMenuItem, title: String, action: Selector) {
        item.title = title
        item.action = action
        item.keyEquivalent = ""
        item.keyEquivalentModifierMask = []
        item.target = self
        item.representedObject = ManagedMenuSectionMarker.fileClose.rawValue
        item.submenu = nil
        item.isEnabled = true
    }

    private func makeManagedItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem.toasttyManagedItem(
            title: title,
            action: action,
            keyEquivalent: "",
            marker: .fileClose
        )
        item.target = self
        item.isEnabled = true
        return item
    }

    private func detachOwnedItemsFromCurrentMenus() {
        for item in ownedItems {
            item.menu?.removeItem(item)
        }
    }

    private func ensureOwnedItemsAttached(to menu: NSMenu, insertionIndex: Int) {
        guard menu.containsItemsIdentical(to: ownedItems, at: insertionIndex) == false ||
                Self.containsUnmanagedCloseSlots(in: menu) else {
            return
        }

        detachOwnedItemsFromCurrentMenus()
        menu.removeManagedItems(marker: .fileClose)
        Self.removeSystemCloseItems(from: menu)
        for (offset, item) in ownedItems.enumerated() {
            menu.insertItem(item, at: min(insertionIndex + offset, menu.items.count))
        }
    }

    private static func containsUnmanagedCloseSlots(in menu: NSMenu) -> Bool {
        menu.items.contains { item in
            item.representedObject as? String != ManagedMenuSectionMarker.fileClose.rawValue &&
                (isSystemCloseWindowItem(item) || isSystemCloseWorkspaceItem(item) || isRetargetedCloseItem(item))
        }
    }

    private static func removeSystemCloseItems(from menu: NSMenu) {
        menu.items
            .enumerated()
            .reversed()
            .filter { _, item in
                // SwiftUI/AppKit may materialize File > Close / Close All with
                // localized titles and system-owned or nil actions. Within the
                // File menu, the reserved shortcut shapes are the most stable
                // way to clear those native slots before inserting Toastty's
                // owned Close Panel / Close Workspace items.
                item.representedObject as? String != ManagedMenuSectionMarker.fileClose.rawValue &&
                    (isSystemCloseWindowItem(item) || isSystemCloseWorkspaceItem(item) || isRetargetedCloseItem(item))
            }
            .forEach { index, _ in
                menu.removeItem(at: index)
            }
    }

    private static func insertionIndex(in menu: NSMenu) -> Int {
        let items = menu.items
        if let existingManagedIndex = items.firstIndex(where: {
            $0.representedObject as? String == ManagedMenuSectionMarker.fileClose.rawValue
        }) {
            return existingManagedIndex
        }
        if let systemCloseIndex = items.firstIndex(where: { isSystemCloseWindowItem($0) || isRetargetedCloseItem($0) }) {
            return systemCloseIndex
        }
        if let systemCloseWorkspaceIndex = items.firstIndex(where: isSystemCloseWorkspaceItem) {
            return systemCloseWorkspaceIndex
        }
        return items.count
    }

    private static func isSystemCloseWindowItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(NSWindow.performClose(_:)) {
            return true
        }

        return item.keyEquivalent.lowercased() == "w" &&
            item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == [.command]
    }

    private static func isSystemCloseWorkspaceItem(_ item: NSMenuItem) -> Bool {
        if item.title == "Close All" {
            return true
        }

        let modifiers = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
        return item.keyEquivalent.lowercased() == "w" &&
            (modifiers == [.command, .shift] || modifiers == [.shift])
    }

    private static func isRetargetedCloseItem(_ item: NSMenuItem) -> Bool {
        item.title == "Close Panel" || item.title == "Close Workspace"
    }

    private static func findFileMenu(in items: [NSMenuItem]) -> NSMenu? {
        findToasttyFileMenu(in: items)
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
        if let existingManagedIndex = menu.items.firstIndex(where: {
            $0.representedObject as? String == ManagedMenuSectionMarker.fileSplit.rawValue
        }) {
            return existingManagedIndex
        }

        guard let closeItemIndex = menu.items.firstIndex(where: { item in
            let marker = item.representedObject as? String
            return marker == ManagedMenuSectionMarker.fileClose.rawValue ||
                (
                    item.keyEquivalent.lowercased() == "w" &&
                        item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == [.command]
                )
        }) else {
            return menu.items.count
        }

        return closeItemIndex
    }

    private static func findFileMenu(in items: [NSMenuItem]) -> NSMenu? {
        findToasttyFileMenu(in: items)
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
final class HiddenSystemMenuItemsBridge: NSObject, NSMenuDelegate {
    private static let hiddenMenuActionNames: Set<String> = [
        NSStringFromSelector(#selector(NSResponder.newWindowForTab(_:))),
        NSStringFromSelector(#selector(NSWindow.toggleTabBar(_:))),
        NSStringFromSelector(#selector(NSWindow.toggleTabOverview(_:)))
    ]

    private static let hiddenMenuTitles: Set<String> = [
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
    case fileClose = "toastty.file-close-menu"
    case windowSplit = "toastty.window-split-menu"
}

@MainActor
func currentToasttyKeyWindowID(in store: AppStore) -> UUID? {
    currentToasttyKeyWindowID(keyWindow: NSApp.keyWindow, in: store)
}

@MainActor
func currentToasttyKeyWindowID(keyWindow: NSWindow?, in store: AppStore) -> UUID? {
    guard let rawWindowID = keyWindow?.identifier?.rawValue,
          let windowID = UUID(uuidString: rawWindowID),
          store.window(id: windowID) != nil else {
        return nil
    }
    return windowID
}

@MainActor
func currentToasttyWorkspaceCommandWindowID(in store: AppStore) -> UUID? {
    currentToasttyWorkspaceCommandWindowID(in: store, keyWindow: NSApp.keyWindow)
}

@MainActor
func currentToasttyWorkspaceCommandWindowID(in store: AppStore, keyWindow: NSWindow?) -> UUID? {
    if let keyWindowID = currentToasttyKeyWindowID(keyWindow: keyWindow, in: store) {
        return keyWindowID
    }

    // Workspace menu commands should survive brief AppKit key-window gaps by
    // falling back to the last selected Toastty window.
    guard let selectedWindowID = store.state.selectedWindowID,
          store.window(id: selectedWindowID) != nil else {
        return nil
    }
    return selectedWindowID
}

private func findToasttyFileMenu(in items: [NSMenuItem]) -> NSMenu? {
    if let titledFileMenu = items.first(where: { $0.title == "File" })?.submenu {
        return titledFileMenu
    }

    if let managedFileMenu = NSObject.firstTopLevelMenu(in: items, where: { menu in
        menu.items.contains { item in
            let marker = item.representedObject as? String
            return marker == ManagedMenuSectionMarker.fileSplit.rawValue ||
                marker == ManagedMenuSectionMarker.fileClose.rawValue
        }
    }) {
        return managedFileMenu
    }

    if let standardFileMenu = NSObject.firstTopLevelMenu(in: items, where: { menu in
        menu.items.contains { item in
            item.keyEquivalent.lowercased() == "w" &&
                item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == [.command]
        }
    }) {
        return standardFileMenu
    }

    return nil
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
