@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class TerminalAppControlTests: XCTestCase {
    func testTerminalStateQueryUsesLiveTitleWithoutMutatingPersistedTitle() throws {
        let fixture = try TerminalAppControlFixture()
        fixture.terminalRuntimeRegistry.terminalLiveTitleStore.setTitle(
            "Live Build",
            for: fixture.panelID
        )

        let result = try fixture.executor.runQuery(
            id: AppControlQueryID.terminalState.rawValue,
            args: ["panelID": .string(fixture.panelID.uuidString)]
        )

        XCTAssertEqual(result.string("title"), "Live Build")
        guard case .terminal(let terminalState)? = fixture.store.state
            .workspacesByID[fixture.workspaceID]?
            .panelState(for: fixture.panelID) else {
            XCTFail("expected terminal panel")
            return
        }
        XCTAssertEqual(terminalState.title, "Terminal 1")
    }

    func testWorkspaceSnapshotRightPanelTerminalUsesLiveTitle() throws {
        let rightPanelID = UUID()
        let fixture = try TerminalAppControlFixture { state, workspaceID in
            var workspace = try XCTUnwrap(state.workspacesByID[workspaceID])
            var tab = try XCTUnwrap(workspace.selectedTab)
            let rightTabID = UUID()
            let rightPanelState = PanelState.terminal(
                TerminalPanelState(title: "Terminal 2", shell: "zsh", cwd: "")
            )
            tab.rightAuxPanel = RightAuxPanelState(
                isVisible: true,
                width: 360,
                hasCustomWidth: true,
                activeTabID: rightTabID,
                tabIDs: [rightTabID],
                tabsByID: [
                    rightTabID: RightAuxPanelTabState(
                        id: rightTabID,
                        identity: .browserSession(rightPanelID),
                        panelID: rightPanelID,
                        panelState: rightPanelState
                    ),
                ],
                focusedPanelID: rightPanelID
            )
            workspace.tabsByID[tab.id] = tab
            state.workspacesByID[workspaceID] = workspace
        }
        fixture.terminalRuntimeRegistry.terminalLiveTitleStore.setTitle(
            "Live Right Panel",
            for: rightPanelID
        )

        let result = try fixture.executor.runQuery(
            id: AppControlQueryID.workspaceSnapshot.rawValue,
            args: ["workspaceID": .string(fixture.workspaceID.uuidString)]
        )

        guard case .object(let rightPanel)? = result["rightPanel"],
              case .array(let tabs)? = rightPanel["tabs"],
              case .object(let firstTab)? = tabs.first else {
            XCTFail("expected right-panel tab snapshot")
            return
        }
        XCTAssertEqual(firstTab.string("title"), "Live Right Panel")
    }
}

@MainActor
private struct TerminalAppControlFixture {
    let store: AppStore
    let executor: AppControlExecutor
    let terminalRuntimeRegistry: TerminalRuntimeRegistry
    let windowID: UUID
    let workspaceID: UUID
    let panelID: UUID

    init(
        configureState: ((inout AppState, UUID) throws -> Void)? = nil
    ) throws {
        var state = AppState.bootstrap()
        let selection = try XCTUnwrap(state.selectedWorkspaceSelection())
        windowID = selection.windowID
        workspaceID = selection.workspaceID
        panelID = try XCTUnwrap(selection.workspace.focusedPanelID)
        try configureState?(&state, workspaceID)

        store = AppStore(state: state, persistTerminalFontPreference: false)
        terminalRuntimeRegistry = TerminalRuntimeRegistry()
        terminalRuntimeRegistry.bind(store: store)
        let webPanelRuntimeRegistry = WebPanelRuntimeRegistry()
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        webPanelRuntimeRegistry.bind(store: store)

        let focusedPanelCommandController = FocusedPanelCommandController(
            store: store,
            runtimeRegistry: terminalRuntimeRegistry,
            slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()
        )
        let agentLaunchService = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalRuntimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: TestAgentCatalogProvider(),
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { "/tmp/toastty-test.sock" }
        )
        executor = AppControlExecutor(
            store: store,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            webPanelRuntimeRegistry: webPanelRuntimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            focusedPanelCommandController: focusedPanelCommandController,
            agentLaunchService: agentLaunchService,
            reloadConfigurationAction: nil
        )
    }
}
