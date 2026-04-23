import CoreState
import Foundation
import XCTest
@testable import ToasttyApp

@MainActor
final class CommandPaletteFileOpenIntegrationTests: XCTestCase {
    func testFileSearchScopeUsesFocusedTerminalRepoRootWhenInferable() throws {
        let repoRootURL = try makeRepositoryScope()
        let nestedURL = repoRootURL.appendingPathComponent("Sources/App", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)

        let state = makeStateWithFocusedTerminalCWD(nestedURL.path)
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let actions = try makeLiveActions(store: store)
        let originWindowID = try XCTUnwrap(store.state.windows.first?.id)

        XCTAssertEqual(
            actions.fileSearchScope(originWindowID: originWindowID),
            PaletteFileSearchScope(
                rootPath: repoRootURL.path,
                kind: .repositoryRoot
            )
        )
    }

    func testFileSearchScopeFallsBackToFirstTerminalInSlotOrder() throws {
        let firstScopeURL = try makeDirectoryScope()
        let secondScopeURL = try makeDirectoryScope()

        var state = AppState.bootstrap()
        let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        state.workspacesByID[workspaceID] = makeWorkspaceWithFocusedBrowser(
            workspaceID: workspaceID,
            firstTerminalCWD: firstScopeURL.path,
            secondTerminalCWD: secondScopeURL.path
        )

        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let actions = try makeLiveActions(store: store)
        let originWindowID = try XCTUnwrap(store.state.windows.first?.id)

        XCTAssertEqual(
            actions.fileSearchScope(originWindowID: originWindowID),
            PaletteFileSearchScope(
                rootPath: firstScopeURL.path,
                kind: .workingDirectory
            )
        )
    }

    func testOpenFileResultRoutesHTMLToBrowserPanel() throws {
        let scopeURL = try makeDirectoryScope()
        let fileURL = scopeURL.appendingPathComponent("index.html")
        try writeFixtureFile(at: fileURL, contents: "<html></html>\n")

        let state = makeStateWithFocusedTerminalCWD(scopeURL.path)
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let actions = try makeLiveActions(store: store)
        let originWindowID = try XCTUnwrap(store.state.windows.first?.id)

        XCTAssertTrue(
            actions.openFileResult(
                .browser(fileURLString: fileURL.absoluteString),
                placement: .default,
                originWindowID: originWindowID
            )
        )

        let browserSelection = try XCTUnwrap(
            store.focusedBrowserPanelSelection(preferredWindowID: originWindowID)
        )
        let workspace = try XCTUnwrap(store.state.workspacesByID[browserSelection.workspaceID])
        guard case .web(let webState) = workspace.panels[browserSelection.panelID] else {
            XCTFail("expected focused panel to be browser-backed")
            return
        }

        XCTAssertEqual(webState.definition, .browser)
        XCTAssertEqual(webState.initialURL, fileURL.absoluteString)
    }

    func testOpenFileResultReusesExistingLocalDocumentPanel() throws {
        let scopeURL = try makeDirectoryScope()
        let fileURL = scopeURL.appendingPathComponent("package.json")
        try writeFixtureFile(
            at: fileURL,
            contents: "{\n  \"name\": \"toastty\"\n}\n"
        )

        let state = makeStateWithFocusedTerminalCWD(scopeURL.path)
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let actions = try makeLiveActions(store: store)
        let originWindowID = try XCTUnwrap(store.state.windows.first?.id)
        let workspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
        let workspaceBeforeOpen = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        let originalTerminalPanelID = try XCTUnwrap(workspaceBeforeOpen.focusedPanelID)

        XCTAssertTrue(
            actions.openFileResult(
                .localDocument(filePath: fileURL.path),
                placement: .default,
                originWindowID: originWindowID
            )
        )

        let workspaceAfterFirstOpen = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspaceAfterFirstOpen.panels.count, 2)
        let localDocumentPanelID = try XCTUnwrap(workspaceAfterFirstOpen.focusedPanelID)

        XCTAssertTrue(
            store.send(.focusPanel(workspaceID: workspaceID, panelID: originalTerminalPanelID))
        )
        XCTAssertTrue(
            actions.openFileResult(
                .localDocument(filePath: fileURL.path),
                placement: .default,
                originWindowID: originWindowID
            )
        )

        let workspaceAfterReuse = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspaceAfterReuse.panels.count, 2)
        XCTAssertEqual(workspaceAfterReuse.focusedPanelID, localDocumentPanelID)

        guard case .web(let webState) = workspaceAfterReuse.panels[localDocumentPanelID] else {
            XCTFail("expected focused panel to stay on the reused local document")
            return
        }

        XCTAssertEqual(webState.definition, .localDocument)
        XCTAssertEqual(
            webState.localDocument,
            LocalDocumentState(filePath: fileURL.path, format: .json)
        )
    }

    func testOpenFileResultOpensTextFilesAsLocalDocuments() throws {
        let scopeURL = try makeDirectoryScope()
        let fileURL = scopeURL.appendingPathComponent("notes.txt")
        try writeFixtureFile(at: fileURL, contents: "plain text\n")

        let state = makeStateWithFocusedTerminalCWD(scopeURL.path)
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let actions = try makeLiveActions(store: store)
        let originWindowID = try XCTUnwrap(store.state.windows.first?.id)
        let workspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)

        XCTAssertTrue(
            actions.openFileResult(
                .localDocument(filePath: fileURL.path),
                placement: .default,
                originWindowID: originWindowID
            )
        )

        let workspace = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        let panelID = try XCTUnwrap(workspace.focusedPanelID)
        guard case .web(let webState) = workspace.panels[panelID] else {
            XCTFail("expected focused panel to be local-document-backed")
            return
        }

        XCTAssertEqual(webState.definition, .localDocument)
        XCTAssertEqual(
            webState.localDocument,
            LocalDocumentState(filePath: fileURL.path, format: .code)
        )
    }

    func testOpenFileResultAlternatePlacementOpensLocalDocumentInNewTab() throws {
        let scopeURL = try makeDirectoryScope()
        let fileURL = scopeURL.appendingPathComponent("README.md")
        try writeFixtureFile(at: fileURL, contents: "# Toastty\n")

        let state = makeStateWithFocusedTerminalCWD(scopeURL.path)
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let actions = try makeLiveActions(store: store)
        let originWindowID = try XCTUnwrap(store.state.windows.first?.id)
        let workspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)

        XCTAssertTrue(
            actions.openFileResult(
                .localDocument(filePath: fileURL.path),
                placement: .alternate,
                originWindowID: originWindowID
            )
        )

        let workspace = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspace.orderedTabs.count, 2)
        let selectedTabID = try XCTUnwrap(workspace.resolvedSelectedTabID)
        let selectedTab = try XCTUnwrap(workspace.tab(id: selectedTabID))
        let panelID = try XCTUnwrap(selectedTab.focusedPanelID)
        guard case .web(let webState) = selectedTab.panels[panelID] else {
            XCTFail("expected selected tab panel to be local-document-backed")
            return
        }

        XCTAssertEqual(webState.definition, .localDocument)
        XCTAssertEqual(
            webState.localDocument,
            LocalDocumentState(filePath: fileURL.path, format: .markdown)
        )
    }

    func testOpenFileResultAlternatePlacementOpensHTMLInNewTab() throws {
        let scopeURL = try makeDirectoryScope()
        let fileURL = scopeURL.appendingPathComponent("index.html")
        try writeFixtureFile(at: fileURL, contents: "<html></html>\n")

        let state = makeStateWithFocusedTerminalCWD(scopeURL.path)
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let actions = try makeLiveActions(store: store)
        let originWindowID = try XCTUnwrap(store.state.windows.first?.id)
        let workspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)

        XCTAssertTrue(
            actions.openFileResult(
                .browser(fileURLString: fileURL.absoluteString),
                placement: .alternate,
                originWindowID: originWindowID
            )
        )

        let workspace = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspace.orderedTabs.count, 2)
        let selectedTabID = try XCTUnwrap(workspace.resolvedSelectedTabID)
        let selectedTab = try XCTUnwrap(workspace.tab(id: selectedTabID))
        let panelID = try XCTUnwrap(selectedTab.focusedPanelID)
        guard case .web(let webState) = selectedTab.panels[panelID] else {
            XCTFail("expected selected tab panel to be browser-backed")
            return
        }

        XCTAssertEqual(webState.definition, .browser)
        XCTAssertEqual(webState.initialURL, fileURL.absoluteString)
    }

    func testOpenFileResultAlternatePlacementStillReusesExistingLocalDocumentPanel() throws {
        let scopeURL = try makeDirectoryScope()
        let fileURL = scopeURL.appendingPathComponent("package.json")
        try writeFixtureFile(
            at: fileURL,
            contents: "{\n  \"name\": \"toastty\"\n}\n"
        )

        let state = makeStateWithFocusedTerminalCWD(scopeURL.path)
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let actions = try makeLiveActions(store: store)
        let originWindowID = try XCTUnwrap(store.state.windows.first?.id)
        let workspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)

        XCTAssertTrue(
            actions.openFileResult(
                .localDocument(filePath: fileURL.path),
                placement: .alternate,
                originWindowID: originWindowID
            )
        )

        let workspaceAfterFirstOpen = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspaceAfterFirstOpen.orderedTabs.count, 2)
        let localDocumentTabID = try XCTUnwrap(workspaceAfterFirstOpen.resolvedSelectedTabID)
        let localDocumentPanelID = try XCTUnwrap(workspaceAfterFirstOpen.focusedPanelID)
        let originalTabID = try XCTUnwrap(workspaceAfterFirstOpen.tabIDs.first)

        XCTAssertTrue(
            store.send(.selectWorkspaceTab(workspaceID: workspaceID, tabID: originalTabID))
        )
        XCTAssertTrue(
            actions.openFileResult(
                .localDocument(filePath: fileURL.path),
                placement: .alternate,
                originWindowID: originWindowID
            )
        )

        let workspaceAfterReuse = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspaceAfterReuse.orderedTabs.count, 2)
        XCTAssertEqual(workspaceAfterReuse.resolvedSelectedTabID, localDocumentTabID)
        XCTAssertEqual(workspaceAfterReuse.focusedPanelID, localDocumentPanelID)
    }

    private func makeLiveActions(store: AppStore) throws -> CommandPaletteActionHandler {
        let runtimeRegistry = TerminalRuntimeRegistry()
        runtimeRegistry.bind(store: store)

        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        runtimeRegistry.bind(sessionLifecycleTracker: sessionRuntimeStore)

        let homeDirectoryPath = (try makeDirectoryScope()).path
        let agentCatalogStore = AgentCatalogStore(
            fileManager: .default,
            homeDirectoryPath: homeDirectoryPath
        )
        let terminalProfileStore = TerminalProfileStore(
            fileManager: .default,
            homeDirectoryPath: homeDirectoryPath,
            environment: [:]
        )
        let agentLaunchService = AgentLaunchService(
            store: store,
            terminalCommandRouter: runtimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: agentCatalogStore
        )
        let terminalProfilesMenuController = TerminalProfilesMenuController(
            store: store,
            terminalRuntimeRegistry: runtimeRegistry,
            terminalProfileProvider: terminalProfileStore,
            installShellIntegrationAction: {},
            openProfilesConfigurationAction: {}
        )

        return CommandPaletteActionHandler(
            store: store,
            splitLayoutCommandController: SplitLayoutCommandController(store: store),
            focusedPanelCommandController: FocusedPanelCommandController(
                store: store,
                runtimeRegistry: runtimeRegistry,
                slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()
            ),
            terminalRuntimeRegistry: runtimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            agentLaunchService: agentLaunchService,
            terminalProfilesMenuController: terminalProfilesMenuController,
            supportsConfigurationReload: { true },
            reloadConfigurationAction: {},
            openLocalDocumentAction: { _, _ in false }
        )
    }

    private func makeStateWithFocusedTerminalCWD(_ cwd: String) -> AppState {
        var state = AppState.bootstrap()
        let workspaceID = state.windows[0].selectedWorkspaceID!
        var workspace = state.workspacesByID[workspaceID]!
        let panelID = workspace.focusedPanelID!
        workspace.panels[panelID] = .terminal(
            TerminalPanelState(
                title: "Terminal 1",
                shell: "zsh",
                cwd: cwd
            )
        )
        state.workspacesByID[workspaceID] = workspace
        return state
    }

    private func makeWorkspaceWithFocusedBrowser(
        workspaceID: UUID,
        firstTerminalCWD: String,
        secondTerminalCWD: String
    ) -> WorkspaceState {
        let browserPanelID = UUID()
        let browserSlotID = UUID()
        let firstTerminalPanelID = UUID()
        let firstTerminalSlotID = UUID()
        let secondTerminalPanelID = UUID()
        let secondTerminalSlotID = UUID()
        let nestedSplitNodeID = UUID()
        let rootSplitNodeID = UUID()

        return WorkspaceState(
            id: workspaceID,
            title: "Workspace 1",
            layoutTree: .split(
                nodeID: rootSplitNodeID,
                orientation: .horizontal,
                ratio: 0.5,
                first: .slot(slotID: browserSlotID, panelID: browserPanelID),
                second: .split(
                    nodeID: nestedSplitNodeID,
                    orientation: .vertical,
                    ratio: 0.5,
                    first: .slot(slotID: firstTerminalSlotID, panelID: firstTerminalPanelID),
                    second: .slot(slotID: secondTerminalSlotID, panelID: secondTerminalPanelID)
                )
            ),
            panels: [
                browserPanelID: .web(WebPanelState(definition: .browser)),
                firstTerminalPanelID: .terminal(
                    TerminalPanelState(title: "Terminal A", shell: "zsh", cwd: firstTerminalCWD)
                ),
                secondTerminalPanelID: .terminal(
                    TerminalPanelState(title: "Terminal B", shell: "zsh", cwd: secondTerminalCWD)
                ),
            ],
            focusedPanelID: browserPanelID
        )
    }

    private func makeRepositoryScope() throws -> URL {
        let rootURL = try makeDirectoryScope()
        let gitURL = rootURL.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitURL, withIntermediateDirectories: true)
        return rootURL
    }

    private func makeDirectoryScope() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeFixtureFile(at fileURL: URL, contents: String) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
