import CoreState
import Foundation

@MainActor
protocol CommandPaletteActionHandling: AnyObject {
    func commandSelection(originWindowID: UUID) -> WindowCommandSelection?
    func canCreateWorkspace(originWindowID: UUID) -> Bool
    func createWorkspace(originWindowID: UUID) -> Bool
    func canSplitHorizontal(originWindowID: UUID) -> Bool
    func splitHorizontal(originWindowID: UUID) -> Bool
    func canToggleSidebar(originWindowID: UUID) -> Bool
    func toggleSidebar(originWindowID: UUID) -> Bool
    func sidebarTitle(originWindowID: UUID) -> String
}

@MainActor
final class CommandPaletteActionHandler: CommandPaletteActionHandling {
    private weak var store: AppStore?
    private let splitLayoutCommandController: SplitLayoutCommandController

    init(
        store: AppStore,
        splitLayoutCommandController: SplitLayoutCommandController
    ) {
        self.store = store
        self.splitLayoutCommandController = splitLayoutCommandController
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

    func canSplitHorizontal(originWindowID: UUID) -> Bool {
        splitLayoutCommandController.canSplit(preferredWindowID: originWindowID)
    }

    func splitHorizontal(originWindowID: UUID) -> Bool {
        splitLayoutCommandController.split(direction: .right, preferredWindowID: originWindowID)
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
            return "Toggle Sidebar"
        }
        return window.sidebarVisible ? "Hide Sidebar" : "Show Sidebar"
    }
}
