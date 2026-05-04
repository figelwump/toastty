#if TOASTTY_HAS_GHOSTTY_KIT
@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class TerminalFileDropAppControlTests: XCTestCase {
    func testLegacyDropImageFilesActionAllowsNonImageFilesWhenSurfaceUnavailableIsAllowed() throws {
        let fixture = try TerminalFileDropAppControlFixture()
        let filePath = "/tmp/toastty drop note.md"

        let outcome = try fixture.executor.runAction(
            id: AppControlActionID.terminalDropImageFiles.rawValue,
            args: [
                "panelID": .string(fixture.panelID.uuidString),
                "files": .array([.string(filePath)]),
                "allowUnavailable": .bool(true),
            ]
        )
        let result = try XCTUnwrap(outcome.result)

        XCTAssertEqual(result.string("panelID"), fixture.panelID.uuidString)
        XCTAssertEqual(result.int("requestedFileCount"), 1)
        XCTAssertEqual(result.int("acceptedFileCount"), 0)
        XCTAssertEqual(result.int("acceptedImageCount"), 0)
        XCTAssertEqual(result.bool("available"), false)
    }
}

@MainActor
private struct TerminalFileDropAppControlFixture {
    let store: AppStore
    let executor: AppControlExecutor
    let panelID: UUID

    init() throws {
        store = AppStore(persistTerminalFontPreference: false)
        let selection = try XCTUnwrap(store.state.selectedWorkspaceSelection())
        panelID = try XCTUnwrap(selection.workspace.focusedPanelID)

        let terminalRuntimeRegistry = TerminalRuntimeRegistry()
        terminalRuntimeRegistry.bind(store: store)
        _ = terminalRuntimeRegistry.controller(
            for: panelID,
            workspaceID: selection.workspaceID,
            windowID: selection.windowID
        )

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
#endif
