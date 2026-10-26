import CGtk
import CoreState
import Foundation

/// The right panel (second `AdwOverlaySplitView`, end side): an `AdwTabView`
/// of the selected workspace tab's right-panel tabs, or an empty state.
@MainActor
public final class RightPanelController {
    public let root: WidgetPtr
    private let windowID: UUID
    private let store: any LinuxStoreBinding
    private let hosts: PanelHostRegistry
    private let tabs = TabViewSync()
    private let content: WidgetPtr
    private let tabBar: WidgetPtr
    private var workspaceID: UUID?
    private var lastFocusedPanelID: UUID?

    public init(windowID: UUID, store: any LinuxStoreBinding, hosts: PanelHostRegistry) {
        self.windowID = windowID
        self.store = store
        self.hosts = hosts

        root = adw_toolbar_view_new()
        Gtk.addClasses(root, ["right-panel"])
        let header = adw_header_bar_new()!
        adw_header_bar_set_title_widget(cast(header), adw_window_title_new("Right Panel", nil))
        let newBrowser = Gtk.iconButton(
            "tab-new-symbolic",
            tooltip: "New Browser (\(ShortcutLabels.label(forCommand: "browser.create") ?? ""))",
            action: "win.browser.create"
        )
        adw_header_bar_pack_start(cast(header), newBrowser)
        adw_toolbar_view_add_top_bar(cast(root), header)

        tabBar = widget(adw_tab_bar_new()!)
        adw_tab_bar_set_view(cast(tabBar), tabs.view)
        adw_tab_bar_set_autohide(cast(tabBar), 1)
        adw_toolbar_view_add_top_bar(cast(root), tabBar)

        content = gtk_stack_new()
        gtk_stack_add_named(cast(content), tabs.widget, "tabs")
        let empty = adw_status_page_new()!
        Gtk.addClasses(empty, ["compact"])
        adw_status_page_set_icon_name(cast(empty), "view-dual-symbolic")
        adw_status_page_set_title(cast(empty), "Nothing Open")
        adw_status_page_set_description(
            cast(empty),
            "Browsers, local documents and Scratchpads open here.\n\(ShortcutLabels.label(forCommand: "browser.create") ?? "") opens a browser."
        )
        gtk_stack_add_named(cast(content), empty, "empty")
        adw_toolbar_view_set_content(cast(root), content)

        tabs.onSelect = { [weak self] tabID in
            guard let self, let workspaceID = self.workspaceID else { return }
            self.store.send(.selectRightAuxPanelTab(workspaceID: workspaceID, tabID: tabID, focus: true))
        }
        tabs.onCloseRequest = { [weak self] tabID in
            guard let self, let workspaceID = self.workspaceID else { return }
            let close: @MainActor () -> Void = { [weak self] in
                _ = self?.store.send(.closeRightAuxPanelTab(workspaceID: workspaceID, tabID: tabID))
            }
            if let panelID = self.store.state.workspacesByID[workspaceID]?.rightAuxPanel.tabsByID[tabID]?.panelID,
               self.hosts.rightPanel.confirmClose(panelID: panelID, parent: self.root, proceed: close) {
                return
            }
            close()
        }
        hosts.rightPanel.observeTabDecorations { [weak self] panelID in
            self?.refreshDecoration(panelID: panelID)
        }
    }

    private func refreshDecoration(panelID: UUID) {
        guard let workspaceID,
              let panel = store.state.workspacesByID[workspaceID]?.rightAuxPanel,
              let tabID = panel.tabID(containingPanelID: panelID),
              let decoration = hosts.rightPanel.tabDecoration(panelID: panelID) else { return }
        tabs.applyDecoration(decoration, toTab: tabID)
    }

    public func render(_ state: AppState) {
        guard let selection = state.workspaceSelection(in: windowID) else {
            tabs.sync([], selectedID: nil)
            gtk_stack_set_visible_child_name(cast(content), "empty")
            return
        }
        workspaceID = selection.workspaceID
        let panel = selection.workspace.rightAuxPanel
        let items = panel.orderedTabs.map { tab in
            TabItem(
                id: tab.id,
                title: tab.panelState.notificationLabel,
                child: hosts.contentWidget(
                    for: tab.panelID,
                    panel: tab.panelState,
                    workspaceID: selection.workspaceID,
                    windowID: windowID,
                    inRightPanel: true
                ),
                decoration: hosts.rightPanel.tabDecoration(panelID: tab.panelID)
            )
        }
        for tab in panel.orderedTabs { hosts.update(panelID: tab.panelID, panel: tab.panelState) }
        tabs.sync(items, selectedID: panel.activeTabID)
        gtk_stack_set_visible_child_name(cast(content), items.isEmpty ? "empty" : "tabs")
        if panel.focusedPanelID != lastFocusedPanelID {
            lastFocusedPanelID = panel.focusedPanelID
            if let focused = panel.focusedPanelID { hosts.focus(panelID: focused) }
        }
    }
}
