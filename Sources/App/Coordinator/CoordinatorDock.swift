import AppKit
import ConversationUI
import CoreState
import SwiftUI

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

    /// Toasty on the toolbar button: steam while the agent works, and a
    /// badge for unread output, an approval or an error while the chat is
    /// out of sight. Jump to Next Active leaves the coordinator out, so the
    /// badge is how the user sees that it needs them.
    static func toggleIconStatus(mark: SidebarCoordinatorPresentation.Mark, chatOnScreen: Bool) -> ToastyIcon.Status {
        switch mark {
        case .working:
            return .working
        case .unread, .needsApproval, .error:
            return chatOnScreen ? .none : SidebarCoordinatorPresentation.iconStatus(mark)
        case .quiet, .starting, .notRunning:
            return .none
        }
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

/// The coordinator's dock: a header with Toasty, the coordinator's status
/// and two buttons, then the chat. The terminal stays in the coordinator's
/// workspace: Open Full View shows it there.
@available(macOS 15.0, *)
struct CoordinatorDockView: View {
    @ObservedObject var controller: CoordinatorController
    @ObservedObject var sessionRuntimeStore: SessionRuntimeStore
    @ObservedObject var store: AppStore
    let chat: CoordinatorChatModel
    let board: TaskBoardStore
    let location: CoordinatorLocation
    /// Room on the header's left for the titlebar's buttons, when the dock
    /// is at the window's left edge.
    let headerLeadingInset: CGFloat
    let appIsActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Toasty hops once when the dock opens, as toast pops from a toaster.
    @State private var toastyHop: CGFloat = 0

    static let headerButtonSize: CGFloat = 22

    private var workspace: WorkspaceState? {
        store.state.workspacesByID[location.workspaceID]
    }

    private var mark: SidebarCoordinatorPresentation.Mark {
        guard let workspace else { return .notRunning }
        return SidebarCoordinatorPresentation.currentMark(
            controller: controller,
            sessionRuntimeStore: sessionRuntimeStore,
            workspace: workspace,
            readPanelID: location.panelID
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let panelID = location.panelID {
                CoordinatorChatView(
                    model: chat,
                    controller: controller,
                    sessionRuntimeStore: sessionRuntimeStore,
                    board: board,
                    store: store,
                    panelID: panelID,
                    windowID: location.windowID,
                    isOnScreen: true,
                    hasPanelFocus: false,
                    host: .dock
                )
            } else {
                missingTerminal
            }
        }
        .background(ConversationDesignTokens.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coordinator.dock")
        // The chat the user sees is read, as a focused panel's output is.
        .task(id: UnreadClear(isUnread: coordinatorPanelIsUnread, appIsActive: appIsActive)) {
            await clearUnreadWhenSeen()
        }
        .onAppear(perform: hop)
    }

    private var header: some View {
        let mark = mark
        return HStack(spacing: 8) {
            ToastyIcon(
                style: .golden,
                size: 16,
                status: mark == .working ? .working : .none,
                badgeRingColor: ToastyTheme.chromeBackground
            )
            .offset(y: toastyHop)
            Text(AppState.coordinatorWorkspaceTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ToastyTheme.primaryText)
                .lineLimit(1)
                .layoutPriority(1)
            CoordinatorStatusLabel(mark: mark)
            Spacer(minLength: 0)
            headerButton(
                symbol: "arrow.up.left.and.arrow.down.right",
                label: "Open Full View",
                help: "Open the coordinator's workspace, with its chat and terminal",
                identifier: "coordinator.dock.open-full-view"
            ) {
                controller.openFullView()
            }
            headerButton(
                symbol: "arrow.left.to.line",
                label: "Hide Dock",
                help: ToasttyKeyboardShortcuts.toggleCoordinatorDock.helpText("Hide Dock"),
                identifier: "coordinator.dock.hide"
            ) {
                controller.hideDock()
            }
        }
        // Centered on the titlebar's buttons, as the workspace title is.
        .frame(height: Self.headerButtonSize)
        .padding(.top, ToastyTheme.titlebarSidebarToggleTopPadding)
        .padding(.leading, headerLeadingInset)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(height: ToastyTheme.topBarHeight)
        .background(ToastyTheme.chromeBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ToastyTheme.hairline)
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coordinator.dock.header")
    }

    private func headerButton(
        symbol: String,
        label: String,
        help: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ToastyTheme.inactiveText)
                .frame(width: Self.headerButtonSize, height: Self.headerButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    /// A coordinator's workspace without its terminal: only a restart
    /// brings the chat back.
    private var missingTerminal: some View {
        VStack(spacing: 10) {
            Text("The coordinator has no terminal.")
                .font(.system(size: 12))
                .foregroundStyle(ConversationDesignTokens.secondaryText)
            Button("Restart Coordinator") { controller.perform(.restart) }
                .accessibilityIdentifier("coordinator.dock.restart")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func hop() {
        guard reduceMotion == false else { return }
        withAnimation(.easeOut(duration: 0.12)) { toastyHop = -3 }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.5).delay(0.12)) { toastyHop = 0 }
    }

    // MARK: - Unread

    private struct UnreadClear: Equatable {
        var isUnread: Bool
        var appIsActive: Bool
    }

    private var coordinatorPanelIsUnread: Bool {
        guard let panelID = location.panelID,
              let workspace,
              let tabID = workspace.tabID(containingPanelID: panelID) else { return false }
        return workspace.tab(id: tabID)?.unreadPanelIDs.contains(panelID) == true
    }

    /// After the delay a focused panel waits, so that a dock the user only
    /// passes through keeps its output unread.
    private func clearUnreadWhenSeen() async {
        guard coordinatorPanelIsUnread, appIsActive, let panelID = location.panelID else { return }
        try? await Task.sleep(nanoseconds: WorkspaceView.seenUnreadClearDelayNanoseconds)
        guard Task.isCancelled == false, store.isAppActive, controller.dockShows(in: location.windowID) else { return }
        _ = store.send(.markPanelNotificationsRead(workspaceID: location.workspaceID, panelID: panelID))
    }
}

/// The dock's button in the window's toolbar, after the sidebar's. Toasty
/// is golden while the chat is on screen and a gray outline while it is
/// not; then a badge shows unread output, an approval or an error.
struct CoordinatorDockToggleButton: View {
    @ObservedObject var controller: CoordinatorController
    @ObservedObject var sessionRuntimeStore: SessionRuntimeStore
    @ObservedObject var store: AppStore
    let windowID: UUID

    var body: some View {
        let location = controller.location
        let window = store.window(id: windowID)
        let chatOnScreen = window.map {
            CoordinatorDockPresentation.chatOnScreen(window: $0, coordinator: location, chatAvailable: controller.chatIsAvailable)
        } ?? false
        let dockShows = controller.dockShows(in: windowID)
        let status = CoordinatorDockPresentation.toggleIconStatus(mark: mark(location: location), chatOnScreen: chatOnScreen)
        let title = CoordinatorDockPresentation.toggleTitle(dockShows: dockShows)
        Button {
            controller.toggleDock()
        } label: {
            ToastyIcon(
                style: chatOnScreen ? .golden : .outline,
                size: 14,
                status: status,
                badgeRingColor: ToastyTheme.chromeBackground
            )
            .frame(width: ToastyTheme.titlebarSidebarToggleButtonSize, height: ToastyTheme.titlebarSidebarToggleButtonSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(ToasttyKeyboardShortcuts.toggleCoordinatorDock.helpText(title))
        .accessibilityLabel(title)
        .accessibilityValue(SidebarCoordinatorPresentation.statusText(badgeMark(status)) ?? "")
        .accessibilityIdentifier("titlebar.toggle.coordinator-dock")
    }

    private func mark(location: CoordinatorLocation?) -> SidebarCoordinatorPresentation.Mark {
        guard let location, let workspace = store.state.workspacesByID[location.workspaceID] else { return .notRunning }
        let selected = store.selectedWorkspaceID(in: windowID) == location.workspaceID
        return SidebarCoordinatorPresentation.currentMark(
            controller: controller,
            sessionRuntimeStore: sessionRuntimeStore,
            workspace: workspace,
            readPanelID: selected ? workspace.focusedPanelID : (controller.dockShows(in: windowID) ? location.panelID : nil)
        )
    }

    private func badgeMark(_ status: ToastyIcon.Status) -> SidebarCoordinatorPresentation.Mark {
        switch status {
        case .none: .quiet
        case .working: .working
        case .unread: .unread
        case .needsApproval: .needsApproval
        case .error: .error
        }
    }
}
