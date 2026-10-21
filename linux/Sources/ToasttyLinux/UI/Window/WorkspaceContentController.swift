import CGtk
import CoreState
import Foundation

/// The main content of one window: a `GtkStack` with one `AdwTabView` per
/// workspace (so every workspace's terminals stay alive while hidden), each
/// tab page holding that tab's split layout.
@MainActor
public final class WorkspaceContentController {
    @MainActor private final class WorkspaceEntry {
        let tabs = TabViewSync()
        var renderers: [UUID: SplitLayoutRenderer] = [:]
    }

    public let stack: WidgetPtr
    private let windowID: UUID
    private let store: any LinuxStoreBinding
    private let hosts: PanelHostRegistry
    private var entries: [UUID: WorkspaceEntry] = [:]
    private var frames: [UUID: PanelFrame] = [:]
    private var lastFocusRequest: (workspaceID: UUID, tabID: UUID, panelID: UUID)?

    /// The tab view of the visible workspace changed (the header's
    /// `AdwTabBar` follows it).
    public var onVisibleTabViewChanged: ((OpaquePointer?) -> Void)?
    public var onTabCloseRequest: ((_ workspaceID: UUID, _ tabID: UUID) -> Void)?

    public init(windowID: UUID, store: any LinuxStoreBinding, hosts: PanelHostRegistry) {
        self.windowID = windowID
        self.store = store
        self.hosts = hosts
        stack = gtk_stack_new()
        Gtk.addClasses(stack, ["workspace-content"])
        Gtk.expand(stack)
        gtk_stack_set_transition_type(cast(stack), GTK_STACK_TRANSITION_TYPE_CROSSFADE)
        gtk_stack_set_transition_duration(cast(stack), 120)
    }

    public var visibleTabView: OpaquePointer? {
        guard let workspaceID = store.state.selectedWorkspaceID(in: windowID) else { return nil }
        return entries[workspaceID]?.tabs.view
    }

    public func renderer(workspaceID: UUID, tabID: UUID) -> SplitLayoutRenderer? {
        entries[workspaceID]?.renderers[tabID]
    }

    public func frame(for panelID: UUID) -> PanelFrame? { frames[panelID] }

    public func render(_ state: AppState, windowIsActive: Bool) {
        guard let window = state.window(id: windowID) else { return }
        var livePanels = Set<UUID>()

        for workspaceID in window.workspaceIDs {
            guard let workspace = state.workspacesByID[workspaceID] else { continue }
            let entry = entries[workspaceID] ?? makeEntry(workspaceID: workspaceID)

            var items: [TabItem] = []
            for tab in workspace.orderedTabs {
                let renderer = entry.renderers[tab.id] ?? makeRenderer(workspaceID: workspaceID, tabID: tab.id, entry: entry)
                let plan = SplitLayoutPlan.make(workspaceID: workspaceID, tab: tab)
                renderer.render(plan) { panelID in
                    frameWidget(panelID: panelID, workspaceID: workspaceID, tab: tab)
                }
                for panelID in tab.layoutTree.allSlotInfos.map(\.panelID) {
                    guard let panel = tab.panels[panelID] else { continue }
                    livePanels.insert(panelID)
                    let frame = frames[panelID]
                    frame?.update(PanelFramePresentation.make(panelID: panelID, panel: panel, tab: tab, plan: plan))
                    hosts.update(panelID: panelID, panel: panel)
                }
                items.append(TabItem(
                    id: tab.id,
                    title: tab.displayTitle,
                    needsAttention: tab.unreadPanelIDs.isEmpty == false && tab.id != workspace.resolvedSelectedTabID,
                    child: renderer.root
                ))
            }
            let liveTabs = Set(workspace.tabIDs)
            entry.renderers = entry.renderers.filter { liveTabs.contains($0.key) }
            entry.tabs.sync(items, selectedID: workspace.resolvedSelectedTabID)
        }

        let liveWorkspaces = Set(window.workspaceIDs)
        for (workspaceID, entry) in entries where liveWorkspaces.contains(workspaceID) == false {
            Gtk.detachFromParent(entry.tabs.widget)
            entries.removeValue(forKey: workspaceID)
        }
        for panelID in frames.keys where livePanels.contains(panelID) == false {
            if let frame = frames.removeValue(forKey: panelID) {
                Gtk.detachFromParent(frame.root)
            }
        }

        if let selectedWorkspaceID = window.selectedWorkspaceID, entries[selectedWorkspaceID] != nil {
            let name = selectedWorkspaceID.uuidString
            if let visible = gtk_stack_get_visible_child_name(cast(stack)), String(cString: visible) == name {
                // already visible
            } else {
                gtk_stack_set_visible_child_name(cast(stack), name)
            }
        }
        onVisibleTabViewChanged?(visibleTabView)

        // Keyboard focus follows the state's focused panel.
        if let selection = state.workspaceSelection(in: windowID),
           let tab = selection.workspace.selectedTab,
           let panelID = tab.resolvedFocusedPanelID,
           tab.rightAuxPanel.focusedPanelID == nil {
            let request = (selection.workspaceID, tab.id, panelID)
            if lastFocusRequest.map({ $0 != request }) ?? true {
                lastFocusRequest = request
                if windowIsActive {
                    hosts.focus(panelID: panelID)
                }
            }
        }
    }

    /// Re-applies keyboard focus (window became active).
    public func refocus() {
        guard let request = lastFocusRequest else { return }
        hosts.focus(panelID: request.panelID)
    }

    private func makeEntry(workspaceID: UUID) -> WorkspaceEntry {
        let entry = WorkspaceEntry()
        entries[workspaceID] = entry
        gtk_stack_add_named(cast(stack), entry.tabs.widget, workspaceID.uuidString)
        entry.tabs.onSelect = { [weak self] tabID in
            self?.store.send(.selectWorkspaceTab(workspaceID: workspaceID, tabID: tabID))
        }
        entry.tabs.onCloseRequest = { [weak self] tabID in
            self?.onTabCloseRequest?(workspaceID, tabID)
        }
        entry.tabs.onReorder = { [weak self] tabID, toIndex in
            guard let self, let workspace = self.store.state.workspacesByID[workspaceID],
                  let fromIndex = workspace.tabIDs.firstIndex(of: tabID) else { return }
            if self.store.send(.moveWorkspaceTab(workspaceID: workspaceID, fromIndex: fromIndex, toIndex: toIndex)) == false {
                // Reducer rejected the move: snap the strip back to state.
                self.render(self.store.state, windowIsActive: true)
            }
        }
        return entry
    }

    private func makeRenderer(workspaceID: UUID, tabID: UUID, entry: WorkspaceEntry) -> SplitLayoutRenderer {
        let renderer = SplitLayoutRenderer()
        renderer.onRatioChanged = { [weak self] nodeID, ratio in
            self?.store.send(.setLayoutSplitRatio(workspaceID: workspaceID, nodeID: nodeID, ratio: ratio))
        }
        entry.renderers[tabID] = renderer
        return renderer
    }

    private func frameWidget(panelID: UUID, workspaceID: UUID, tab: WorkspaceTabState) -> WidgetPtr {
        if let frame = frames[panelID] { return frame.root }
        let panel = tab.panels[panelID] ?? .terminal(TerminalPanelState(title: "Terminal", shell: "", cwd: ""))
        let content = hosts.contentWidget(for: panelID, panel: panel, workspaceID: workspaceID, windowID: windowID)
        let frame = PanelFrame(panelID: panelID, content: content)
        frame.onActivate = { [weak self] in
            guard let self,
                  let workspaceID = self.store.state.workspaceSelection(containingPanelID: panelID)?.workspaceID else { return }
            self.store.send(.focusPanel(workspaceID: workspaceID, panelID: panelID))
        }
        frame.onClose = { [weak self] in
            guard let self else { return }
            self.hosts.requestClose(panelID: panelID, parent: frame.root) { [weak self] in
                self?.store.send(.closePanel(panelID: panelID))
            }
        }
        frame.onToggleZoom = { [weak self] in
            guard let self,
                  let workspaceID = self.store.state.workspaceSelection(containingPanelID: panelID)?.workspaceID else { return }
            self.store.send(.focusPanel(workspaceID: workspaceID, panelID: panelID))
            self.store.send(.toggleFocusedPanelMode(workspaceID: workspaceID))
        }
        frames[panelID] = frame
        return frame.root
    }
}
