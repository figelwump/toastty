@testable import ToasttyApp
import CoreState
import SwiftUI
import XCTest

final class ToasttyCommandMenusTests: XCTestCase {
    func testTerminalProfileMenuModelUsesProfilesAsTopLevelSections() {
        let catalog = TerminalProfileCatalog(
            profiles: [
                TerminalProfile(
                    id: "zmx",
                    displayName: "ZMX",
                    badgeLabel: "ZMX",
                    startupCommand: "zmx attach"
                ),
                TerminalProfile(
                    id: "ssh-prod",
                    displayName: "SSH Prod",
                    badgeLabel: "PROD",
                    startupCommand: "ssh prod"
                ),
            ]
        )

        let model = TerminalProfileMenuModel(
            catalog: catalog,
            registry: makeProfileShortcutRegistry(terminalProfiles: catalog)
        )

        XCTAssertEqual(model.sections.map(\.title), ["ZMX", "SSH Prod"])
        XCTAssertEqual(model.sections.map(\.profileID), ["zmx", "ssh-prod"])
        XCTAssertEqual(
            model.sections.map { $0.actions.map(\.title) },
            [
                ["Split Right", "Split Down"],
                ["Split Right", "Split Down"],
            ]
        )
        XCTAssertEqual(
            model.sections.map { $0.actions.map(\.direction) },
            [
                [.right, .down],
                [.right, .down],
            ]
        )
    }

    func testTerminalProfileMenuModelMapsShortcutsToEachSplitDirection() throws {
        let catalog = TerminalProfileCatalog(
            profiles: [
                TerminalProfile(
                    id: "zmx",
                    displayName: "ZMX",
                    badgeLabel: "ZMX",
                    startupCommand: "zmx attach",
                    shortcutKey: "z"
                ),
            ]
        )

        let model = TerminalProfileMenuModel(
            catalog: catalog,
            registry: makeProfileShortcutRegistry(terminalProfiles: catalog)
        )
        let actions = try XCTUnwrap(model.sections.first?.actions)

        XCTAssertEqual(actions.first?.shortcut, ShortcutChord(key: "z", modifiers: [.command, .control]))
        XCTAssertEqual(actions.last?.shortcut, ShortcutChord(key: "z", modifiers: [.command, .control, .shift]))
    }

    func testTerminalProfileMenuModelOmitsConflictedShortcutFromRegistry() throws {
        let terminalCatalog = TerminalProfileCatalog(
            profiles: [
                TerminalProfile(
                    id: "zmx",
                    displayName: "ZMX",
                    badgeLabel: "ZMX",
                    startupCommand: "zmx attach",
                    shortcutKey: "z"
                ),
            ]
        )
        let registry = makeProfileShortcutRegistry(
            terminalProfiles: terminalCatalog,
            agentProfiles: AgentCatalog(
                profiles: [
                    AgentProfile(
                        id: "codex",
                        displayName: "Codex",
                        argv: ["codex"],
                        shortcutKey: "z"
                    ),
                ]
            )
        )

        let model = TerminalProfileMenuModel(
            catalog: terminalCatalog,
            registry: registry
        )
        let actions = try XCTUnwrap(model.sections.first?.actions)

        XCTAssertNil(actions.first?.shortcut)
        XCTAssertEqual(actions.last?.shortcut, ShortcutChord(key: "z", modifiers: [.command, .control, .shift]))
    }

    @MainActor
    func testCanFocusNextUnreadOrActivePanelUsesResolvedCommandSelection() throws {
        let currentTab = makeUnreadMenuTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let unreadTab = makeUnreadMenuTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: [0]
        )
        let workspace = makeUnreadMenuWorkspace(
            title: "One",
            tabs: [currentTab, unreadTab],
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
                ),
            ],
            workspacesByID: [workspace.id: workspace],
            selectedWindowID: windowID
        )

        let selection = WindowCommandSelection(
            windowID: windowID,
            window: try XCTUnwrap(state.window(id: windowID)),
            workspace: try XCTUnwrap(state.workspacesByID[workspace.id])
        )

        XCTAssertTrue(
            ToasttyCommandMenus.canFocusNextUnreadOrActivePanel(
                state: state,
                commandSelection: selection,
                activePanelIDs: []
            )
        )
    }

    @MainActor
    func testCanFocusNextUnreadOrActivePanelFallsBackToActivePanelIDs() throws {
        let currentTab = makeUnreadMenuTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let activeTab = makeUnreadMenuTab(
            focusedPanelIndex: 0,
            unreadPanelIndices: []
        )
        let workspace = makeUnreadMenuWorkspace(
            title: "One",
            tabs: [currentTab, activeTab],
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
                ),
            ],
            workspacesByID: [workspace.id: workspace],
            selectedWindowID: windowID
        )

        let selection = WindowCommandSelection(
            windowID: windowID,
            window: try XCTUnwrap(state.window(id: windowID)),
            workspace: try XCTUnwrap(state.workspacesByID[workspace.id])
        )

        XCTAssertTrue(
            ToasttyCommandMenus.canFocusNextUnreadOrActivePanel(
                state: state,
                commandSelection: selection,
                activePanelIDs: [activeTab.panelIDs[1]]
            )
        )
    }

    @MainActor
    func testResolvedCommandWindowIDPrefersAppKitKeyWindowOverStaleFocusedSceneWindow() throws {
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
            selectedWindowID: firstWindowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        let resolvedWindowID = ToasttyCommandMenus.resolvedCommandWindowID(
            focusedWindowID: firstWindowID,
            keyWindowID: secondWindowID
        )

        XCTAssertEqual(resolvedWindowID, secondWindowID)
        XCTAssertTrue(store.createWorkspaceFromCommand(preferredWindowID: resolvedWindowID))

        let updatedFirstWindow = try XCTUnwrap(store.state.window(id: firstWindowID))
        let updatedSecondWindow = try XCTUnwrap(store.state.window(id: secondWindowID))
        XCTAssertEqual(updatedFirstWindow.workspaceIDs, [firstWorkspace.id])
        XCTAssertEqual(updatedSecondWindow.workspaceIDs.count, 2)
        XCTAssertEqual(updatedSecondWindow.workspaceIDs.first, secondWorkspace.id)
        XCTAssertEqual(updatedSecondWindow.selectedWorkspaceID, updatedSecondWindow.workspaceIDs.last)
    }

    func testResolvedCommandWindowIDFallsBackToFocusedSceneWindowWithoutAppKitKeyWindow() {
        let focusedWindowID = UUID()

        XCTAssertEqual(
            ToasttyCommandMenus.resolvedCommandWindowID(
                focusedWindowID: focusedWindowID,
                keyWindowID: nil
            ),
            focusedWindowID
        )
        XCTAssertNil(
            ToasttyCommandMenus.resolvedCommandWindowID(
                focusedWindowID: nil,
                keyWindowID: nil
            )
        )
    }

    func testFindCommandsYieldToUnrelatedTextInput() {
        XCTAssertTrue(
            ToasttyCommandMenus.textInputOwnsFindCommands(
                modalWindowPresent: false,
                firstResponderIsTextInput: true,
                terminalSearchFieldIsFocused: false
            )
        )
    }

    func testFindCommandsStayAvailableWhileTerminalSearchFieldOwnsFocus() {
        XCTAssertFalse(
            ToasttyCommandMenus.textInputOwnsFindCommands(
                modalWindowPresent: false,
                firstResponderIsTextInput: true,
                terminalSearchFieldIsFocused: true
            )
        )
    }

    func testFindCommandsYieldToModalContexts() {
        XCTAssertTrue(
            ToasttyCommandMenus.textInputOwnsFindCommands(
                modalWindowPresent: true,
                firstResponderIsTextInput: false,
                terminalSearchFieldIsFocused: true
            )
        )
    }
}

private func makeProfileShortcutRegistry(
    terminalProfiles: TerminalProfileCatalog,
    agentProfiles: AgentCatalog = .empty
) -> ProfileShortcutRegistry {
    ProfileShortcutRegistry(
        terminalProfiles: terminalProfiles,
        terminalProfilesFilePath: "/tmp/terminal-profiles.toml",
        agentProfiles: agentProfiles,
        agentProfilesFilePath: "/tmp/agents.toml"
    )
}

private struct UnreadMenuTabFixture {
    let panelIDs: [UUID]
    let tab: WorkspaceTabState
}

private func makeUnreadMenuTab(
    focusedPanelIndex: Int,
    unreadPanelIndices: Set<Int>,
    panelCount: Int = 2
) -> UnreadMenuTabFixture {
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
        layoutTree: makeUnreadMenuLayout(panelIDs: panelIDs),
        panels: panels,
        focusedPanelID: panelIDs[focusedPanelIndex],
        unreadPanelIDs: Set(unreadPanelIndices.map { panelIDs[$0] })
    )

    return UnreadMenuTabFixture(panelIDs: panelIDs, tab: tab)
}

private func makeUnreadMenuWorkspace(
    title: String,
    tabs: [UnreadMenuTabFixture],
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

private func makeUnreadMenuLayout(panelIDs: [UUID]) -> LayoutNode {
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
