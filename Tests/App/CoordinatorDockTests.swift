@testable import ToasttyApp
import AppKit
import CoreState
import Foundation
import Testing

/// The coordinator's dock: where it shows, how the chat moves between the
/// dock and the full view, and what its toolbar button shows.
@MainActor
@Suite(.serialized)
struct CoordinatorDockTests {
    // MARK: - Where the dock shows

    @Test func theDockShowsOnlyInTheCoordinatorsWindowBesideAnotherWorkspace() {
        let taskWorkspaceID = UUID()
        let coordinator = CoordinatorLocation(windowID: UUID(), workspaceID: UUID(), panelID: UUID())
        var window = WindowState(
            id: coordinator.windowID,
            frame: CGRectCodable(x: 0, y: 0, width: 1440, height: 900),
            workspaceIDs: [coordinator.workspaceID, taskWorkspaceID],
            selectedWorkspaceID: taskWorkspaceID,
            coordinatorDockVisible: true
        )
        func shows(chat: Bool = true) -> Bool {
            CoordinatorDockPresentation.showsDock(window: window, coordinator: coordinator, chatAvailable: chat)
        }
        #expect(shows())
        #expect(CoordinatorDockPresentation.chatOnScreen(window: window, coordinator: coordinator, chatAvailable: true))
        // The Tasks view covers only the workspace beside the dock.
        window.showsTasksView = true
        #expect(shows())
        window.showsTasksView = false
        // On macOS 14, or before the app has the conversation access, there
        // is no chat to show.
        #expect(shows(chat: false) == false)
        // The full view shows the same chat, so the dock steps aside.
        window.selectedWorkspaceID = coordinator.workspaceID
        #expect(shows() == false)
        #expect(CoordinatorDockPresentation.chatOnScreen(window: window, coordinator: coordinator, chatAvailable: true))
        window.showsTasksView = true
        #expect(CoordinatorDockPresentation.chatOnScreen(window: window, coordinator: coordinator, chatAvailable: true) == false)
        window.showsTasksView = false
        window.selectedWorkspaceID = taskWorkspaceID
        window.coordinatorDockVisible = false
        #expect(shows() == false)
        #expect(CoordinatorDockPresentation.chatOnScreen(window: window, coordinator: coordinator, chatAvailable: true) == false)
        // Another window has neither the dock nor its button.
        window.coordinatorDockVisible = true
        let otherWindow = WindowState(
            id: UUID(),
            frame: window.frame,
            workspaceIDs: [UUID()],
            selectedWorkspaceID: nil,
            coordinatorDockVisible: true
        )
        #expect(CoordinatorDockPresentation.showsDock(window: otherWindow, coordinator: coordinator, chatAvailable: true) == false)
        #expect(CoordinatorDockPresentation.showsToggle(windowID: otherWindow.id, coordinator: coordinator, chatAvailable: true) == false)
        #expect(CoordinatorDockPresentation.showsToggle(windowID: window.id, coordinator: coordinator, chatAvailable: true))
        #expect(CoordinatorDockPresentation.showsToggle(windowID: window.id, coordinator: nil, chatAvailable: true) == false)
    }

    @Test func toastyOnTheToolbarShowsABadgeOnlyWhileTheChatIsOutOfSight() {
        typealias Presentation = CoordinatorDockPresentation
        for mark in [SidebarCoordinatorPresentation.Mark.unread, .needsApproval, .error] {
            #expect(Presentation.toggleIconStatus(mark: mark, chatOnScreen: false) == SidebarCoordinatorPresentation.iconStatus(mark))
            #expect(Presentation.toggleIconStatus(mark: mark, chatOnScreen: true) == .none)
        }
        // Steam shows wherever the chat is.
        #expect(Presentation.toggleIconStatus(mark: .working, chatOnScreen: true) == .working)
        #expect(Presentation.toggleIconStatus(mark: .working, chatOnScreen: false) == .working)
        for mark in [SidebarCoordinatorPresentation.Mark.quiet, .starting, .notRunning] {
            #expect(Presentation.toggleIconStatus(mark: mark, chatOnScreen: false) == .none)
        }
    }

    @Test func thePaletteOffersTheDockWithItsShortcut() throws {
        func dockCommand(_ option: PaletteCoordinatorOption) -> PaletteCommandDescriptor? {
            CommandPaletteTaskCatalog.descriptors(current: nil, releases: [], coordinator: option)
                .first { $0.id == "coordinator.dock.toggle" }
        }
        #expect(dockCommand(PaletteCoordinatorOption(isOpen: true)) == nil)
        let show = try #require(dockCommand(PaletteCoordinatorOption(isOpen: true, dockShows: false)))
        #expect(show.title == "Show Coordinator Dock")
        #expect(show.shortcut?.symbolLabel == "⇧⌘K")
        #expect(show.invocation == .task(.toggleCoordinatorDock))
        #expect(dockCommand(PaletteCoordinatorOption(isOpen: true, dockShows: true))?.title == "Hide Coordinator Dock")
    }

    // MARK: - With the real controller and chat

    @Test func theDockAndTheFullViewTakeTurnsWithTheChat() async throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        let store = fixture.store
        let controller = fixture.controller
        let location = try #require(store.state.coordinator)
        let windowID = location.windowID
        let taskWorkspaceID = try #require(store.state.topLevelWorkspaceIDs(in: windowID).first)
        func window() throws -> WindowState { try #require(store.window(id: windowID)) }

        // The fixture opened the full view. Leaving it for the dock goes to
        // the first workspace in the sidebar.
        #expect(store.selectedWorkspaceID(in: windowID) == location.workspaceID)
        #expect(controller.dockShows(in: windowID) == false)
        #expect(controller.showDock(focusComposer: true))
        #expect(store.selectedWorkspaceID(in: windowID) == taskWorkspaceID)
        #expect(try window().coordinatorDockVisible)

        // Open Full View: the dock steps aside, and comes back when the user
        // leaves the full view by any way.
        controller.openFullView()
        #expect(store.selectedWorkspaceID(in: windowID) == location.workspaceID)
        #expect(controller.dockShows(in: windowID) == false)
        #expect(store.selectWorkspace(windowID: windowID, workspaceID: taskWorkspaceID, preferringUnreadSessionPanelIn: nil))
        #expect(controller.dockShows(in: windowID))

        // The toolbar button hides and shows it.
        controller.toggleDock()
        #expect(controller.dockShows(in: windowID) == false)
        #expect(store.selectedWorkspaceID(in: windowID) == taskWorkspaceID)
        controller.toggleDock()
        #expect(controller.dockShows(in: windowID))

        // Show Terminal in the dock opens the full view with the terminal.
        controller.openFullView(showingTerminal: true)
        #expect(controller.showsTerminal)
        #expect(store.selectedWorkspaceID(in: windowID) == location.workspaceID)
        controller.showsTerminal = false

        // A chip in the full view opens its task, with the chat in the dock.
        controller.hideDock()
        controller.openTaskSpaceFromChat(workspaceID: taskWorkspaceID, fallbackWindowID: windowID)
        #expect(store.selectedWorkspaceID(in: windowID) == taskWorkspaceID)
        #expect(controller.dockShows(in: windowID))

        // The Dock button goes back to the workspace the full view came from.
        let secondWorkspaceID = try addWorkspace(to: store, windowID: windowID, title: "second")
        #expect(store.selectWorkspace(windowID: windowID, workspaceID: secondWorkspaceID, preferringUnreadSessionPanelIn: nil))
        controller.openFullView()
        #expect(controller.showDock(focusComposer: false))
        #expect(store.selectedWorkspaceID(in: windowID) == secondWorkspaceID)

        // Without the chat, the dock never shows.
        controller.supportsChat = false
        #expect(controller.dockShows(in: windowID) == false)
        #expect(controller.showDock(focusComposer: true) == false)
    }

    @Test func theChatReadsOnWhileEitherViewShowsAndGivesTheKeyboardToTheOneThatOpens() throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        let chat = fixture.chat
        let panelID = fixture.panelID

        // The full view opens the dock: for a moment both views show. The
        // order in which SwiftUI shows and hides them must not matter.
        chat.show(panelID: panelID, host: .panel)
        chat.show(panelID: panelID, host: .dock)
        chat.hide(panelID: panelID, host: .panel)
        #expect(chat.shownPanelID == panelID)
        #expect(chat.activeHost == .dock)
        chat.show(panelID: panelID, host: .panel)
        chat.hide(panelID: panelID, host: .dock)
        #expect(chat.shownPanelID == panelID)
        #expect(chat.activeHost == .panel)
        chat.hide(panelID: panelID, host: .panel)
        #expect(chat.shownPanelID == nil)
        #expect(chat.activeHost == nil)

        // A row click opens the dock: its field takes the keyboard when it
        // shows, not before, and only once.
        let before = chat.composerFocusRequest
        chat.requestComposerFocus(host: .dock)
        #expect(chat.composerFocusRequest == before)
        chat.show(panelID: panelID, host: .dock)
        #expect(chat.composerFocusRequest == before + 1)
        chat.hide(panelID: panelID, host: .dock)
        chat.show(panelID: panelID, host: .dock)
        #expect(chat.composerFocusRequest == before + 1)
        // While the dock shows, the request goes to it at once.
        chat.requestComposerFocus(host: .dock)
        #expect(chat.composerFocusRequest == before + 2)
        chat.hide(panelID: panelID, host: .dock)

        // The full view opened before the dock could: the dock does not
        // take the keyboard later, when it shows by another way.
        chat.requestComposerFocus(host: .dock)
        chat.show(panelID: panelID, host: .panel)
        chat.hide(panelID: panelID, host: .panel)
        chat.show(panelID: panelID, host: .dock)
        #expect(chat.composerFocusRequest == before + 2)
    }

    /// Cmd+Shift+K takes the user to the chat's field before it hides the
    /// dock: from a terminal while the dock shows, and in the full view.
    /// The app's key handling owns the key, so a stale View menu item
    /// cannot drop it.
    @Test func theDockShortcutGivesTheFieldTheKeyboardBeforeItHidesTheDock() throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        let store = fixture.store
        let controller = fixture.controller
        let chat = fixture.chat
        let location = try #require(store.state.coordinator)
        let windowID = location.windowID
        let taskWorkspaceID = try #require(store.state.topLevelWorkspaceIDs(in: windowID).first)
        // The key goes through the app's key handling, as a press does.
        let keys = try CoordinatorChatTextSizeTests.Keys(fixture)

        // Each host's field, and a view that stands for a terminal, in
        // off-screen windows: only which view has the keyboard matters.
        func window(_ views: NSView...) -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            let content = NSView(frame: window.contentLayoutRect)
            views.forEach(content.addSubview)
            window.contentView = content
            return window
        }
        let dockField = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        let terminal = NSTextView(frame: NSRect(x: 0, y: 100, width: 200, height: 20))
        let dockWindow = window(dockField, terminal)
        let panelField = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        let policy = NSTextView(frame: NSRect(x: 0, y: 100, width: 200, height: 20))
        let panelWindow = window(panelField, policy)
        defer {
            dockWindow.close()
            panelWindow.close()
        }
        chat.setComposerTextView(dockField, host: .dock)
        chat.setComposerTextView(panelField, host: .panel)

        // The fixture opened the full view, and its field has the keyboard:
        // the key goes to the dock, which takes the keyboard when it shows.
        chat.show(panelID: fixture.panelID, host: .panel)
        #expect(panelWindow.makeFirstResponder(panelField))
        #expect(controller.dockShortcutAction == .showDock)
        #expect(try keys.press(.dock) == .coordinatorDockShortcut)
        #expect(store.selectedWorkspaceID(in: windowID) == taskWorkspaceID)
        #expect(controller.dockShows(in: windowID))
        chat.hide(panelID: fixture.panelID, host: .panel)
        var requests = chat.composerFocusRequest
        chat.show(panelID: fixture.panelID, host: .dock)
        #expect(chat.composerFocusRequest == requests + 1)

        // The user types in a terminal beside the dock. The key gives the
        // dock's field the keyboard and leaves the dock open.
        #expect(dockWindow.makeFirstResponder(terminal))
        #expect(controller.dockShortcutAction == .focusDock)
        #expect(CoordinatorDockPresentation.shortcutTitle(.focusDock) == "Focus Coordinator Chat")
        requests = chat.composerFocusRequest
        #expect(try keys.press(.dock) == .coordinatorDockShortcut)
        #expect(chat.composerFocusRequest == requests + 1)
        #expect(controller.dockShows(in: windowID))

        // With the keyboard in the dock's field, the key hides the dock.
        #expect(dockWindow.makeFirstResponder(dockField))
        #expect(controller.dockShortcutAction == .hideDock)
        #expect(try keys.press(.dock) == .coordinatorDockShortcut)
        #expect(controller.dockShows(in: windowID) == false)
        #expect(store.selectedWorkspaceID(in: windowID) == taskWorkspaceID)
        chat.hide(panelID: fixture.panelID, host: .dock)

        // In the full view, with another panel focused, as policy.md's can
        // be, the key gives the chat's field the keyboard and focuses the
        // coordinator's panel.
        controller.openFullView()
        chat.show(panelID: fixture.panelID, host: .panel)
        #expect(store.send(.splitFocusedSlot(workspaceID: location.workspaceID, orientation: .horizontal)))
        let otherPanelID = try #require(store.state.workspacesByID[location.workspaceID]?.focusedPanelID)
        #expect(otherPanelID != location.panelID)
        #expect(panelWindow.makeFirstResponder(policy))
        #expect(controller.dockShortcutAction == .focusFullView)
        requests = chat.composerFocusRequest
        #expect(try keys.press(.dock) == .coordinatorDockShortcut)
        #expect(chat.composerFocusRequest == requests + 1)
        #expect(store.selectedWorkspaceID(in: windowID) == location.workspaceID)
        #expect(store.state.workspacesByID[location.workspaceID]?.focusedPanelID == location.panelID)

        // The chat is off screen in the full view: the key opens the dock,
        // as before. The panel shows the terminal; the Tasks view covers the
        // workspace; focus mode shows only the other panel.
        #expect(panelWindow.makeFirstResponder(policy))
        controller.showsTerminal = true
        #expect(controller.dockShortcutAction == .showDock)
        controller.showsTerminal = false
        #expect(store.send(.setTasksViewShown(windowID: windowID, shown: true)))
        #expect(controller.dockShortcutAction == .showDock)
        #expect(store.send(.setTasksViewShown(windowID: windowID, shown: false)))
        #expect(controller.dockShortcutAction == .focusFullView)
        #expect(store.send(.focusPanel(workspaceID: location.workspaceID, panelID: otherPanelID)))
        #expect(store.send(.toggleFocusedPanelMode(workspaceID: location.workspaceID)))
        #expect(controller.dockShortcutAction == .showDock)
    }

    private func addWorkspace(to store: AppStore, windowID: UUID, title: String) throws -> UUID {
        let before = Set(store.window(id: windowID)?.workspaceIDs ?? [])
        #expect(store.send(.createWorkspace(windowID: windowID, title: title, activate: false)))
        return try #require(store.window(id: windowID)?.workspaceIDs.first { before.contains($0) == false })
    }

    // MARK: - Jump to Next Active

    @Test func jumpToNextActiveLeavesTheCoordinatorOut() throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        let store = fixture.store
        let location = try #require(store.state.coordinator)
        let windowID = location.windowID
        let taskWorkspaceID = try #require(store.state.topLevelWorkspaceIDs(in: windowID).first)
        #expect(store.selectWorkspace(windowID: windowID, workspaceID: taskWorkspaceID, preferringUnreadSessionPanelIn: nil))

        // The coordinator's reply is unread: before the dock, the jump went
        // to the full view.
        #expect(store.send(.recordDesktopNotification(workspaceID: location.workspaceID, panelID: fixture.panelID)))
        #expect(store.nextUnreadOrActivePanelTargetFromCommand(preferredWindowID: windowID, sessionRuntimeStore: nil) == nil)

        // An unread task panel is still a target.
        let otherWorkspaceID = try addWorkspace(to: store, windowID: windowID, title: "task")
        #expect(store.selectWorkspace(windowID: windowID, workspaceID: taskWorkspaceID, preferringUnreadSessionPanelIn: nil))
        let otherPanelID = try #require(store.state.workspacesByID[otherWorkspaceID]?.focusedPanelID)
        #expect(store.send(.recordDesktopNotification(workspaceID: otherWorkspaceID, panelID: otherPanelID)))
        let target = store.nextUnreadOrActivePanelTargetFromCommand(preferredWindowID: windowID, sessionRuntimeStore: nil)
        #expect(target?.panelID == otherPanelID)

        // From the full view too.
        #expect(store.selectWorkspace(windowID: windowID, workspaceID: location.workspaceID, preferringUnreadSessionPanelIn: nil))
        let fromFullView = store.nextUnreadOrActivePanelTargetFromCommand(preferredWindowID: windowID, sessionRuntimeStore: nil)
        #expect(fromFullView?.panelID == otherPanelID)
    }
}
