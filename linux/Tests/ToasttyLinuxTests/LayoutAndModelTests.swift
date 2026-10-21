import CoreState
import Foundation
import Testing
@testable import ToasttyLinuxUI

/// Reducer-driven fixtures: every layout is produced by real `AppAction`s.
@MainActor
struct Fixture {
    let store = ReducerStoreBinding()
    var windowID: UUID { store.state.windows[0].id }
    var workspaceID: UUID { store.state.windows[0].selectedWorkspaceID! }
    var tab: WorkspaceTabState { store.state.workspacesByID[workspaceID]!.selectedTab! }

    func perform(_ commandID: String) {
        if case .actions(let actions) = CommandRouter.route(commandID, windowID: windowID, state: store.state) {
            for action in actions { store.send(action) }
        }
    }

    var plan: SplitLayoutPlan { SplitLayoutPlan.make(workspaceID: workspaceID, tab: tab) }
}

@Suite("Split tree to widget layout")
@MainActor
struct SplitLayoutPlanTests {
    @Test func singlePanel() {
        let fixture = Fixture()
        guard case .panel(let panelID, _) = fixture.plan.root else {
            Issue.record("expected a single panel")
            return
        }
        #expect(panelID == fixture.tab.resolvedFocusedPanelID)
        #expect(fixture.plan.isZoomed == false)
        #expect(fixture.plan.root.depth == 0)
    }

    @Test func splitRightIsSideBySidePaned() {
        let fixture = Fixture()
        let first = fixture.tab.resolvedFocusedPanelID!
        fixture.perform("layout.split.horizontal")
        guard case .split(_, let axis, let ratio, let lhs, let rhs) = fixture.plan.root else {
            Issue.record("expected a split")
            return
        }
        #expect(axis == .sideBySide)
        #expect(abs(ratio - 0.5) < 0.0001)
        #expect(lhs.panelIDs == [first])
        #expect(rhs.panelIDs.count == 1)
        #expect(fixture.plan.focusedPanelID == rhs.panelIDs.first)
    }

    @Test func nestedSplitsMirrorTree() {
        let fixture = Fixture()
        fixture.perform("layout.split.horizontal")
        fixture.perform("layout.split.vertical")
        let plan = fixture.plan
        #expect(plan.root.panelIDs.count == 3)
        #expect(plan.root.depth == 2)
        guard case .split(_, .sideBySide, _, .panel, .split(_, let innerAxis, _, _, _)) = plan.root else {
            Issue.record("expected right column split down: \(plan.root)")
            return
        }
        #expect(innerAxis == .stacked)
        #expect(plan.root.panelIDs == fixture.tab.layoutTree.allSlotInfos.map(\.panelID))
    }

    @Test func ratioChangeKeepsShape() {
        let fixture = Fixture()
        fixture.perform("layout.split.horizontal")
        let before = fixture.plan
        guard case .split(let nodeID, _, _, _, _) = before.root else { return }
        fixture.store.send(.setLayoutSplitRatio(workspaceID: fixture.workspaceID, nodeID: nodeID, ratio: 0.3))
        let after = fixture.plan
        #expect(after.root.shape == before.root.shape, "a ratio change must not force a widget rebuild")
        #expect(abs((after.root.ratios[nodeID] ?? 0) - 0.3) < 0.0001)
        fixture.perform("layout.split.equalize")
        #expect(abs((fixture.plan.root.ratios[nodeID] ?? 0) - 0.5) < 0.0001)
    }

    @Test func zoomRendersOnlyFocusedPanel() {
        let fixture = Fixture()
        fixture.perform("layout.split.horizontal")
        fixture.perform("layout.split.vertical")
        let focused = fixture.tab.resolvedFocusedPanelID!
        fixture.perform("panel.focus-mode.toggle")
        let zoomed = fixture.plan
        #expect(zoomed.isZoomed)
        #expect(zoomed.root.panelIDs == [focused])
        #expect(zoomed.hiddenPanelIDs.count == 2)
        fixture.perform("panel.focus-mode.toggle")
        #expect(fixture.plan.isZoomed == false)
        #expect(fixture.plan.root.panelIDs.count == 3)
    }

    @Test func closingPanelCollapsesSplit() {
        let fixture = Fixture()
        fixture.perform("layout.split.horizontal")
        fixture.perform("panel.close")
        guard case .panel = fixture.plan.root else {
            Issue.record("expected the split to collapse")
            return
        }
    }

    @Test func ratioPositionRoundTrip() {
        #expect(SplitLayoutPlan.position(forRatio: 0.5, maxPosition: 1000) == 500)
        #expect(SplitLayoutPlan.position(forRatio: 0.0, maxPosition: 1000) == 100, "clamped to the 0.1 minimum")
        #expect(SplitLayoutPlan.position(forRatio: 0.5, maxPosition: 0) == 0)
        #expect(SplitLayoutPlan.ratio(forPosition: 250, maxPosition: 1000) == 0.25)
        #expect(SplitLayoutPlan.ratio(forPosition: 10, maxPosition: 0) == nil)
        #expect(SplitLayoutPlan.isMeaningfulDrag(from: 0.5, to: 0.5005, maxPosition: 1000) == false, "sub-pixel noise")
        #expect(SplitLayoutPlan.isMeaningfulDrag(from: 0.5, to: 0.52, maxPosition: 1000))
    }
}

@Suite("Command routing")
@MainActor
struct CommandRouterTests {
    @Test func tabSelectionWraps() {
        let fixture = Fixture()
        fixture.perform("workspace.tab.create")
        fixture.perform("workspace.tab.create")
        let workspace = fixture.store.state.workspacesByID[fixture.workspaceID]!
        #expect(workspace.tabIDs.count == 3)
        #expect(workspace.resolvedSelectedTabID == workspace.tabIDs[2])
        fixture.perform("workspace.tab.select-next")
        #expect(fixture.store.state.workspacesByID[fixture.workspaceID]!.resolvedSelectedTabID == workspace.tabIDs[0])
        fixture.perform("workspace.tab.select-2")
        #expect(fixture.store.state.workspacesByID[fixture.workspaceID]!.resolvedSelectedTabID == workspace.tabIDs[1])
        fixture.perform("workspace.tab.move-right")
        #expect(fixture.store.state.workspacesByID[fixture.workspaceID]!.tabIDs[2] == workspace.tabIDs[1])
        #expect(CommandRouter.route("workspace.tab.select-9", windowID: fixture.windowID, state: fixture.store.state) == .none)
    }

    @Test func workspaceSelectionByNumber() {
        let fixture = Fixture()
        let first = fixture.workspaceID
        fixture.perform("workspace.create")
        #expect(fixture.workspaceID != first)
        fixture.perform("workspace.select-1")
        #expect(fixture.workspaceID == first)
        fixture.perform("workspace.select-next")
        #expect(fixture.workspaceID != first)
    }

    @Test func uiCommandsNeedConfirmationOrInput() {
        let fixture = Fixture()
        let state = fixture.store.state
        #expect(CommandRouter.route("workspace.close", windowID: fixture.windowID, state: state)
            == .ui(.confirmCloseWorkspace(workspaceID: fixture.workspaceID)))
        #expect(CommandRouter.route("workspace.rename", windowID: fixture.windowID, state: state)
            == .ui(.renameWorkspace(workspaceID: fixture.workspaceID)))
        #expect(CommandRouter.route("command-palette.toggle", windowID: fixture.windowID, state: state) == .ui(.commandPalette))
        #expect(CommandRouter.route("app.remote-access.open", windowID: fixture.windowID, state: state) == .app("app.remote-access.open"))
        if case .ui(.panel(let id, let panelID)) = CommandRouter.route("find.show", windowID: fixture.windowID, state: state) {
            #expect(id == "find.show")
            #expect(panelID == fixture.tab.resolvedFocusedPanelID)
        } else {
            Issue.record("find.show should route to the focused panel")
        }
    }

    @Test func paneFocusByPositionAndDirection() {
        let fixture = Fixture()
        fixture.perform("layout.split.horizontal")
        let slots = fixture.tab.layoutTree.allSlotInfos.map(\.panelID)
        fixture.perform("layout.pane.focus-1")
        #expect(fixture.tab.resolvedFocusedPanelID == slots[0])
        fixture.perform("layout.split.navigate-right")
        #expect(fixture.tab.resolvedFocusedPanelID == slots[1])
        fixture.perform("layout.split.select-next")
        #expect(fixture.tab.resolvedFocusedPanelID == slots[0])
    }

    @Test func textSizeIsPerWindow() {
        let fixture = Fixture()
        let base = fixture.store.state.effectiveTerminalFontPoints(for: fixture.windowID)
        fixture.perform("text-size.increase")
        #expect(fixture.store.state.effectiveTerminalFontPoints(for: fixture.windowID) == base + 1)
        fixture.perform("text-size.reset")
        #expect(fixture.store.state.effectiveTerminalFontPoints(for: fixture.windowID) == base)
    }

    @Test func sidebarAndRightPanelToggles() {
        let fixture = Fixture()
        fixture.perform("window.toggle-sidebar")
        #expect(fixture.store.state.windows[0].sidebarVisible == false)
        fixture.perform("window.toggle-right-panel")
        #expect(fixture.tab.rightAuxPanel.isVisible)
    }
}

@Suite("Palette and sidebar models")
@MainActor
struct PaletteAndSidebarTests {
    @Test func paletteRanksTitleMatchesFirst() {
        let fixture = Fixture()
        let catalog = PaletteModel.catalog(state: fixture.store.state, windowID: fixture.windowID)
        #expect(catalog.contains { $0.id == "layout.split.horizontal" })
        #expect(catalog.contains { $0.id == "terminal.copy" } == false, "terminal-owned keys are not palette commands")
        #expect(catalog.contains { $0.id.hasPrefix(PaletteModel.workspacePrefix) })
        let results = PaletteModel.filter(catalog, query: "split")
        #expect(results.first?.id == "layout.split.horizontal")
        let byKeyword = PaletteModel.filter(catalog, query: "zoom")
        #expect(byKeyword.first?.id == "panel.focus-mode.toggle")
        #expect(PaletteModel.filter(catalog, query: "").count == catalog.count)
        #expect(PaletteModel.filter(catalog, query: "qqqqzz").isEmpty)
    }

    @Test func paletteTitlesFollowState() {
        let fixture = Fixture()
        let title = { (id: String) in
            PaletteModel.catalog(state: fixture.store.state, windowID: fixture.windowID).first { $0.id == id }?.title
        }
        #expect(title("window.toggle-sidebar") == "Hide Sidebar")
        fixture.perform("window.toggle-sidebar")
        #expect(title("window.toggle-sidebar") == "Show Sidebar")
        #expect(title("panel.focus-mode.toggle") == "Focus Panel")
        fixture.perform("panel.focus-mode.toggle")
        #expect(title("panel.focus-mode.toggle") == "Restore Layout")
    }

    @Test func sidebarRows() {
        let fixture = Fixture()
        fixture.perform("layout.split.horizontal")
        fixture.perform("workspace.create")
        fixture.perform("workspace.tab.create")
        let rows = SidebarModel.rows(state: fixture.store.state, windowID: fixture.windowID, sessions: EmptySessionSource())
        #expect(rows.count == 2)
        #expect(rows[0].subtitle == "2 panes")
        #expect(rows[1].subtitle == "2 tabs · 1 pane")
        #expect(rows[1].isSelected)
        #expect(rows[0].shortcutLabel == "Ctrl+Alt+1")
        #expect(rows[0].showsNewBadge == false)
    }

    @Test func sidebarSessionRows() {
        let fixture = Fixture()
        let demo = DemoSessionSource()
        demo.attach(to: fixture.store)
        fixture.perform("layout.split.horizontal")
        fixture.perform("layout.split.vertical")
        let rows = SidebarModel.rows(state: fixture.store.state, windowID: fixture.windowID, sessions: demo)
        let sessions = rows[0].sessions
        #expect(sessions.count == 3)
        #expect(sessions[0].statusKind == .working)
        #expect(sessions[1].chipLabel == "approval")
        #expect(sessions[1].attentionClass == "attention-approval")
        demo.setFlaggedForLater(sessionID: sessions[0].sessionID, flagged: true)
        let flagged = SidebarModel.rows(state: fixture.store.state, windowID: fixture.windowID, sessions: demo)
        #expect(flagged[0].sessions[0].isFlaggedForLater)
    }

    @Test func dragReorderDestination() {
        #expect(SidebarController.reorderDestination(from: 0, onto: 2, placeAfter: false) == 1)
        #expect(SidebarController.reorderDestination(from: 0, onto: 2, placeAfter: true) == 2)
        #expect(SidebarController.reorderDestination(from: 3, onto: 1, placeAfter: false) == 1)
        #expect(SidebarController.reorderDestination(from: 3, onto: 1, placeAfter: true) == 2)
    }

    @Test func storeBindingNotifiesObservers() {
        let store = ReducerStoreBinding()
        var calls = 0
        let observation = store.observe { _ in calls += 1 }
        store.send(.toggleSidebar(windowID: store.state.windows[0].id))
        #expect(calls == 1)
        store.send(.selectWindow(windowID: UUID()))
        observation.cancel()
        store.send(.toggleSidebar(windowID: store.state.windows[0].id))
        #expect(calls <= 2)
        #expect(store.actionLog.contains("toggleSidebar"))
    }
}
