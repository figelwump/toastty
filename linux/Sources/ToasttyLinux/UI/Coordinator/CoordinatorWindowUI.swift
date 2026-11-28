#if TOASTTY_LINUX_APP_LOGIC
import CGtk
import CGtkShim
import CoreState
import Foundation
@testable import ToasttyAppLogic

/// The coordinator in one window (docs/tasks.md "The coordinator's chat",
/// "The coordinator's dock"):
///
/// - the dock: a column between the sidebar and the workspace with the
///   chat, shown while the window holds the Coordinator workspace, the dock
///   is open and another workspace is selected; its right edge sets its
///   width;
/// - the full view: the chat over the coordinator's terminal, with Dock,
///   Terminal/Chat and … (Policy, Ledger, Friction Notes, Restart) in the
///   panel's header;
/// - Ctrl+Shift+K, Open Coordinator and Restart Coordinator.
@MainActor
final class CoordinatorWindowUI {
    let dockRoot: WidgetPtr
    private let ui: TasksUI
    private let windowID: UUID
    private weak var controller: LinuxWindowController?
    private let dock: WidgetPtr
    private let dockStatus: WidgetPtr
    private let dockStack: WidgetPtr
    private let resize: SplitViewResizeHandle
    let dockChat: CoordinatorChatView
    let panelChat: CoordinatorChatView
    private let panelAccessories: WidgetPtr
    /// The header buttons move between frames when the coordinator restarts.
    private var panelAccessoriesRef: GObjectRef!
    private let modeToggle: WidgetPtr
    private weak var decoratedFrame: PanelFrame?
    private var lastPanelID: UUID?

    init(ui: TasksUI, controller: LinuxWindowController) {
        self.ui = ui
        self.controller = controller
        windowID = controller.windowID

        // The dock.
        dock = Gtk.vbox(classes: ["coordinator-dock"])
        Gtk.setName(dock, "coordinator.dock")
        let header = Gtk.hbox(spacing: 8, classes: ["coordinator-dock-header"])
        Gtk.append(header, Gtk.image(LinuxAppController.applicationID, pixelSize: 20))
        let titles = Gtk.vbox()
        gtk_widget_set_hexpand(titles, 1)
        Gtk.append(titles, Gtk.label(AppState.coordinatorWorkspaceTitle, classes: ["coordinator-dock-title"]))
        dockStatus = Gtk.label("", classes: ["coordinator-dock-status"])
        Gtk.append(titles, dockStatus)
        Gtk.append(header, titles)
        let fullView = Gtk.iconButton("view-fullscreen-symbolic", tooltip: "Open Full View", classes: ["flat"])
        Gtk.setName(fullView, "coordinator.dock.full-view")
        Gtk.append(header, fullView)
        let hide = Gtk.iconButton("window-close-symbolic", tooltip: "Hide Dock (\(ShortcutLabels.label(forCommand: "coordinator.dock.toggle") ?? ""))", classes: ["flat"])
        Gtk.setName(hide, "coordinator.dock.hide")
        Gtk.append(header, hide)
        Gtk.append(dock, header)
        dockChat = CoordinatorChatView(ui: ui, windowID: controller.windowID, host: .dock)
        dockStack = gtk_stack_new()!
        Gtk.expand(dockStack)
        gtk_stack_add_named(cast(dockStack), dockChat.root, "chat")
        let noTerminal = Gtk.vbox(spacing: 10, classes: ["coordinator-dock-empty"])
        gtk_widget_set_valign(noTerminal, GTK_ALIGN_CENTER)
        Gtk.append(noTerminal, Gtk.label("The coordinator has no terminal.", classes: ["dim-label"], xalign: 0.5))
        let restart = Gtk.button("Restart Coordinator", classes: ["pill"])
        gtk_widget_set_halign(restart, GTK_ALIGN_CENTER)
        Gtk.setName(restart, "coordinator.dock.restart")
        Gtk.append(noTerminal, restart)
        gtk_stack_add_named(cast(dockStack), noTerminal, "empty")
        Gtk.append(dock, dockStack)
        resize = SplitViewResizeHandle(sidebar: dock, edge: GTK_ALIGN_END)
        dockRoot = resize.root
        Gtk.setVisible(dockRoot, false)

        // The full view's header buttons and chat.
        panelChat = CoordinatorChatView(ui: ui, windowID: controller.windowID, host: .panel)
        panelAccessories = Gtk.hbox(spacing: 2, classes: ["coordinator-panel-buttons"])
        panelAccessoriesRef = GObjectRef(sinking: panelAccessories)
        let dockButton = Gtk.button("Dock", classes: ["flat", "coordinator-panel-button"])
        gtk_widget_set_tooltip_text(dockButton, "Show the chat in the dock and go back to your workspace")
        Gtk.setName(dockButton, "coordinator.panel.dock")
        Gtk.append(panelAccessories, dockButton)
        modeToggle = Gtk.button("Terminal", classes: ["flat", "coordinator-panel-button"])
        Gtk.setName(modeToggle, "coordinator.panel.mode")
        Gtk.append(panelAccessories, modeToggle)
        let more = gtk_menu_button_new()!
        gtk_menu_button_set_icon_name(cast(more), "view-more-symbolic")
        Gtk.addClasses(more, ["flat", "coordinator-panel-button"])
        Gtk.setName(more, "coordinator.panel.more")
        let menu = g_menu_new()!
        let documents = g_menu_new()!
        for document in CoordinatorDocument.allCases {
            g_menu_append(documents, "Open \(document.name)", "coordinator.document::\(document.fileName)")
        }
        g_menu_append_section(menu, nil, cast(documents))
        let actions = g_menu_new()!
        g_menu_append(actions, "Restart Coordinator", "win.coordinator.restart")
        g_menu_append_section(menu, nil, cast(actions))
        gtk_menu_button_set_menu_model(cast(more), cast(menu))
        for model in [documents, actions, menu] { g_object_unref(UnsafeMutableRawPointer(model)) }
        Gtk.append(panelAccessories, more)
        installDocumentAction(on: panelAccessories)

        Signal.connect(fullView, "clicked") { [weak self] in self?.coordinator?.openFullView() }
        Signal.connect(hide, "clicked") { [weak self] in self?.coordinator?.hideDock() }
        Signal.connect(restart, "clicked") { [weak self] in self?.perform(.restart) }
        Signal.connect(dockButton, "clicked") { [weak self] in _ = self?.coordinator?.showDock(focusComposer: true) }
        Signal.connect(modeToggle, "clicked") { [weak self] in
            guard let coordinator = self?.coordinator else { return }
            if coordinator.showsTerminal {
                coordinator.showsTerminal = false
                coordinator.chat?.requestComposerFocus(host: .panel)
            } else {
                coordinator.showTerminal()
            }
            self?.ui.scheduleRender()
        }
        resize.onWidthChanged = { [weak self] width in
            guard let self else { return }
            _ = self.ui.store.send(.setCoordinatorDockWidth(windowID: self.windowID, width: width))
        }
    }

    func teardown() {
        dockChat.teardown()
        panelChat.teardown()
        if let frame = decoratedFrame {
            frame.setCover(nil)
            Gtk.detachFromParent(panelAccessories)
        }
    }

    private var coordinator: CoordinatorController? { ui.tasks.coordinatorController }
    var automationController: CoordinatorController? { coordinator }

    // MARK: - Render

    func render(_ state: AppState) {
        guard let coordinator, let window = state.window(id: windowID) else {
            Gtk.setVisible(dockRoot, false)
            return
        }
        // The dock.
        let showsDock = coordinator.dockShows(in: windowID)
        Gtk.setVisible(dockRoot, showsDock)
        if showsDock {
            let windowWidth = Double(gtk_widget_get_width(controller?.window ?? dockRoot))
            let width = windowWidth > 0 ? window.coordinatorDockWidth(windowWidth: windowWidth) : window.coordinatorDockWidth
            gtk_widget_set_size_request(dock, Int32(width.rounded()), -1)
            gtk_stack_set_visible_child_name(cast(dockStack), coordinator.location?.panelID == nil ? "empty" : "chat")
            Gtk.setLabel(dockStatus, statusText(state))
            dockChat.followCoordinatorPanel()
            dockChat.scheduleRender()
        }

        // The full view: the chat over the coordinator's terminal.
        let location = coordinator.location
        let frame = (location?.windowID == windowID ? location?.panelID : nil).flatMap { controller?.content.frame(for: $0) }
        if frame !== decoratedFrame {
            if let old = decoratedFrame {
                old.setCover(nil)
                Gtk.detachFromParent(panelAccessories)
            }
            decoratedFrame = frame
            if let frame {
                Gtk.append(frame.headerAccessories, panelAccessories)
            }
        }
        if let frame {
            let showsChat = coordinator.chatIsAvailable && coordinator.showsTerminal == false
            frame.setCover(showsChat ? panelChat.root : nil)
            gtk_button_set_label(cast(modeToggle), showsChat ? "Terminal" : "Chat")
            gtk_widget_set_tooltip_text(modeToggle, showsChat ? "Show the coordinator's terminal" : "Show the chat")
            Gtk.setVisible(panelAccessories, coordinator.chatIsAvailable)
            if showsChat {
                panelChat.followCoordinatorPanel()
                panelChat.scheduleRender()
            }
        }
        if location?.panelID != lastPanelID {
            lastPanelID = location?.panelID
        }
    }

    private func statusText(_ state: AppState) -> String {
        guard let coordinator, let location = coordinator.location,
              let workspace = state.workspacesByID[location.workspaceID] else { return "Not running" }
        let mark = SidebarCoordinatorPresentation.currentMark(
            controller: coordinator,
            sessionRuntimeStore: ui.sessionRuntimeStore,
            workspace: workspace,
            readPanelID: location.panelID
        )
        return SidebarCoordinatorPresentation.statusText(mark).map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Ready"
    }

    // MARK: - Commands

    func perform(_ command: CoordinatorController.UserCommand) {
        coordinator?.perform(command, windowID: windowID)
    }

    /// Ctrl+Shift+K: shows the dock with the keyboard in its field, moves
    /// the keyboard to the chat's field, or hides the dock.
    func performDockShortcut() {
        guard let coordinator else { return }
        if coordinator.location == nil {
            controller?.toast("The coordinator is not running. Open it with Open Coordinator.")
            return
        }
        coordinator.performDockShortcut()
    }

    var dockShortcutTitle: String {
        coordinator?.dockShortcutAction.map(CoordinatorDockPresentation.shortcutTitle) ?? "Show Coordinator Dock"
    }

    /// The chat's text size, while a chat's field has the keyboard
    /// (Ctrl+=, Ctrl+-, Ctrl+0 as on macOS).
    func changeTextScale(_ change: CoordinatorChatModel.TextScaleChange) -> Bool {
        guard let chat = coordinator?.chat,
              chat.composerHasKeyboard(host: .dock) || chat.composerHasKeyboard(host: .panel) else { return false }
        chat.changeTextScale(change)
        return true
    }

    private func installDocumentAction(on widget: WidgetPtr) {
        let group = g_simple_action_group_new()!
        let stringType = g_variant_type_new("s")
        defer { g_variant_type_free(stringType) }
        let action = g_simple_action_new("document", stringType)!
        Signal.connectPointer(action, "activate") { [weak self] parameter in
            guard let self, let name = variantStringValue(parameter.map(OpaquePointer.init)),
                  let document = CoordinatorDocument.allCases.first(where: { $0.fileName == name }) else { return }
            do {
                try self.coordinator?.openDocument(document)
            } catch {
                self.controller?.toast(error.localizedDescription)
            }
        }
        g_action_map_add_action(cast(group), cast(action))
        g_object_unref(UnsafeMutableRawPointer(action))
        gtk_widget_insert_action_group(widget, "coordinator", cast(group))
        g_object_unref(UnsafeMutableRawPointer(group))
    }
}
#endif
