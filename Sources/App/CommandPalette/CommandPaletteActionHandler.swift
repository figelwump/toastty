import CoreState
import Foundation

@MainActor
protocol CommandPaletteActionHandling: AnyObject {
    func commandSelection(originWindowID: UUID) -> WindowCommandSelection?
    func canCreateWindow(originWindowID: UUID) -> Bool
    func createWindow(originWindowID: UUID) -> Bool
    func canCreateWorkspace(originWindowID: UUID) -> Bool
    func createWorkspace(originWindowID: UUID) -> Bool
    func canCreateWorkspaceTab(originWindowID: UUID) -> Bool
    func createWorkspaceTab(originWindowID: UUID) -> Bool
    func canSplit(direction: SlotSplitDirection, originWindowID: UUID) -> Bool
    func split(direction: SlotSplitDirection, originWindowID: UUID) -> Bool
    func canToggleSidebar(originWindowID: UUID) -> Bool
    func toggleSidebar(originWindowID: UUID) -> Bool
    func sidebarTitle(originWindowID: UUID) -> String
    func canClosePanel(originWindowID: UUID) -> Bool
    func closePanel(originWindowID: UUID) -> Bool
    func canRenameWorkspace(originWindowID: UUID) -> Bool
    func renameWorkspace(originWindowID: UUID) -> Bool
    func canCloseWorkspace(originWindowID: UUID) -> Bool
    func closeWorkspace(originWindowID: UUID) -> Bool
    func canRenameTab(originWindowID: UUID) -> Bool
    func renameTab(originWindowID: UUID) -> Bool
    func canSelectAdjacentTab(direction: TabNavigationDirection, originWindowID: UUID) -> Bool
    func selectAdjacentTab(direction: TabNavigationDirection, originWindowID: UUID) -> Bool
    func canJumpToNextActive(originWindowID: UUID) -> Bool
    func jumpToNextActive(originWindowID: UUID) -> Bool
    func canReloadConfiguration() -> Bool
    func reloadConfiguration() -> Bool
}

@MainActor
final class CommandPaletteActionHandler: CommandPaletteActionHandling {
    private weak var store: AppStore?
    private let splitLayoutCommandController: SplitLayoutCommandController
    private let focusedPanelCommandController: FocusedPanelCommandController
    private let sessionRuntimeStore: SessionRuntimeStore
    private let supportsConfigurationReload: @MainActor () -> Bool
    private let reloadConfigurationAction: @MainActor () -> Void

    init(
        store: AppStore,
        splitLayoutCommandController: SplitLayoutCommandController,
        focusedPanelCommandController: FocusedPanelCommandController,
        sessionRuntimeStore: SessionRuntimeStore,
        supportsConfigurationReload: @escaping @MainActor () -> Bool,
        reloadConfigurationAction: @escaping @MainActor () -> Void
    ) {
        self.store = store
        self.splitLayoutCommandController = splitLayoutCommandController
        self.focusedPanelCommandController = focusedPanelCommandController
        self.sessionRuntimeStore = sessionRuntimeStore
        self.supportsConfigurationReload = supportsConfigurationReload
        self.reloadConfigurationAction = reloadConfigurationAction
    }

    func commandSelection(originWindowID: UUID) -> WindowCommandSelection? {
        store?.commandSelection(preferredWindowID: originWindowID)
    }

    func canCreateWindow(originWindowID: UUID) -> Bool {
        store?.window(id: originWindowID) != nil
    }

    func createWindow(originWindowID: UUID) -> Bool {
        // Keep the palette anchored to its origin window instead of silently
        // retargeting another window if the origin disappears mid-session.
        guard let store, store.window(id: originWindowID) != nil else {
            return false
        }
        return store.createWindowFromCommand(preferredWindowID: originWindowID)
    }

    func canCreateWorkspace(originWindowID: UUID) -> Bool {
        guard let store, store.window(id: originWindowID) != nil else {
            return false
        }
        return store.canCreateWorkspaceFromCommand(preferredWindowID: originWindowID)
    }

    func createWorkspace(originWindowID: UUID) -> Bool {
        guard let store, store.window(id: originWindowID) != nil else {
            return false
        }
        return store.createWorkspaceFromCommand(preferredWindowID: originWindowID)
    }

    func canCreateWorkspaceTab(originWindowID: UUID) -> Bool {
        store?.commandSelection(preferredWindowID: originWindowID) != nil
    }

    func createWorkspaceTab(originWindowID: UUID) -> Bool {
        store?.createWorkspaceTabFromCommand(preferredWindowID: originWindowID) ?? false
    }

    func canSplit(direction: SlotSplitDirection, originWindowID: UUID) -> Bool {
        _ = direction
        return splitLayoutCommandController.canSplit(preferredWindowID: originWindowID)
    }

    func split(direction: SlotSplitDirection, originWindowID: UUID) -> Bool {
        splitLayoutCommandController.split(direction: direction, preferredWindowID: originWindowID)
    }

    func canToggleSidebar(originWindowID: UUID) -> Bool {
        store?.window(id: originWindowID) != nil
    }

    func toggleSidebar(originWindowID: UUID) -> Bool {
        guard let store, store.window(id: originWindowID) != nil else {
            return false
        }
        return store.send(.toggleSidebar(windowID: originWindowID))
    }

    func sidebarTitle(originWindowID: UUID) -> String {
        guard let window = store?.window(id: originWindowID) else {
            return ToasttyBuiltInCommand.toggleSidebar.title
        }
        return ToasttyBuiltInCommand.toggleSidebarTitle(sidebarVisible: window.sidebarVisible)
    }

    func canClosePanel(originWindowID: UUID) -> Bool {
        guard let workspaceID = store?.commandSelection(preferredWindowID: originWindowID)?.workspace.id else {
            return false
        }
        return focusedPanelCommandController.canCloseFocusedPanel(in: workspaceID)
    }

    func closePanel(originWindowID: UUID) -> Bool {
        guard let workspaceID = store?.commandSelection(preferredWindowID: originWindowID)?.workspace.id else {
            return false
        }
        return focusedPanelCommandController.closeFocusedPanel(in: workspaceID).didMutateState
    }

    // The menu controllers wrap these same AppStore command helpers, but the
    // palette must pass its explicit origin window instead of following the
    // live key-window providers those controllers use.
    func canRenameWorkspace(originWindowID: UUID) -> Bool {
        store?.commandSelection(preferredWindowID: originWindowID) != nil
    }

    func renameWorkspace(originWindowID: UUID) -> Bool {
        store?.renameSelectedWorkspaceFromCommand(preferredWindowID: originWindowID) ?? false
    }

    func canCloseWorkspace(originWindowID: UUID) -> Bool {
        store?.commandSelection(preferredWindowID: originWindowID) != nil
    }

    func closeWorkspace(originWindowID: UUID) -> Bool {
        store?.closeSelectedWorkspaceFromCommand(preferredWindowID: originWindowID) ?? false
    }

    func canRenameTab(originWindowID: UUID) -> Bool {
        store?.canRenameSelectedWorkspaceTabFromCommand(preferredWindowID: originWindowID) ?? false
    }

    func renameTab(originWindowID: UUID) -> Bool {
        store?.renameSelectedWorkspaceTabFromCommand(preferredWindowID: originWindowID) ?? false
    }

    func canSelectAdjacentTab(direction: TabNavigationDirection, originWindowID: UUID) -> Bool {
        _ = direction
        guard let workspace = store?.commandSelection(preferredWindowID: originWindowID)?.workspace else {
            return false
        }
        let tabs = workspace.orderedTabs
        guard tabs.count > 1, let selectedTabID = workspace.resolvedSelectedTabID else {
            return false
        }
        return tabs.contains(where: { $0.id == selectedTabID })
    }

    func selectAdjacentTab(direction: TabNavigationDirection, originWindowID: UUID) -> Bool {
        store?.selectAdjacentWorkspaceTab(
            preferredWindowID: originWindowID,
            direction: direction
        ) ?? false
    }

    func canJumpToNextActive(originWindowID: UUID) -> Bool {
        store?.canFocusNextUnreadOrActivePanelFromCommand(
            preferredWindowID: originWindowID,
            sessionRuntimeStore: sessionRuntimeStore
        ) ?? false
    }

    func jumpToNextActive(originWindowID: UUID) -> Bool {
        store?.focusNextUnreadOrActivePanelFromCommand(
            preferredWindowID: originWindowID,
            sessionRuntimeStore: sessionRuntimeStore
        ) ?? false
    }

    func canReloadConfiguration() -> Bool {
        supportsConfigurationReload()
    }

    func reloadConfiguration() -> Bool {
        guard supportsConfigurationReload() else {
            return false
        }
        reloadConfigurationAction()
        return true
    }
}
