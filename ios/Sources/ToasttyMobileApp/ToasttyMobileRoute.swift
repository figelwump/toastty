import Foundation

enum ToasttyMobileRoute: Hashable {
    case workspace(UUID)
    case panelPreview(workspaceID: UUID, panelID: UUID)
    case conversation(UUID)

    var conversationID: UUID? {
        guard case .conversation(let id) = self else { return nil }
        return id
    }
}

extension [ToasttyMobileRoute] {
    var containsConversation: Bool {
        contains { $0.conversationID != nil }
    }

    /// The path with its conversation tail matching `selection`. The
    /// conversation route always sits on top of the stack, so syncing removes
    /// any existing conversation entry before appending the selected one.
    func synchronized(
        with selection: SelectedConversationPresentation?
    ) -> [ToasttyMobileRoute] {
        var path = filter { $0.conversationID == nil }
        if let selection {
            path.append(.conversation(selection.id))
        }
        return path
    }
}

/// The app's tabs while the Mac runs its task system. Each tab keeps its
/// own navigation stack. A new tab is a new case.
enum ToasttyMobileTab: Hashable {
    case home
    case tasks
    /// While the Mac has a coordinator. The tab's own screen is the
    /// coordinator's chat.
    case coordinator
}

/// The selected tab and each tab's navigation stack. Switching tabs keeps
/// every stack as it was.
struct ToasttyMobileTabState: Equatable {
    var selected = ToasttyMobileTab.home
    var paths: [ToasttyMobileTab: [ToasttyMobileRoute]] = [:]

    /// The stack of the tab on screen.
    var selectedPath: [ToasttyMobileRoute] {
        get { paths[selected] ?? [] }
        set { paths[selected] = newValue }
    }

    /// The conversation that `tab`'s top screen shows: a conversation on
    /// top of its stack, or the coordinator's chat on the Coordinator tab's
    /// own screen. Only the tab on screen keeps its conversation open.
    func openConversationID(in tab: ToasttyMobileTab, coordinatorConversationID: UUID?) -> UUID? {
        let path = paths[tab] ?? []
        if let last = path.last { return last.conversationID }
        return tab == .coordinator ? coordinatorConversationID : nil
    }
}
