import CoreState
import XCTest

final class AppStateSelectionTests: XCTestCase {
    func testWorkspaceSelectionInWindowRespectsWindowSelectionAndFallback() throws {
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        let secondWorkspace = WorkspaceState.bootstrap(title: "Two")
        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [firstWorkspace.id, secondWorkspace.id],
                    selectedWorkspaceID: nil
                ),
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: windowID,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )

        let selection = try XCTUnwrap(state.workspaceSelection(in: windowID))

        XCTAssertEqual(selection.windowID, windowID)
        XCTAssertEqual(selection.workspaceID, firstWorkspace.id)
        XCTAssertEqual(selection.workspace.id, firstWorkspace.id)
    }

    func testWorkspaceSelectionContainingWorkspaceIDIgnoresGlobalSelectedWindow() throws {
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        let secondWorkspace = WorkspaceState.bootstrap(title: "Two")
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: firstWindowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [firstWorkspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                ),
                WindowState(
                    id: secondWindowID,
                    frame: CGRectCodable(x: 40, y: 40, width: 900, height: 700),
                    workspaceIDs: [secondWorkspace.id],
                    selectedWorkspaceID: secondWorkspace.id
                ),
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: firstWindowID,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )

        let selection = try XCTUnwrap(state.workspaceSelection(containingWorkspaceID: secondWorkspace.id))

        XCTAssertEqual(selection.windowID, secondWindowID)
        XCTAssertEqual(selection.workspaceID, secondWorkspace.id)
    }

    func testSelectedWorkspaceSelectionUsesSelectedWindowID() throws {
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        let secondWorkspace = WorkspaceState.bootstrap(title: "Two")
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: firstWindowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [firstWorkspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                ),
                WindowState(
                    id: secondWindowID,
                    frame: CGRectCodable(x: 40, y: 40, width: 900, height: 700),
                    workspaceIDs: [secondWorkspace.id],
                    selectedWorkspaceID: secondWorkspace.id
                ),
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: secondWindowID,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )

        let selection = try XCTUnwrap(state.selectedWorkspaceSelection())

        XCTAssertEqual(selection.windowID, secondWindowID)
        XCTAssertEqual(selection.workspaceID, secondWorkspace.id)
    }

    func testSoleWorkspaceSelectionReturnsNilWhenMultipleWindowsExist() {
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        let secondWorkspace = WorkspaceState.bootstrap(title: "Two")
        let state = AppState(
            windows: [
                WindowState(
                    id: UUID(),
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [firstWorkspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                ),
                WindowState(
                    id: UUID(),
                    frame: CGRectCodable(x: 40, y: 40, width: 900, height: 700),
                    workspaceIDs: [secondWorkspace.id],
                    selectedWorkspaceID: secondWorkspace.id
                ),
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: nil,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )

        XCTAssertNil(state.soleWorkspaceSelection())
    }

    func testSoleWorkspaceSelectionReturnsNilWhenNoWindowsExist() {
        let workspace = WorkspaceState.bootstrap(title: "One")
        let state = AppState(
            windows: [],
            workspacesByID: [workspace.id: workspace],
            selectedWindowID: nil,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )

        XCTAssertNil(state.soleWorkspaceSelection())
    }

    func testNextUnreadPanelSkipsFocusedPanelAndWrapsWithinCurrentTab() throws {
        let currentTab = makeTabFixture(
            focusedPanelIndex: 1,
            unreadPanelIndices: [0, 1]
        )
        let otherTab = makeTabFixture(
            focusedPanelIndex: 0,
            unreadPanelIndices: [0]
        )
        let workspace = makeWorkspaceFixture(
            title: "One",
            tabs: [currentTab, otherTab],
            selectedTabIndex: 0
        )
        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [workspace.id],
                    selectedWorkspaceID: workspace.id
                )
            ],
            workspacesByID: [workspace.id: workspace],
            selectedWindowID: windowID,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )

        let target = try XCTUnwrap(
            state.nextUnreadPanel(
                fromWindowID: windowID,
                workspaceID: workspace.id,
                tabID: currentTab.tab.id,
                focusedPanelID: currentTab.panelIDs[1]
            )
        )

        XCTAssertEqual(target.windowID, windowID)
        XCTAssertEqual(target.workspaceID, workspace.id)
        XCTAssertEqual(target.tabID, currentTab.tab.id)
        XCTAssertEqual(target.panelID, currentTab.panelIDs[0])
    }

    func testNextUnreadPanelOrdersOtherWorkspacesBeforeOtherWindows() throws {
        let currentTab = makeTabFixture(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let currentWorkspace = makeWorkspaceFixture(
            title: "One",
            tabs: [currentTab],
            selectedTabIndex: 0
        )
        let siblingWorkspaceTab = makeTabFixture(
            focusedPanelIndex: 0,
            unreadPanelIndices: [0]
        )
        let siblingWorkspace = makeWorkspaceFixture(
            title: "Two",
            tabs: [siblingWorkspaceTab],
            selectedTabIndex: 0
        )
        let otherWindowTab = makeTabFixture(
            focusedPanelIndex: 0,
            unreadPanelIndices: [0]
        )
        let otherWindowWorkspace = makeWorkspaceFixture(
            title: "Three",
            tabs: [otherWindowTab],
            selectedTabIndex: 0
        )
        let currentWindowID = UUID()
        let otherWindowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: currentWindowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [currentWorkspace.id, siblingWorkspace.id],
                    selectedWorkspaceID: currentWorkspace.id
                ),
                WindowState(
                    id: otherWindowID,
                    frame: CGRectCodable(x: 40, y: 40, width: 900, height: 700),
                    workspaceIDs: [otherWindowWorkspace.id],
                    selectedWorkspaceID: otherWindowWorkspace.id
                ),
            ],
            workspacesByID: [
                currentWorkspace.id: currentWorkspace,
                siblingWorkspace.id: siblingWorkspace,
                otherWindowWorkspace.id: otherWindowWorkspace,
            ],
            selectedWindowID: currentWindowID,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )

        let target = try XCTUnwrap(
            state.nextUnreadPanel(
                fromWindowID: currentWindowID,
                workspaceID: currentWorkspace.id,
                tabID: currentTab.tab.id,
                focusedPanelID: currentTab.panelIDs[0]
            )
        )

        XCTAssertEqual(target.windowID, currentWindowID)
        XCTAssertEqual(target.workspaceID, siblingWorkspace.id)
        XCTAssertEqual(target.tabID, siblingWorkspaceTab.tab.id)
        XCTAssertEqual(target.panelID, siblingWorkspaceTab.panelIDs[0])
    }

    func testNextUnreadPanelReturnsNilWhenFocusedPanelIsOnlyUnreadTarget() {
        let currentTab = makeTabFixture(
            focusedPanelIndex: 0,
            unreadPanelIndices: [0]
        )
        let workspace = makeWorkspaceFixture(
            title: "One",
            tabs: [currentTab],
            selectedTabIndex: 0
        )
        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [workspace.id],
                    selectedWorkspaceID: workspace.id
                )
            ],
            workspacesByID: [workspace.id: workspace],
            selectedWindowID: windowID,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )

        XCTAssertNil(
            state.nextUnreadPanel(
                fromWindowID: windowID,
                workspaceID: workspace.id,
                tabID: currentTab.tab.id,
                focusedPanelID: currentTab.panelIDs[0]
            )
        )
    }
}

private struct TabFixture {
    let tab: WorkspaceTabState
    let panelIDs: [UUID]
}

private func makeTabFixture(
    focusedPanelIndex: Int,
    unreadPanelIndices: Set<Int>,
    panelCount: Int = 3
) -> TabFixture {
    let panelIDs = (0 ..< panelCount).map { _ in UUID() }
    let panels = Dictionary(uniqueKeysWithValues: panelIDs.enumerated().map { index, panelID in
        (
            panelID,
            PanelState.terminal(
                TerminalPanelState(
                    title: "Terminal \(index + 1)",
                    shell: "zsh",
                    cwd: NSHomeDirectory()
                )
            )
        )
    })

    let tab = WorkspaceTabState(
        id: UUID(),
        layoutTree: makeLinearLayout(panelIDs: panelIDs),
        panels: panels,
        focusedPanelID: panelIDs[focusedPanelIndex],
        unreadPanelIDs: Set(unreadPanelIndices.map { panelIDs[$0] })
    )

    return TabFixture(tab: tab, panelIDs: panelIDs)
}

private func makeWorkspaceFixture(
    title: String,
    tabs: [TabFixture],
    selectedTabIndex: Int
) -> WorkspaceState {
    let tabIDs = tabs.map(\.tab.id)
    return WorkspaceState(
        id: UUID(),
        title: title,
        selectedTabID: tabIDs[selectedTabIndex],
        tabIDs: tabIDs,
        tabsByID: Dictionary(uniqueKeysWithValues: tabs.map { ($0.tab.id, $0.tab) })
    )
}

private func makeLinearLayout(panelIDs: [UUID]) -> LayoutNode {
    precondition(panelIDs.isEmpty == false)

    var iterator = panelIDs.makeIterator()
    let firstPanelID = iterator.next()!
    var layout = LayoutNode.slot(slotID: UUID(), panelID: firstPanelID)

    while let panelID = iterator.next() {
        layout = .split(
            nodeID: UUID(),
            orientation: .horizontal,
            ratio: 0.5,
            first: layout,
            second: .slot(slotID: UUID(), panelID: panelID)
        )
    }

    return layout
}
