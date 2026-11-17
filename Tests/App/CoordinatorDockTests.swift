@testable import ToasttyApp
import AppKit
import CoreState
import Foundation
import SwiftUI
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

    /// Show Terminal, in the full view's chat or in the dock, shows the
    /// coordinator's terminal with the keyboard, so that the user can
    /// answer a folder-trust question with the keys at once. The chat's
    /// field had the keyboard, and a terminal that shows does not take the
    /// keyboard from that field by itself. The real workspace view shows
    /// the chat over the terminal, as in the app.
    @Test func showTerminalGivesTheTerminalTheKeyboard() async throws {
        guard #available(macOS 15.0, *) else { return }
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        let store = fixture.store
        let controller = fixture.controller
        let location = try #require(store.state.coordinator)
        let windowID = location.windowID
        let taskWorkspaceID = try #require(store.state.topLevelWorkspaceIDs(in: windowID).first)
        let host = try HostedCoordinatorWindow(fixture, windowID: windowID)
        defer { host.close() }
        let terminal = fixture.conversations.terminalRuntimeRegistry.controller(
            for: fixture.panelID, workspaceID: location.workspaceID, windowID: windowID
        )
        func chatFieldHasTheKeyboard() -> Bool {
            fixture.chat.composerTextView.map { $0.window === host.window && host.window.firstResponder === $0 } ?? false
        }

        // The full view: the chat covers the terminal, and the chat's field
        // has the keyboard.
        try await fixture.waitUntil("the chat's field to take the keyboard", chatFieldHasTheKeyboard)
        #expect(terminal.hasKeyboardFocus == false)

        // Show Terminal in the chat's notice, or Terminal in the panel's
        // header. The terminal keeps the keyboard after the chat has gone.
        controller.showTerminal()
        try await fixture.waitUntil("the terminal to take the keyboard") { terminal.hasKeyboardFocus }
        try await Task.sleep(for: .milliseconds(300))
        #expect(terminal.hasKeyboardFocus)

        // Chat in the panel's header: the chat's field takes it back.
        controller.showsTerminal = false
        try await fixture.waitUntil("the chat's field to take the keyboard again", chatFieldHasTheKeyboard)

        // Another panel beside the chat, as policy.md's can be, has the
        // focus: Show Terminal focuses the coordinator's panel too.
        #expect(store.send(.splitFocusedSlot(workspaceID: location.workspaceID, orientation: .horizontal)))
        #expect(store.state.workspacesByID[location.workspaceID]?.focusedPanelID != fixture.panelID)
        controller.showTerminal()
        try await fixture.waitUntil("the terminal to take the keyboard from the panel beside it") { terminal.hasKeyboardFocus }
        #expect(store.state.workspacesByID[location.workspaceID]?.focusedPanelID == fixture.panelID)
        controller.showsTerminal = false
        try await fixture.waitUntil("the chat's field to take the keyboard once more", chatFieldHasTheKeyboard)

        // The dock beside another workspace: its field, outside every
        // panel, has the keyboard. Its Show Terminal opens the full view
        // with the terminal, and the terminal takes the keyboard.
        #expect(store.selectWorkspace(windowID: windowID, workspaceID: taskWorkspaceID, preferringUnreadSessionPanelIn: nil))
        let dockField = CoordinatorComposerTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        host.window.contentView?.addSubview(dockField)
        try await Task.sleep(for: .milliseconds(300))
        #expect(host.window.makeFirstResponder(dockField))
        controller.openFullView(showingTerminal: true)
        try await fixture.waitUntil("the terminal to take the keyboard from the dock's field") { terminal.hasKeyboardFocus }
        #expect(store.selectedWorkspaceID(in: windowID) == location.workspaceID)
        #expect(store.state.workspacesByID[location.workspaceID]?.focusedPanelID == fixture.panelID)
        try await Task.sleep(for: .milliseconds(300))
        #expect(terminal.hasKeyboardFocus)
    }

    /// A file dropped on the chat, perhaps from Finder, gives that view's
    /// field the keyboard and makes Toastty the active app, so that the
    /// user can type the message that goes with it. In the full view the
    /// coordinator's panel takes the focus; the dock stays beside the
    /// workspace it shows.
    @Test func aFileDroppedOnTheChatGivesThatViewsFieldTheKeyboard() throws {
        let fixture = try CoordinatorChatFixture()
        defer { fixture.tearDown() }
        let store = fixture.store
        let controller = fixture.controller
        let chat = fixture.chat
        let location = try #require(store.state.coordinator)
        let windowID = location.windowID
        let image = QuickEntryTests.pasteboard()
        image.setData(try QuickEntryTests.pngData(), forType: .png)

        // The full view, with another panel focused, as policy.md's can be.
        controller.openFullView()
        chat.show(panelID: fixture.panelID, host: .panel)
        #expect(store.send(.splitFocusedSlot(workspaceID: location.workspaceID, orientation: .horizontal)))
        #expect(store.state.workspacesByID[location.workspaceID]?.focusedPanelID != location.panelID)

        // Text is not a file: the chat takes no drop and nothing moves.
        let text = QuickEntryTests.pasteboard()
        text.setString("hello", forType: .string)
        var requests = chat.composerFocusRequest
        #expect(chat.attachmentDropTarget(host: .panel).performDrop(text) == false)
        #expect(chat.composerFocusRequest == requests)
        #expect(fixture.clock.activations == 0)

        #expect(chat.attachmentDropTarget(host: .panel).performDrop(image))
        #expect(chat.composerFocusRequest == requests + 1)
        #expect(fixture.clock.activations == 1)
        #expect(store.selectedWorkspaceID(in: windowID) == location.workspaceID)
        #expect(store.state.workspacesByID[location.workspaceID]?.focusedPanelID == location.panelID)
        chat.hide(panelID: fixture.panelID, host: .panel)

        // The dock beside a task's workspace.
        #expect(controller.showDock(focusComposer: false))
        let taskWorkspaceID = try #require(store.selectedWorkspaceID(in: windowID))
        #expect(taskWorkspaceID != location.workspaceID)
        chat.show(panelID: fixture.panelID, host: .dock)
        requests = chat.composerFocusRequest
        #expect(chat.attachmentDropTarget(host: .dock).performDrop(image))
        #expect(chat.composerFocusRequest == requests + 1)
        #expect(fixture.clock.activations == 2)
        #expect(store.selectedWorkspaceID(in: windowID) == taskWorkspaceID)
        #expect(controller.dockShows(in: windowID))
        chat.hide(panelID: fixture.panelID, host: .dock)
    }

    /// The coordinator's window as the app shows it: the real workspace
    /// view, with the chat over the coordinator's terminal, and the
    /// keyboard connected between them as the app connects it.
    @MainActor
    private final class HostedCoordinatorWindow {
        let window: NSWindow
        private let home: URL
        /// The views reach the coordinator through the task system, which
        /// they do not keep.
        private let tasks: TaskCoordinator

        init(_ fixture: CoordinatorChatFixture, windowID: UUID) throws {
            let store = fixture.store
            let conversations = fixture.conversations
            let registry = conversations.terminalRuntimeRegistry
            let sessions = conversations.sessionRuntimeStore
            registry.bind(store: store)
            registry.synchronize(with: store.state)
            sessions.bind(store: store)
            home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            tasks = TaskCoordinator(
                records: TaskRecordStore(fileURL: home.appendingPathComponent("tasks.json")),
                store: store, launcher: nil,
                configLoader: { TasksConfig() },
                attachmentsDirectoryURL: home.appendingPathComponent("attachments"),
                hasActiveSession: { _ in false }, grantScope: { _, _ in }
            )
            tasks.coordinatorController = fixture.controller
            sessions.taskCoordinator = tasks
            fixture.controller.connectKeyboard(to: registry)

            let agents = AgentCatalogStore(homeDirectoryPath: home.path)
            let webPanels = WebPanelRuntimeRegistry()
            webPanels.bind(store: store)
            let view = WorkspaceView(
                windowID: windowID,
                store: store,
                agentCatalogStore: agents,
                terminalProfileStore: TerminalProfileStore(homeDirectoryPath: home.path, environment: [:]),
                terminalRuntimeRegistry: registry,
                terminalLiveTitleStore: registry.terminalLiveTitleStore,
                webPanelRuntimeRegistry: webPanels,
                sessionRuntimeStore: sessions,
                profileShortcutRegistry: ProfileShortcutRegistry(
                    terminalProfiles: .empty,
                    terminalProfilesFilePath: home.appendingPathComponent("terminal-profiles.toml").path,
                    agentProfiles: .empty,
                    agentProfilesFilePath: home.appendingPathComponent("agents.toml").path
                ),
                focusedPanelCommandController: FocusedPanelCommandController(
                    store: store,
                    runtimeRegistry: registry,
                    slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator(),
                    webPanelRuntimeRegistry: webPanels
                ),
                agentLaunchService: AgentLaunchService(
                    store: store,
                    terminalCommandRouter: registry,
                    sessionRuntimeStore: sessions,
                    agentCatalogProvider: agents
                ),
                openGettingStartedPanel: {},
                toggleCommandPalette: { _ in },
                presentCommandPalette: { _, _ in },
                terminalRuntimeContext: TerminalWindowRuntimeContext(windowID: windowID, runtimeRegistry: registry),
                leftColumnVisible: true
            )
            .frame(width: 900, height: 600)
            // Off the screen: only which view has the keyboard matters.
            window = NSWindow(
                contentRect: NSRect(x: -10_000, y: -10_000, width: 900, height: 600),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            let hosting = NSHostingView(rootView: view)
            hosting.frame = content.bounds
            content.addSubview(hosting)
            window.contentView = content
            window.makeKeyAndOrderFront(nil)
        }

        func close() {
            window.close()
            try? FileManager.default.removeItem(at: home)
        }
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
