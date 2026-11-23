import CoreState
import Foundation

/// When the coordinator's dock shows, and what its toolbar button shows.
///
/// The dock is a column between the sidebar and the workspace with the
/// coordinator's chat. It shows only in the window that holds the
/// coordinator's workspace, and only while another workspace is selected
/// there: the coordinator's own workspace shows the same chat in full.
@MainActor
enum CoordinatorDockPresentation {
    static func showsDock(window: WindowState, coordinator: CoordinatorLocation?, chatAvailable: Bool) -> Bool {
        guard chatAvailable,
              let coordinator,
              coordinator.windowID == window.id,
              window.coordinatorDockVisible else { return false }
        return window.selectedWorkspaceID != coordinator.workspaceID
    }

    /// The toolbar button shows in the window that holds the coordinator's
    /// workspace, while the chat can show.
    static func showsToggle(windowID: UUID, coordinator: CoordinatorLocation?, chatAvailable: Bool) -> Bool {
        chatAvailable && coordinator?.windowID == windowID
    }

    /// The chat is on screen in `window`: in the dock, or in the full view
    /// when the Tasks view does not cover it.
    static func chatOnScreen(window: WindowState, coordinator: CoordinatorLocation?, chatAvailable: Bool) -> Bool {
        guard let coordinator, coordinator.windowID == window.id else { return false }
        if showsDock(window: window, coordinator: coordinator, chatAvailable: chatAvailable) { return true }
        return window.selectedWorkspaceID == coordinator.workspaceID && window.showsTasksView == false
    }

    static func toggleTitle(dockShows: Bool) -> String {
        dockShows ? "Hide Coordinator Dock" : "Show Coordinator Dock"
    }

    /// What Cmd+Shift+K does. The keyboard goes to the chat's field before
    /// the dock hides, so the key always takes the user to the field first.
    enum ShortcutAction: Equatable {
        /// Shows the dock, with the keyboard in its field. From the full
        /// view, the window goes back to another workspace.
        case showDock
        /// The dock shows; its field takes the keyboard.
        case focusDock
        /// The full view shows the chat; its field takes the keyboard.
        case focusFullView
        /// The dock's field has the keyboard; the dock hides.
        case hideDock
    }

    static func shortcutAction(
        dockShows: Bool,
        dockHasKeyboard: Bool,
        fullViewChatOnScreen: Bool,
        fullViewHasKeyboard: Bool
    ) -> ShortcutAction {
        if dockShows {
            return dockHasKeyboard ? .hideDock : .focusDock
        }
        if fullViewChatOnScreen, fullViewHasKeyboard == false {
            return .focusFullView
        }
        return .showDock
    }

    static func shortcutTitle(_ action: ShortcutAction) -> String {
        switch action {
        case .showDock: toggleTitle(dockShows: false)
        case .hideDock: toggleTitle(dockShows: true)
        case .focusDock, .focusFullView: "Focus Coordinator Chat"
        }
    }

    /// The workspace the window shows when the dock opens from the full
    /// view: the one it showed before, while it is still in the window, or
    /// else the first in the sidebar. `nil` when the window holds no other.
    static func workspaceLeavingFullView(
        state: AppState,
        coordinator: CoordinatorLocation,
        previousWorkspaceID: UUID?
    ) -> UUID? {
        guard let window = state.window(id: coordinator.windowID) else { return nil }
        if let previousWorkspaceID,
           previousWorkspaceID != coordinator.workspaceID,
           window.workspaceIDs.contains(previousWorkspaceID),
           state.workspacesByID[previousWorkspaceID] != nil {
            return previousWorkspaceID
        }
        return state.topLevelWorkspaceIDs(in: coordinator.windowID).first
            ?? window.workspaceIDs.first { $0 != coordinator.workspaceID }
    }
}
