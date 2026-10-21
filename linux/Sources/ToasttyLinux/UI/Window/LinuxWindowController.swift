import CGtk
import CoreState
import Foundation

/// One `AdwApplicationWindow` per Toastty `WindowState`:
///
/// ```
/// AdwApplicationWindow
/// └ AdwToastOverlay
///   └ AdwOverlaySplitView (workspace sidebar, F9)
///     ├ sidebar: SidebarController
///     └ AdwOverlaySplitView (right panel, end side, Shift+F9)
///       ├ sidebar: RightPanelController
///       └ AdwToolbarView
///         ├ AdwHeaderBar (sidebar toggle, new tab, title, zoom pill, menu, right panel)
///         ├ AdwTabBar (the selected workspace's tabs)
///         └ GtkStack: workspace content | empty state
/// ```
@MainActor
public final class LinuxWindowController {
    public let windowID: UUID
    public let window: WidgetPtr
    private let store: any LinuxStoreBinding
    private let hosts: PanelHostRegistry
    private let preferences: LinuxUIPreferences
    private let toastOverlay: WidgetPtr
    private let outerSplit: WidgetPtr
    private let innerSplit: WidgetPtr
    private let windowTitle: WidgetPtr
    private let tabBar: WidgetPtr
    private let zoomPill: WidgetPtr
    /// Header agent buttons (macOS top bar): one per agent profile, or
    /// "Get Started…" when no profiles are configured.
    private let agentButtons: WidgetPtr
    private var agentButtonsByProfileID: [String: WidgetPtr] = [:]
    private let mainStack: WidgetPtr
    public let sidebar: SidebarController
    public let content: WorkspaceContentController
    public let rightPanel: RightPanelController
    private var keyboard: KeyboardShortcutController?
    private var isSyncing = false
    private var sidebarResize: SplitViewResizeHandle!
    private var rightPanelResize: SplitViewResizeHandle!
    private var frameSaveTimer: guint = 0
    /// Linux sidebar width without an override (the cards are wider than the
    /// macOS rows, so the macOS 180/280 defaults do not carry over).
    static let defaultSidebarWidth: Double = 248
    private var renderScheduled = false
    private var isClosing = false
    public private(set) var palette: CommandPaletteDialog?

    /// Window-level request to run an app command (quit, new window …).
    public var onAppCommand: ((String, UUID) -> Void)?

    public init(
        application: OpaquePointer,
        windowID: UUID,
        store: any LinuxStoreBinding,
        hosts: PanelHostRegistry,
        preferences: LinuxUIPreferences
    ) {
        self.windowID = windowID
        self.store = store
        self.hosts = hosts
        self.preferences = preferences

        window = adw_application_window_new(cast(application))
        gtk_window_set_title(cast(window), "Toastty")
        if let frame = store.state.window(id: windowID)?.frame {
            gtk_window_set_default_size(cast(window), Int32(max(frame.width, 640)), Int32(max(frame.height, 420)))
        }
        gtk_widget_set_size_request(window, 420, 320)

        sidebar = SidebarController(windowID: windowID, store: store)
        content = WorkspaceContentController(windowID: windowID, store: store, hosts: hosts)
        rightPanel = RightPanelController(windowID: windowID, store: store, hosts: hosts)

        // Main column.
        let toolbar = adw_toolbar_view_new()!
        let header = adw_header_bar_new()!
        let sidebarButton = Gtk.iconButton(
            "sidebar-show-symbolic",
            tooltip: "Toggle Sidebar (\(ShortcutLabels.label(forCommand: "window.toggle-sidebar") ?? ""))",
            action: "win.window.toggle-sidebar"
        )
        adw_header_bar_pack_start(cast(header), sidebarButton)
        let newTabButton = Gtk.iconButton(
            "tab-new-symbolic",
            tooltip: "New Tab (\(ShortcutLabels.label(forCommand: "workspace.tab.create") ?? ""))",
            action: "win.workspace.tab.create"
        )
        adw_header_bar_pack_start(cast(header), newTabButton)
        windowTitle = adw_window_title_new("Toastty", nil)
        adw_header_bar_set_title_widget(cast(header), windowTitle)

        let menuButton = gtk_menu_button_new()!
        gtk_menu_button_set_icon_name(cast(menuButton), "open-menu-symbolic")
        gtk_menu_button_set_primary(cast(menuButton), 1)
        gtk_widget_set_tooltip_text(menuButton, "Main Menu")
        let menuModel = LinuxMenus.primaryMenu()
        gtk_menu_button_set_menu_model(cast(menuButton), cast(menuModel))
        g_object_unref(UnsafeMutableRawPointer(menuModel))
        adw_header_bar_pack_end(cast(header), menuButton)
        let rightButton = Gtk.iconButton(
            "sidebar-show-right-symbolic",
            tooltip: "Toggle Right Panel (\(ShortcutLabels.label(forCommand: "window.toggle-right-panel") ?? ""))",
            action: "win.window.toggle-right-panel"
        )
        adw_header_bar_pack_end(cast(header), rightButton)
        let paletteButton = Gtk.iconButton(
            "system-search-symbolic",
            tooltip: "Command Palette (\(ShortcutLabels.label(forCommand: "command-palette.toggle") ?? ""))",
            action: "win.command-palette.toggle"
        )
        adw_header_bar_pack_end(cast(header), paletteButton)
        zoomPill = Gtk.button("Focused Panel", action: "win.panel.focus-mode.toggle", classes: ["zoom-banner", "flat"])
        gtk_widget_set_tooltip_text(zoomPill, "Restore Layout (\(ShortcutLabels.label(forCommand: "panel.focus-mode.toggle") ?? ""))")
        gtk_widget_set_valign(zoomPill, GTK_ALIGN_CENTER)
        Gtk.setVisible(zoomPill, false)
        adw_header_bar_pack_end(cast(header), zoomPill)
        agentButtons = Gtk.hbox(spacing: 2, classes: ["agent-buttons"])
        gtk_widget_set_valign(agentButtons, GTK_ALIGN_CENTER)
        adw_header_bar_pack_end(cast(header), agentButtons)
        adw_toolbar_view_add_top_bar(cast(toolbar), header)

        tabBar = widget(adw_tab_bar_new()!)
        adw_tab_bar_set_autohide(cast(tabBar), preferences.tabBarAutohide.gboolean)
        adw_tab_bar_set_expand_tabs(cast(tabBar), 0)
        adw_toolbar_view_add_top_bar(cast(toolbar), tabBar)

        mainStack = gtk_stack_new()
        gtk_stack_add_named(cast(mainStack), content.stack, "workspaces")
        gtk_stack_add_named(cast(mainStack), Self.makeEmptyState(), "empty")
        adw_toolbar_view_set_content(cast(toolbar), mainStack)

        let rightPanelResize = SplitViewResizeHandle(sidebar: rightPanel.root, edge: GTK_ALIGN_START)
        innerSplit = adw_overlay_split_view_new()
        adw_overlay_split_view_set_sidebar_position(cast(innerSplit), GTK_PACK_END)
        adw_overlay_split_view_set_sidebar(cast(innerSplit), rightPanelResize.root)
        adw_overlay_split_view_set_content(cast(innerSplit), toolbar)
        adw_overlay_split_view_set_min_sidebar_width(cast(innerSplit), RightAuxPanelState.minWidth)
        adw_overlay_split_view_set_sidebar_width_fraction(cast(innerSplit), RightAuxPanelState.defaultWidthFraction)
        adw_overlay_split_view_set_show_sidebar(cast(innerSplit), 0)

        // Widths follow AppState (render): the sidebar uses its override or
        // the Linux default, capped at half the window.
        let sidebarResize = SplitViewResizeHandle(sidebar: sidebar.root, edge: GTK_ALIGN_END)
        outerSplit = adw_overlay_split_view_new()
        adw_overlay_split_view_set_sidebar(cast(outerSplit), sidebarResize.root)
        adw_overlay_split_view_set_content(cast(outerSplit), innerSplit)
        adw_overlay_split_view_set_min_sidebar_width(cast(outerSplit), WindowState.minSidebarWidth)
        adw_overlay_split_view_set_sidebar_width_fraction(cast(outerSplit), 0.5)

        toastOverlay = adw_toast_overlay_new()
        adw_toast_overlay_set_child(cast(toastOverlay), outerSplit)
        adw_application_window_set_content(cast(window), toastOverlay)

        addBreakpoint("max-width: 760sp", split: outerSplit)
        addBreakpoint("max-width: 860sp", split: innerSplit)

        content.onVisibleTabViewChanged = { [weak self] view in
            guard let self else { return }
            if adw_tab_bar_get_view(cast(self.tabBar)) != view {
                adw_tab_bar_set_view(cast(self.tabBar), view)
            }
        }
        content.onTabCloseRequest = { [weak self] workspaceID, tabID in
            self?.handleUI(.confirmCloseTab(workspaceID: workspaceID, tabID: tabID))
        }
        sidebar.onRenameWorkspace = { [weak self] id in self?.handleUI(.renameWorkspace(workspaceID: id)) }
        sidebar.onCloseWorkspace = { [weak self] id in self?.handleUI(.confirmCloseWorkspace(workspaceID: id)) }

        self.sidebarResize = sidebarResize
        self.rightPanelResize = rightPanelResize
        sidebarResize.onWidthChanged = { [weak self] width in self?.resizeSidebar(to: width) }
        rightPanelResize.onWidthChanged = { [weak self] width in self?.resizeRightPanel(to: width) }

        installActions()
        keyboard = KeyboardShortcutController(
            window: window,
            matcher: Self.shortcutMatcher(),
            perform: { [weak self] id in self?.perform(id) ?? false },
            onAltChanged: { [weak self] down in
                guard let self else { return }
                self.sidebar.setShowsShortcutHints(down && self.preferences.showsShortcutHintsWithAlt)
            }
        )
        connectWindowSignals()
        TerminalProfileShortcuts.shared.onCommandsChanged.append { [weak self] in
            guard let self else { return }
            self.keyboard?.matcher = Self.shortcutMatcher()
            self.rebuildAgentButtons()
            self.updateAgentButtonStates()
        }
        rebuildAgentButtons()
        render(store.state)
    }

    /// The command table's global shortcuts plus terminal-profile split
    /// shortcuts (`Ctrl+Alt[+Shift]+key`).
    static func shortcutMatcher() -> ShortcutMatcher {
        var matcher = ShortcutMatcher(bindings: LinuxCommandTable.globalBindings)
        for command in TerminalProfileShortcuts.shared.commands {
            if let accelerator = command.accelerator { matcher.add(accelerator: accelerator, commandID: command.id) }
        }
        for command in TerminalProfileShortcuts.shared.agentCommands {
            if let accelerator = command.accelerator { matcher.add(accelerator: accelerator, commandID: command.id) }
        }
        return matcher
    }

    // MARK: Rendering

    public func scheduleRender() {
        guard renderScheduled == false else { return }
        renderScheduled = true
        MainLoop.idle(priority: Int32(G_PRIORITY_HIGH_IDLE)) { [weak self] in
            guard let self else { return }
            self.renderScheduled = false
            self.render(self.store.state)
        }
    }

    public func render(_ state: AppState) {
        guard isClosing == false, let windowState = state.window(id: windowID) else { return }
        isSyncing = true
        defer { isSyncing = false }

        let isActive = gtk_window_is_active(cast(window)).bool
        sidebar.render(state)
        content.render(state, windowIsActive: isActive)
        rightPanel.render(state)

        setShowSidebar(outerSplit, windowState.sidebarVisible)
        let selection = state.workspaceSelection(in: windowID)
        setShowSidebar(innerSplit, selection?.workspace.rightAuxPanel.isVisible ?? false)
        let sidebarWidth = windowState.sidebarWidthPointsOverride ?? Self.defaultSidebarWidth
        adw_overlay_split_view_set_max_sidebar_width(cast(outerSplit), WindowState.clampedSidebarWidth(sidebarWidth))
        // The right panel takes 40% of the space until it is resized, then
        // its stored width, capped at 80% (RightAuxPanelState.effectiveWidth).
        if let panel = selection?.workspace.rightAuxPanel {
            let custom = panel.hasCustomWidth
            adw_overlay_split_view_set_sidebar_width_fraction(
                cast(innerSplit),
                custom ? RightAuxPanelState.maximumVisibleWidthFraction : RightAuxPanelState.defaultWidthFraction
            )
            adw_overlay_split_view_set_max_sidebar_width(
                cast(innerSplit),
                custom ? RightAuxPanelState.clampedWidth(panel.width) : 100_000
            )
        }

        let hasWorkspaces = windowState.workspaceIDs.isEmpty == false
        gtk_stack_set_visible_child_name(cast(mainStack), hasWorkspaces ? "workspaces" : "empty")

        if let workspace = selection?.workspace {
            let paneCount = workspace.layoutTree.allSlotInfos.count
            let subtitle = "\(workspace.selectedTabDisplayTitle) · \(paneCount == 1 ? "1 pane" : "\(paneCount) panes")"
            adw_window_title_set_title(cast(windowTitle), workspace.title)
            adw_window_title_set_subtitle(cast(windowTitle), subtitle)
            gtk_window_set_title(cast(window), "\(workspace.title) — Toastty")
            Gtk.setVisible(zoomPill, workspace.focusedPanelModeActive)
        } else {
            adw_window_title_set_title(cast(windowTitle), "Toastty")
            adw_window_title_set_subtitle(cast(windowTitle), "")
            Gtk.setVisible(zoomPill, false)
        }
        hosts.terminal.setFontSize(points: state.effectiveTerminalFontPoints(for: windowID), windowID: windowID)
        updateActionStates(state)
        updateAgentButtonStates()
    }

    private func rebuildAgentButtons() {
        for child in Gtk.children(agentButtons) { gtk_box_remove(cast(agentButtons), child) }
        agentButtonsByProfileID = [:]
        let profiles = TerminalProfileShortcuts.shared
        // Without the app-logic frontend there is nothing to launch.
        guard profiles.agentLauncher != nil else { return }
        if profiles.agentCatalog.profiles.isEmpty {
            let start = Gtk.button("Get Started…", action: "win.help.getting-started", classes: ["flat", "agent-button"])
            gtk_widget_set_tooltip_text(start, "Set up agents (opens Getting Started)")
            Gtk.setName(start, "topbar.agent.add")
            Gtk.append(agentButtons, start)
            return
        }
        guard profiles.agentCatalog.showsTopBarButtons else { return }
        for command in profiles.agentCommands {
            let button = Gtk.button(command.displayName, classes: ["flat", "agent-button"])
            let shortcut = command.accelerator.flatMap { ParsedAccelerator($0)?.label }
            gtk_widget_set_tooltip_text(button, "Run \(command.displayName)\(shortcut.map { " (\($0))" } ?? "")")
            Gtk.setName(button, "topbar.agent.\(command.profileID)")
            let commandID = command.id
            Signal.connect(button, "clicked") { [weak self] in _ = self?.perform(commandID) }
            Gtk.append(agentButtons, button)
            agentButtonsByProfileID[command.profileID] = button
        }
    }

    /// Header agent button labels (automation summary).
    var agentButtonTitles: [String] {
        Gtk.children(agentButtons).compactMap { button in
            gtk_button_get_label(cast(button)).map { String(cString: $0) }
        }
    }

    private func updateAgentButtonStates() {
        guard let launcher = TerminalProfileShortcuts.shared.agentLauncher else { return }
        for (profileID, button) in agentButtonsByProfileID {
            gtk_widget_set_sensitive(button, launcher.canLaunchAgent(profileID: profileID, windowID: windowID).gboolean)
        }
    }

    func resizeSidebar(to width: Double) {
        store.send(.setSidebarWidth(windowID: windowID, width: width, defaultWidth: Self.defaultSidebarWidth))
    }

    func resizeRightPanel(to width: Double) {
        guard let workspaceID = store.state.workspaceSelection(in: windowID)?.workspaceID else { return }
        store.send(.setRightAuxPanelWidth(workspaceID: workspaceID, width: width))
    }

    private func scheduleFrameSave() {
        MainLoop.cancel(frameSaveTimer)
        frameSaveTimer = MainLoop.timeout(milliseconds: 400) { [weak self] in
            guard let self else { return false }
            self.frameSaveTimer = 0
            var width: Int32 = 0
            var height: Int32 = 0
            gtk_window_get_default_size(cast(self.window), &width, &height)
            guard width > 0, height > 0, self.isClosing == false,
                  var frame = self.store.state.window(id: self.windowID)?.frame else { return false }
            frame.width = Double(width)
            frame.height = Double(height)
            self.store.send(.updateWindowFrame(windowID: self.windowID, frame: frame))
            return false
        }
    }

    private func setShowSidebar(_ split: WidgetPtr, _ show: Bool) {
        if adw_overlay_split_view_get_show_sidebar(cast(split)).bool != show {
            adw_overlay_split_view_set_show_sidebar(cast(split), show.gboolean)
        }
    }

    private func addBreakpoint(_ condition: String, split: WidgetPtr) {
        guard let parsed = adw_breakpoint_condition_parse(condition) else { return }
        let breakpoint = adw_breakpoint_new(parsed)!
        var value = GValue()
        g_value_init(&value, toasttyBooleanType)
        g_value_set_boolean(&value, 1)
        adw_breakpoint_add_setter(breakpoint, split.rawGPointer.assumingMemoryBound(to: GObject.self), "collapsed", &value)
        g_value_unset(&value)
        adw_application_window_add_breakpoint(cast(window), breakpoint)
    }

    private static func makeEmptyState() -> WidgetPtr {
        let page = adw_status_page_new()!
        Gtk.addClasses(page, ["toastty-empty-state"])
        adw_status_page_set_icon_name(cast(page), "utilities-terminal-symbolic")
        adw_status_page_set_title(cast(page), "No Workspaces")
        adw_status_page_set_description(
            cast(page),
            "Create a workspace to start a terminal.\n\(ShortcutLabels.label(forCommand: "workspace.create") ?? "") New Workspace · \(ShortcutLabels.label(forCommand: "command-palette.toggle") ?? "") Command Palette"
        )
        let button = Gtk.button("New Workspace", action: "win.workspace.create", classes: ["pill", "suggested-action"])
        gtk_widget_set_halign(button, GTK_ALIGN_CENTER)
        adw_status_page_set_child(cast(page), button)
        return page
    }

    // MARK: Actions

    private var actionsByID: [String: OpaquePointer] = [:]

    private func installActions() {
        for binding in LinuxCommandTable.all {
            let action = g_simple_action_new(binding.actionName, nil)!
            let id = binding.id
            Signal.connectPointer(action, "activate") { [weak self] _ in
                _ = self?.perform(id)
            }
            g_action_map_add_action(cast(window), cast(action))
            actionsByID[id] = action
            g_object_unref(UnsafeMutableRawPointer(action))
        }

        // Sidebar row actions take the workspace ID as a string target.
        let stringType = g_variant_type_new("s")
        defer { g_variant_type_free(stringType) }
        let rowActions: [(String, (UUID) -> Void)] = [
            ("sidebar.rename", { [weak self] id in self?.handleUI(.renameWorkspace(workspaceID: id)) }),
            ("sidebar.close", { [weak self] id in self?.handleUI(.confirmCloseWorkspace(workspaceID: id)) }),
            ("sidebar.new-tab", { [weak self] id in
                guard let self else { return }
                self.store.send(.selectWorkspace(windowID: self.windowID, workspaceID: id))
                self.store.send(.createWorkspaceTab(workspaceID: id, seed: nil))
            }),
            ("sidebar.move-up", { [weak self] id in self?.moveWorkspace(id, by: -1) }),
            ("sidebar.move-down", { [weak self] id in self?.moveWorkspace(id, by: 1) }),
        ]
        for (name, handler) in rowActions {
            let action = g_simple_action_new(name, stringType)!
            Signal.connectPointer(action, "activate") { parameter in
                guard let value = variantStringValue(parameter.map(OpaquePointer.init)), let id = UUID(uuidString: value) else { return }
                handler(id)
            }
            g_action_map_add_action(cast(window), cast(action))
            g_object_unref(UnsafeMutableRawPointer(action))
        }
    }

    private func moveWorkspace(_ workspaceID: UUID, by delta: Int) {
        guard let ids = store.state.window(id: windowID)?.workspaceIDs,
              let index = ids.firstIndex(of: workspaceID), ids.indices.contains(index + delta) else { return }
        store.send(.moveWorkspace(windowID: windowID, fromIndex: index, toIndex: index + delta))
    }

    private func updateActionStates(_ state: AppState) {
        let selection = state.workspaceSelection(in: windowID)
        let hasWorkspace = selection != nil
        let tabCount = selection?.workspace.tabIDs.count ?? 0
        let paneCount = selection?.workspace.layoutTree.allSlotInfos.count ?? 0
        func enable(_ id: String, _ enabled: Bool) {
            guard let action = actionsByID[id] else { return }
            if g_action_get_enabled(action).bool != enabled {
                g_simple_action_set_enabled(cast(action), enabled.gboolean)
            }
        }
        for binding in LinuxCommandTable.all {
            let id = binding.id
            switch id {
            case "workspace.close", "workspace.rename", "workspace.tab.create", "workspace.tab.rename", "workspace.tab.close",
                 "layout.split.horizontal", "layout.split.vertical", "layout.split.left", "layout.split.up",
                 "panel.close", "panel.focus-mode.toggle", "window.toggle-right-panel":
                enable(id, hasWorkspace)
            case "workspace.tab.select-previous", "workspace.tab.select-next", "workspace.tab.move-left", "workspace.tab.move-right":
                enable(id, tabCount > 1)
            case "layout.split.select-previous", "layout.split.select-next", "layout.split.equalize",
                 "layout.split.navigate-left", "layout.split.navigate-right", "layout.split.navigate-up", "layout.split.navigate-down",
                 "layout.split.resize-left", "layout.split.resize-right", "layout.split.resize-up", "layout.split.resize-down":
                enable(id, paneCount > 1)
            default:
                break
            }
        }
    }

    // MARK: Command execution

    /// Runs a command from the table in this window. Returns whether the
    /// key press (if any) was consumed.
    @discardableResult
    public func perform(_ commandID: String) -> Bool {
        if commandID.hasPrefix(PaletteModel.workspacePrefix),
           let id = UUID(uuidString: String(commandID.dropFirst(PaletteModel.workspacePrefix.count))) {
            store.send(.selectWorkspace(windowID: windowID, workspaceID: id))
            return true
        }
        if hosts.performWindowCommand(commandID, windowID: windowID, window: window) {
            return true
        }
        if let agentCommand = TerminalProfileShortcuts.shared.agentCommand(id: commandID) {
            if let launcher = TerminalProfileShortcuts.shared.agentLauncher,
               launcher.canLaunchAgent(profileID: agentCommand.profileID, windowID: windowID) {
                launcher.launchAgent(profileID: agentCommand.profileID, windowID: windowID)
            }
            return true
        }
        if let profileCommand = TerminalProfileShortcuts.shared.command(id: commandID) {
            if let action = TerminalProfileShortcuts.action(for: profileCommand, windowID: windowID, state: store.state) {
                store.send(action)
            }
            return true
        }
        if commandID == "session.later-flag.toggle" {
            toggleLaterFlag()
            return true
        }
        let route = CommandRouter.route(commandID, windowID: windowID, state: store.state)
        switch route {
        case .actions(let actions):
            // Closing a terminal with a running process asks first (macOS
            // FocusedPanelCommandController); the host owns the prompt.
            if actions.count == 1, case .closePanel(let panelID) = actions[0] {
                requestClosePanel(panelID)
                return true
            }
            for action in actions { store.send(action) }
            return true
        case .ui(let command):
            handleUI(command)
            return true
        case .app(let id):
            switch id {
            case "window.create", "app.quit":
                onAppCommand?(id, windowID)
            default:
                let result = store.commands.perform(commandID: id, windowID: windowID)
                switch result {
                case .handled: break
                case .unavailable(let message), .failed(let message): toast(message)
                }
            }
            return true
        case .none:
            // A matched shortcut with nothing to do still belongs to the app.
            return LinuxCommandTable.binding(commandID) != nil
        }
    }

    /// Closes a panel after its host's confirmation (running process,
    /// unsaved draft).
    public func requestClosePanel(_ panelID: UUID) {
        hosts.requestClose(panelID: panelID, parent: window) { [weak self] in
            self?.store.send(.closePanel(panelID: panelID))
        }
    }

    private func toggleLaterFlag() {
        guard let selection = store.state.workspaceSelection(in: windowID),
              let panelID = selection.workspace.focusedPanelID,
              let session = store.sessions.sessions(workspaceID: selection.workspaceID).first(where: { $0.panelID == panelID }) else {
            toast("No managed session in the focused panel")
            return
        }
        let flagged = store.sessions.isFlaggedForLater(sessionID: session.sessionID)
        store.sessions.setFlaggedForLater(sessionID: session.sessionID, flagged: !flagged)
        toast(flagged ? "Cleared later flag" : "Flagged for later")
    }

    public func handleUI(_ command: LinuxUICommand) {
        switch command {
        case .renameWorkspace(let workspaceID):
            guard let workspace = store.state.workspacesByID[workspaceID] else { return }
            // Like macOS, keyboard focus returns to the workspace's panel
            // whether the rename was committed or cancelled (the dialog may
            // have been opened from the sidebar's context menu).
            Dialogs.rename(
                parent: window, heading: "Rename Workspace", current: workspace.title, placeholder: "Workspace name",
                onFinish: { [weak self] in self?.content.refocus() }
            ) { [weak self] title in
                self?.store.send(.renameWorkspace(workspaceID: workspaceID, title: title))
            }
        case .renameTab(let workspaceID, let tabID):
            guard let tab = store.state.workspacesByID[workspaceID]?.tab(id: tabID) else { return }
            Dialogs.rename(
                parent: window, heading: "Rename Tab", current: tab.customTitle ?? "",
                placeholder: tab.displayTitle, allowsEmpty: true,
                onFinish: { [weak self] in self?.content.refocus() }
            ) { [weak self] title in
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                self?.store.send(.setWorkspaceTabCustomTitle(workspaceID: workspaceID, tabID: tabID, title: trimmed.isEmpty ? nil : trimmed))
            }
        case .confirmCloseWorkspace(let workspaceID):
            guard let workspace = store.state.workspacesByID[workspaceID] else { return }
            let panelCount = workspace.allPanelsByID.count
            if panelCount <= 1 {
                store.send(.closeWorkspace(workspaceID: workspaceID))
                return
            }
            Dialogs.confirm(
                parent: window,
                heading: "Close “\(workspace.title)”?",
                body: "Its \(workspace.tabIDs.count == 1 ? "tab" : "\(workspace.tabIDs.count) tabs") and \(panelCount) panels will close.",
                confirmLabel: "_Close Workspace",
                confirmIsDefault: true
            ) { [weak self] in
                self?.store.send(.closeWorkspace(workspaceID: workspaceID))
            }
        case .confirmCloseTab(let workspaceID, let tabID):
            guard let tab = store.state.workspacesByID[workspaceID]?.tab(id: tabID) else { return }
            if tab.panels.count <= 1 {
                let close: @MainActor () -> Void = { [weak self] in
                    _ = self?.store.send(.closeWorkspaceTab(workspaceID: workspaceID, tabID: tabID))
                }
                if let panelID = tab.panels.keys.first {
                    hosts.requestClose(panelID: panelID, parent: window, close: close)
                } else {
                    close()
                }
                return
            }
            Dialogs.confirm(
                parent: window,
                heading: "Close “\(tab.displayTitle)”?",
                body: "\(tab.panels.count) panels in this tab will close.",
                confirmLabel: "_Close Tab",
                confirmIsDefault: true
            ) { [weak self] in
                self?.store.send(.closeWorkspaceTab(workspaceID: workspaceID, tabID: tabID))
            }
        case .commandPalette:
            if let palette, adw_application_window_get_visible_dialog(cast(window)) == cast(palette.dialog) {
                palette.close()
                self.palette = nil
                return
            }
            let palette = CommandPaletteDialog(catalog: PaletteModel.catalog(state: store.state, windowID: windowID)
                + TerminalProfileShortcuts.shared.paletteItems
                + TerminalProfileShortcuts.shared.agentPaletteItems(windowID: windowID)) { [weak self] id in
                self?.palette = nil
                self?.perform(id)
            }
            self.palette = palette
            palette.present(over: window)
        case .preferences:
            PreferencesDialog(preferences: preferences, store: store) { [weak self] id in
                self?.perform(id)
            }.present(over: window)
        case .shortcuts:
            adw_dialog_present(cast(ShortcutsDialog.make()), window)
        case .about:
            AboutDialog.present(over: window)
        case .toggleFullscreen:
            if gtk_window_is_fullscreen(cast(window)).bool {
                gtk_window_unfullscreen(cast(window))
            } else {
                gtk_window_fullscreen(cast(window))
            }
        case .quit:
            onAppCommand?("app.quit", windowID)
        case .panel(let commandID, let panelID):
            if hosts.perform(commandID: commandID, panelID: panelID) == false {
                toast("\(LinuxCommandTable.title(commandID)) is not available in this panel")
            }
        }
    }

    public func toast(_ message: String) {
        let toast = adw_toast_new(message)!
        adw_toast_set_timeout(toast, 3)
        adw_toast_overlay_add_toast(cast(toastOverlay), toast)
    }

    // MARK: Window lifecycle

    private func connectWindowSignals() {
        // Window size (Wayland gives clients no position): GTK keeps the
        // unmaximized size in default-width/-height; store it once resizing
        // settles so layout persistence restores it.
        for property in ["default-width", "default-height"] {
            Signal.notify(window, property) { [weak self] in self?.scheduleFrameSave() }
        }
        Signal.connectBool(window, "close-request") { [weak self] in
            guard let self else { return false }
            if self.isClosing { return false }
            self.onAppCommand?("window.close", self.windowID)
            return true
        }
        Signal.notify(window, "is-active") { [weak self] in
            guard let self else { return }
            if gtk_window_is_active(cast(self.window)).bool {
                if self.store.state.selectedWindowID != self.windowID {
                    self.store.send(.selectWindow(windowID: self.windowID))
                }
                self.content.refocus()
            } else {
                self.keyboard?.resetModifiers()
            }
        }
        Signal.notify(outerSplit, "show-sidebar") { [weak self] in
            guard let self, self.isSyncing == false,
                  let visible = self.store.state.window(id: self.windowID)?.sidebarVisible else { return }
            if adw_overlay_split_view_get_show_sidebar(cast(self.outerSplit)).bool != visible {
                self.store.send(.toggleSidebar(windowID: self.windowID))
            }
        }
        Signal.notify(innerSplit, "show-sidebar") { [weak self] in
            guard let self, self.isSyncing == false,
                  let selection = self.store.state.workspaceSelection(in: self.windowID) else { return }
            let shown = adw_overlay_split_view_get_show_sidebar(cast(self.innerSplit)).bool
            if shown != selection.workspace.rightAuxPanel.isVisible {
                self.store.send(.setRightAuxPanelVisibility(workspaceID: selection.workspaceID, isVisible: shown))
            }
        }
    }

    public func present() {
        gtk_window_present(cast(window))
    }

    /// Destroys the GTK window without asking (state already dropped it).
    public func destroy() {
        isClosing = true
        sidebar.teardown()
        gtk_window_destroy(cast(window))
    }

    // MARK: Automation helpers

    public func activateAction(_ name: String, parameter: OpaquePointer? = nil) -> Bool {
        gtk_widget_activate_action_variant(window, name.hasPrefix("win.") ? name : "win.\(name)", parameter).bool
    }

    public var visibleDialog: OpaquePointer? {
        adw_application_window_get_visible_dialog(cast(window)).map { OpaquePointer($0) }
    }
}

import CGtkShim
private var toasttyBooleanType: GType { toastty_g_type_boolean() }
