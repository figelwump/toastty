import CoreState
import Foundation

@MainActor
protocol CommandPaletteActionHandling: AnyObject {
    func commandSelection(originWindowID: UUID) -> WindowCommandSelection?
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
    func canReloadConfiguration() -> Bool
    func reloadConfiguration() -> Bool
}

@MainActor
final class CommandPaletteActionHandler: CommandPaletteActionHandling {
    private weak var store: AppStore?
    private let splitLayoutCommandController: SplitLayoutCommandController
    private let focusedPanelCommandController: FocusedPanelCommandController
    private let supportsConfigurationReload: @MainActor () -> Bool
    private let reloadConfigurationAction: @MainActor () -> Void

    init(
        store: AppStore,
        splitLayoutCommandController: SplitLayoutCommandController,
        focusedPanelCommandController: FocusedPanelCommandController,
        supportsConfigurationReload: @escaping @MainActor () -> Bool,
        reloadConfigurationAction: @escaping @MainActor () -> Void
    ) {
        self.store = store
        self.splitLayoutCommandController = splitLayoutCommandController
        self.focusedPanelCommandController = focusedPanelCommandController
        self.supportsConfigurationReload = supportsConfigurationReload
        self.reloadConfigurationAction = reloadConfigurationAction
    }

    func commandSelection(originWindowID: UUID) -> WindowCommandSelection? {
        store?.commandSelection(preferredWindowID: originWindowID)
    }

    func canCreateWorkspace(originWindowID: UUID) -> Bool {
        store?.canCreateWorkspaceFromCommand(preferredWindowID: originWindowID) ?? false
    }

    func createWorkspace(originWindowID: UUID) -> Bool {
        store?.createWorkspaceFromCommand(preferredWindowID: originWindowID) ?? false
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
