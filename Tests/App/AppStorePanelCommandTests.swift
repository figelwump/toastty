@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class AppStorePanelCommandTests: AppStoreCommandTestCase {
    func testCreateBrowserPanelFromCommandCreatesSelectedBrowserTab() throws {
        let state = AppState.bootstrap()
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.createBrowserPanelFromCommand(
                preferredWindowID: sourceWindowID,
                request: BrowserPanelCreateRequest(
                    initialURL: "https://example.com/docs",
                    placementOverride: .newTab
                )
            )
        )

        let workspace = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        XCTAssertEqual(workspace.orderedTabs.count, 2)
        let selectedTabID = try XCTUnwrap(workspace.resolvedSelectedTabID)
        let selectedTab = try XCTUnwrap(workspace.tab(id: selectedTabID))
        let panelID = try XCTUnwrap(selectedTab.focusedPanelID)
        guard case .web(let webState) = selectedTab.panels[panelID] else {
            XCTFail("expected selected tab panel to be web-backed browser")
            return
        }

        XCTAssertEqual(webState.definition, .browser)
        XCTAssertEqual(webState.initialURL, "https://example.com/docs")
        XCTAssertNil(webState.currentURL)
        XCTAssertNil(store.pendingBrowserLocationFocusRequest)
    }

    func testCreateBrowserPanelFromCommandCanSplitFocusedPanel() throws {
        let state = AppState.bootstrap()
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.createBrowserPanelFromCommand(
                preferredWindowID: sourceWindowID,
                request: BrowserPanelCreateRequest(
                    placementOverride: .splitRight
                )
            )
        )

        let workspace = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        XCTAssertEqual(workspace.layoutTree.allSlotInfos.count, 2)
        let focusedPanelID = try XCTUnwrap(workspace.focusedPanelID)
        guard case .web(let webState) = workspace.panels[focusedPanelID] else {
            XCTFail("expected focused split panel to be browser")
            return
        }

        XCTAssertEqual(webState.definition, .browser)
        XCTAssertNil(webState.initialURL)
        XCTAssertNil(webState.currentURL)
        XCTAssertEqual(store.pendingBrowserLocationFocusRequest?.windowID, sourceWindowID)
        XCTAssertEqual(store.pendingBrowserLocationFocusRequest?.workspaceID, sourceWorkspaceID)
        XCTAssertEqual(store.pendingBrowserLocationFocusRequest?.panelID, focusedPanelID)
        XCTAssertNotNil(store.pendingBrowserLocationFocusRequest?.requestID)
    }

    func testCreateBrowserPanelUsesDefaultPlacementWhenNoOverrideIsProvided() throws {
        let state = AppState.bootstrap()
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.createBrowserPanel(
                workspaceID: workspaceID,
                request: BrowserPanelCreateRequest()
            )
        )

        let workspace = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspace.orderedTabs.count, 1)
        XCTAssertEqual(workspace.layoutTree.allSlotInfos.count, 1)
        XCTAssertEqual(workspace.rightAuxPanel.tabIDs.count, 1)
        let tab = try XCTUnwrap(workspace.rightAuxPanel.activeTab)
        guard case .web(let webState) = tab.panelState else {
            XCTFail("expected active right-panel tab to be web-backed browser")
            return
        }

        XCTAssertNil(webState.initialURL)
        XCTAssertNil(webState.currentURL)
        XCTAssertEqual(workspace.rightAuxPanel.focusedPanelID, tab.panelID)
        XCTAssertEqual(store.pendingBrowserLocationFocusRequest?.windowID, sourceWindowID)
        XCTAssertEqual(store.pendingBrowserLocationFocusRequest?.workspaceID, workspaceID)
        XCTAssertEqual(store.pendingBrowserLocationFocusRequest?.panelID, tab.panelID)
        XCTAssertNotNil(store.pendingBrowserLocationFocusRequest?.requestID)
    }

    func testCreateBrowserPanelWithInitialURLDoesNotRequestLocationFocusInRightPanel() throws {
        let state = AppState.bootstrap()
        let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.createBrowserPanel(
                workspaceID: workspaceID,
                request: BrowserPanelCreateRequest(initialURL: "https://example.com")
            )
        )

        let workspace = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        let tab = try XCTUnwrap(workspace.rightAuxPanel.activeTab)
        guard case .web(let webState) = tab.panelState else {
            XCTFail("expected active right-panel tab to be web-backed browser")
            return
        }

        XCTAssertEqual(webState.initialURL, "https://example.com")
        XCTAssertEqual(workspace.rightAuxPanel.focusedPanelID, tab.panelID)
        XCTAssertNil(store.pendingBrowserLocationFocusRequest)
    }

    func testCreateMarkdownPanelFromCommandCreatesSelectedMarkdownTab() throws {
        let fixture = try makeMarkdownFixture()
        let state = AppState.bootstrap()
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.createLocalDocumentPanelFromCommand(
                preferredWindowID: sourceWindowID,
                request: LocalDocumentPanelCreateRequest(
                    filePath: fixture.canonicalPath,
                    placementOverride: .newTab
                )
            )
        )

        let workspace = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        XCTAssertEqual(workspace.orderedTabs.count, 2)
        let selectedTabID = try XCTUnwrap(workspace.resolvedSelectedTabID)
        let selectedTab = try XCTUnwrap(workspace.tab(id: selectedTabID))
        let panelID = try XCTUnwrap(selectedTab.focusedPanelID)
        guard case .web(let webState) = selectedTab.panels[panelID] else {
            XCTFail("expected selected tab panel to be markdown")
            return
        }

        XCTAssertEqual(webState.definition, .localDocument)
        XCTAssertEqual(webState.title, "README.md")
        XCTAssertEqual(webState.filePath, fixture.canonicalPath)
        XCTAssertEqual(
            webState.localDocument,
            LocalDocumentState(filePath: fixture.canonicalPath, format: .markdown)
        )
        XCTAssertNil(webState.initialURL)
        XCTAssertNil(webState.currentURL)
    }

    func testCreateMarkdownPanelFromCommandDefaultsToRightPanelPlacement() throws {
        let fixture = try makeMarkdownFixture()
        let state = AppState.bootstrap()
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.createLocalDocumentPanelFromCommand(
                preferredWindowID: sourceWindowID,
                request: LocalDocumentPanelCreateRequest(filePath: fixture.canonicalPath)
            )
        )

        let workspace = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        XCTAssertEqual(workspace.orderedTabs.count, 1)
        XCTAssertEqual(workspace.layoutTree.allSlotInfos.count, 1)
        XCTAssertEqual(workspace.rightAuxPanel.tabIDs.count, 1)
        let tab = try XCTUnwrap(workspace.rightAuxPanel.activeTab)
        guard case .web(let webState) = tab.panelState else {
            XCTFail("expected active right-panel tab to be markdown")
            return
        }

        XCTAssertEqual(webState.definition, .localDocument)
        XCTAssertEqual(webState.title, "README.md")
        XCTAssertEqual(webState.filePath, fixture.canonicalPath)
        XCTAssertEqual(workspace.rightAuxPanel.focusedPanelID, tab.panelID)
        XCTAssertEqual(
            webState.localDocument,
            LocalDocumentState(filePath: fixture.canonicalPath, format: .markdown)
        )
    }

    func testCreateMarkdownPanelFromCommandSupportsExactColonSuffixedFilename() throws {
        let fixture = try makeMarkdownFixture(fileName: "README.md:42")
        let state = AppState.bootstrap()
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.createLocalDocumentPanelFromCommand(
                preferredWindowID: sourceWindowID,
                request: LocalDocumentPanelCreateRequest(
                    filePath: fixture.canonicalPath,
                    placementOverride: .newTab
                )
            )
        )

        let workspace = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        let selectedTabID = try XCTUnwrap(workspace.resolvedSelectedTabID)
        let selectedTab = try XCTUnwrap(workspace.tab(id: selectedTabID))
        let panelID = try XCTUnwrap(selectedTab.focusedPanelID)
        guard case .web(let webState) = selectedTab.panels[panelID] else {
            XCTFail("expected selected tab panel to be markdown")
            return
        }

        XCTAssertEqual(webState.definition, .localDocument)
        XCTAssertEqual(webState.title, "README.md:42")
        XCTAssertEqual(webState.filePath, fixture.canonicalPath)
        XCTAssertEqual(
            webState.localDocument,
            LocalDocumentState(filePath: fixture.canonicalPath, format: .markdown)
        )
    }

    func testCreateYamlPanelFromCommandCreatesTypedLocalDocument() throws {
        let fixturePath = try makeLocalDocumentFixture(fileName: "config.yaml")
        let state = AppState.bootstrap()
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.createLocalDocumentPanelFromCommand(
                preferredWindowID: sourceWindowID,
                request: LocalDocumentPanelCreateRequest(
                    filePath: fixturePath,
                    placementOverride: .newTab
                )
            )
        )

        let workspace = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        let selectedTabID = try XCTUnwrap(workspace.resolvedSelectedTabID)
        let selectedTab = try XCTUnwrap(workspace.tab(id: selectedTabID))
        let panelID = try XCTUnwrap(selectedTab.focusedPanelID)
        guard case .web(let webState) = selectedTab.panels[panelID] else {
            XCTFail("expected selected tab panel to be local document")
            return
        }

        XCTAssertEqual(webState.definition, .localDocument)
        XCTAssertEqual(webState.filePath, fixturePath)
        XCTAssertEqual(webState.title, "config.yaml")
        XCTAssertEqual(
            webState.localDocument,
            LocalDocumentState(filePath: fixturePath, format: .yaml)
        )
    }

    func testCreateJsonPanelFromCommandCreatesTypedLocalDocument() throws {
        let fixturePath = try makeLocalDocumentFixture(
            fileName: "package.json",
            content: "{\n  \"name\": \"toastty\"\n}\n"
        )
        let state = AppState.bootstrap()
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.createLocalDocumentPanelFromCommand(
                preferredWindowID: sourceWindowID,
                request: LocalDocumentPanelCreateRequest(
                    filePath: fixturePath,
                    placementOverride: .newTab
                )
            )
        )

        let workspace = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        let selectedTabID = try XCTUnwrap(workspace.resolvedSelectedTabID)
        let selectedTab = try XCTUnwrap(workspace.tab(id: selectedTabID))
        let panelID = try XCTUnwrap(selectedTab.focusedPanelID)
        guard case .web(let webState) = selectedTab.panels[panelID] else {
            XCTFail("expected selected tab panel to be local document")
            return
        }

        XCTAssertEqual(webState.definition, .localDocument)
        XCTAssertEqual(webState.filePath, fixturePath)
        XCTAssertEqual(webState.title, "package.json")
        XCTAssertEqual(
            webState.localDocument,
            LocalDocumentState(filePath: fixturePath, format: .json)
        )
    }

    func testCreateExtensionlessPanelFromCommandUsesExplicitFormatOverride() throws {
        let fixturePath = try makeLocalDocumentFixture(
            fileName: "config",
            content: "terminal-font-size = 13\n"
        )
        let state = AppState.bootstrap()
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.createLocalDocumentPanelFromCommand(
                preferredWindowID: sourceWindowID,
                request: LocalDocumentPanelCreateRequest(
                    filePath: fixturePath,
                    placementOverride: .newTab,
                    formatOverride: .toml
                )
            )
        )

        let workspace = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        let selectedTabID = try XCTUnwrap(workspace.resolvedSelectedTabID)
        let selectedTab = try XCTUnwrap(workspace.tab(id: selectedTabID))
        let panelID = try XCTUnwrap(selectedTab.focusedPanelID)
        guard case .web(let webState) = selectedTab.panels[panelID] else {
            XCTFail("expected selected tab panel to be local document")
            return
        }

        XCTAssertEqual(webState.definition, .localDocument)
        XCTAssertEqual(webState.filePath, fixturePath)
        XCTAssertEqual(webState.title, "config")
        XCTAssertEqual(
            webState.localDocument,
            LocalDocumentState(filePath: fixturePath, format: .toml)
        )
    }

    func testCreateMarkdownPanelDeduplicatesByNormalizedFilePathInWorkspace() throws {
        let fixture = try makeMarkdownFixture()
        let state = AppState.bootstrap()
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.createLocalDocumentPanelFromCommand(
                preferredWindowID: sourceWindowID,
                request: LocalDocumentPanelCreateRequest(
                    filePath: fixture.canonicalPath,
                    placementOverride: .newTab
                )
            )
        )

        let workspaceAfterCreate = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        let markdownTabID = try XCTUnwrap(workspaceAfterCreate.resolvedSelectedTabID)
        let markdownPanelID = try XCTUnwrap(workspaceAfterCreate.tab(id: markdownTabID)?.focusedPanelID)
        let originalTabID = try XCTUnwrap(workspaceAfterCreate.tabIDs.first)

        XCTAssertTrue(store.send(.selectWorkspaceTab(workspaceID: sourceWorkspaceID, tabID: originalTabID)))
        XCTAssertTrue(
            store.createLocalDocumentPanelFromCommand(
                preferredWindowID: sourceWindowID,
                request: LocalDocumentPanelCreateRequest(
                    filePath: fixture.alternatePath,
                    placementOverride: .splitRight
                )
            )
        )

        let workspaceAfterDedupedOpen = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        XCTAssertEqual(workspaceAfterDedupedOpen.orderedTabs.count, 2)
        XCTAssertEqual(workspaceAfterDedupedOpen.resolvedSelectedTabID, markdownTabID)
        XCTAssertEqual(workspaceAfterDedupedOpen.focusedPanelID, markdownPanelID)
    }

    func testCreateMarkdownPanelOutcomeReportsOpenedPanelIDForNewPanel() throws {
        let fixture = try makeMarkdownFixture()
        let state = AppState.bootstrap()
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        let outcome = store.createLocalDocumentPanelFromCommandOutcome(
            preferredWindowID: sourceWindowID,
            request: LocalDocumentPanelCreateRequest(
                filePath: fixture.canonicalPath,
                lineNumber: 17,
                placementOverride: .newTab
            )
        )

        let panelID: UUID
        switch outcome {
        case .opened(let createdPanelID):
            panelID = createdPanelID
        default:
            XCTFail("expected opened panel outcome")
            return
        }

        let workspace = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        let selectedTabID = try XCTUnwrap(workspace.resolvedSelectedTabID)
        let selectedTab = try XCTUnwrap(workspace.tab(id: selectedTabID))
        XCTAssertEqual(selectedTab.focusedPanelID, panelID)
    }

    func testCreateMarkdownPanelOutcomeReportsFocusedExistingPanelIDWhenDeduped() throws {
        let fixture = try makeMarkdownFixture()
        let state = AppState.bootstrap()
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.createLocalDocumentPanelFromCommand(
                preferredWindowID: sourceWindowID,
                request: LocalDocumentPanelCreateRequest(
                    filePath: fixture.canonicalPath,
                    placementOverride: .newTab
                )
            )
        )

        let workspaceAfterCreate = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        let existingTabID = try XCTUnwrap(workspaceAfterCreate.resolvedSelectedTabID)
        let existingPanelID = try XCTUnwrap(workspaceAfterCreate.tab(id: existingTabID)?.focusedPanelID)
        let originalTabID = try XCTUnwrap(workspaceAfterCreate.tabIDs.first)
        XCTAssertTrue(store.send(.selectWorkspaceTab(workspaceID: sourceWorkspaceID, tabID: originalTabID)))

        let outcome = store.createLocalDocumentPanelFromCommandOutcome(
            preferredWindowID: sourceWindowID,
            request: LocalDocumentPanelCreateRequest(
                filePath: fixture.alternatePath,
                lineNumber: 42,
                placementOverride: .splitRight
            )
        )

        XCTAssertEqual(outcome, .focusedExisting(panelID: existingPanelID))
        let workspaceAfterDedupedOpen = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        XCTAssertEqual(workspaceAfterDedupedOpen.resolvedSelectedTabID, existingTabID)
        XCTAssertEqual(workspaceAfterDedupedOpen.focusedPanelID, existingPanelID)
    }

    func testCreateLocalDocumentRightPanelDedupesAndFocusesExistingTabWithoutChangingMainFocus() throws {
        let fixture = try makeMarkdownFixture()
        let state = AppState.bootstrap()
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let workspaceBefore = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        let focusedPanelIDBefore = try XCTUnwrap(workspaceBefore.focusedPanelID)

        let openedOutcome = store.createLocalDocumentPanelFromCommandOutcome(
            preferredWindowID: sourceWindowID,
            request: LocalDocumentPanelCreateRequest(
                filePath: fixture.canonicalPath,
                placementOverride: .rightPanel
            )
        )
        guard case .opened(let openedPanelID)? = openedOutcome else {
            XCTFail("expected opened panel outcome")
            return
        }

        XCTAssertTrue(store.send(.focusPanel(workspaceID: sourceWorkspaceID, panelID: focusedPanelIDBefore)))
        let workspaceAfterMainRefocus = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        XCTAssertNil(workspaceAfterMainRefocus.rightAuxPanel.focusedPanelID)

        let dedupedOutcome = store.createLocalDocumentPanelFromCommandOutcome(
            preferredWindowID: sourceWindowID,
            request: LocalDocumentPanelCreateRequest(
                filePath: fixture.alternatePath,
                placementOverride: .rightPanel
            )
        )

        XCTAssertEqual(dedupedOutcome, .focusedExisting(panelID: openedPanelID))
        let workspaceAfterDedupedOpen = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        XCTAssertEqual(workspaceAfterDedupedOpen.focusedPanelID, focusedPanelIDBefore)
        XCTAssertEqual(workspaceAfterDedupedOpen.rightAuxPanel.tabIDs.count, 1)
        XCTAssertEqual(workspaceAfterDedupedOpen.rightAuxPanel.activePanelID, openedPanelID)
        XCTAssertEqual(workspaceAfterDedupedOpen.rightAuxPanel.focusedPanelID, openedPanelID)
    }

    func testCreateLocalDocumentPanelFromCommandOpensTextFilesAsCodeDocuments() throws {
        let textPath = try makeLocalDocumentFixture(
            fileName: "README.txt",
            content: "plain text\n"
        )
        let state = AppState.bootstrap()
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.createLocalDocumentPanelFromCommand(
                preferredWindowID: sourceWindowID,
                request: LocalDocumentPanelCreateRequest(filePath: textPath)
            )
        )

        let workspace = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        let tab = try XCTUnwrap(workspace.rightAuxPanel.activeTab)
        guard case .web(let webState) = tab.panelState else {
            XCTFail("expected active right-panel tab to be local-document-backed")
            return
        }

        XCTAssertEqual(
            webState.localDocument,
            LocalDocumentState(filePath: textPath, format: .code)
        )
    }

    func testCreateLocalDocumentPanelFromCommandRejectsUnsupportedFileExtension() throws {
        let unsupportedPath = try makeUnsupportedFixture()
        let state = AppState.bootstrap()
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertFalse(
            store.createLocalDocumentPanelFromCommand(
                preferredWindowID: sourceWindowID,
                request: LocalDocumentPanelCreateRequest(filePath: unsupportedPath)
            )
        )

        let workspace = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        XCTAssertEqual(workspace.orderedTabs.count, 1)
        XCTAssertEqual(workspace.layoutTree.allSlotInfos.count, 1)
    }

    func testCreateMarkdownPanelDeduplicatesResolvedSymlinkPathInWorkspace() throws {
        let fixture = try makeSymlinkedMarkdownFixture()
        let state = AppState.bootstrap()
        let sourceWindowID = try XCTUnwrap(state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.createLocalDocumentPanelFromCommand(
                preferredWindowID: sourceWindowID,
                request: LocalDocumentPanelCreateRequest(
                    filePath: fixture.canonicalPath,
                    placementOverride: .newTab
                )
            )
        )

        let workspaceAfterCreate = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        let markdownTabID = try XCTUnwrap(workspaceAfterCreate.resolvedSelectedTabID)
        let markdownPanelID = try XCTUnwrap(workspaceAfterCreate.tab(id: markdownTabID)?.focusedPanelID)
        let originalTabID = try XCTUnwrap(workspaceAfterCreate.tabIDs.first)

        XCTAssertTrue(store.send(.selectWorkspaceTab(workspaceID: sourceWorkspaceID, tabID: originalTabID)))
        XCTAssertTrue(
            store.createLocalDocumentPanelFromCommand(
                preferredWindowID: sourceWindowID,
                request: LocalDocumentPanelCreateRequest(
                    filePath: fixture.symlinkPath,
                    placementOverride: .splitRight
                )
            )
        )

        let workspaceAfterDedupedOpen = try XCTUnwrap(store.state.workspacesByID[sourceWorkspaceID])
        XCTAssertEqual(workspaceAfterDedupedOpen.orderedTabs.count, 2)
        XCTAssertEqual(workspaceAfterDedupedOpen.resolvedSelectedTabID, markdownTabID)
        XCTAssertEqual(workspaceAfterDedupedOpen.focusedPanelID, markdownPanelID)
    }

    func testOpenURLInBrowserUsesConfiguredRightPanelPlacement() throws {
        let state = AppState.bootstrap()
        let windowID = try XCTUnwrap(state.windows.first?.id)
        let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let url = try XCTUnwrap(URL(string: "https://example.com/right"))

        XCTAssertTrue(
            store.openURLInBrowser(
                preferredWindowID: windowID,
                url: url,
                placement: .rightPanel
            )
        )

        let workspace = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspace.orderedTabs.count, 1)
        XCTAssertEqual(workspace.layoutTree.allSlotInfos.count, 1)
        XCTAssertEqual(workspace.rightAuxPanel.tabIDs.count, 1)
        let tab = try XCTUnwrap(workspace.rightAuxPanel.activeTab)
        guard case .web(let webState) = tab.panelState else {
            XCTFail("expected active right-panel tab to be browser")
            return
        }

        XCTAssertEqual(webState.initialURL, url.absoluteString)
    }

    func testOpenURLInBrowserUsesConfiguredNewTabPlacement() throws {
        let state = AppState.bootstrap()
        let windowID = try XCTUnwrap(state.windows.first?.id)
        let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let url = try XCTUnwrap(URL(string: "https://example.com/new-tab"))

        XCTAssertTrue(
            store.openURLInBrowser(
                preferredWindowID: windowID,
                url: url,
                placement: .newTab
            )
        )

        let workspace = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspace.orderedTabs.count, 2)
        let selectedTabID = try XCTUnwrap(workspace.resolvedSelectedTabID)
        let selectedTab = try XCTUnwrap(workspace.tab(id: selectedTabID))
        let panelID = try XCTUnwrap(selectedTab.focusedPanelID)
        guard case .web(let webState) = selectedTab.panels[panelID] else {
            XCTFail("expected selected panel to be browser")
            return
        }

        XCTAssertEqual(webState.initialURL, url.absoluteString)
    }

    func testFocusedBrowserPanelSelectionReturnsFocusedBrowserInPreferredWindow() throws {
        let state = AppState.bootstrap()
        let windowID = try XCTUnwrap(state.windows.first?.id)
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.createBrowserPanelFromCommand(
                preferredWindowID: windowID,
                request: BrowserPanelCreateRequest(
                    initialURL: "https://example.com/docs",
                    placementOverride: .splitRight
                )
            )
        )

        let selection = try XCTUnwrap(
            store.focusedBrowserPanelSelection(preferredWindowID: windowID)
        )
        let workspace = try XCTUnwrap(store.state.workspacesByID[selection.workspaceID])
        guard case .web(let webState) = workspace.panels[selection.panelID] else {
            XCTFail("expected focused browser selection to resolve a browser panel")
            return
        }

        XCTAssertEqual(selection.windowID, windowID)
        XCTAssertEqual(selection.workspaceID, workspace.id)
        XCTAssertEqual(webState.definition, .browser)
    }

    func testFocusedBrowserPanelSelectionReturnsNilWhenFocusedPanelIsTerminal() {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)

        XCTAssertNil(store.focusedBrowserPanelSelection(preferredWindowID: nil))
    }

    func testFocusedScaleCommandTargetReturnsTerminalForFocusedTerminal() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)

        XCTAssertEqual(
            store.focusedScaleCommandTarget(preferredWindowID: windowID),
            .terminal(windowID: windowID)
        )
    }

    func testFocusedScaleCommandTargetReturnsMarkdownForFocusedMarkdown() throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let fileURL = tempDirectoryURL.appendingPathComponent("README.md")
        try "# Preview\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)

        XCTAssertTrue(
            store.createLocalDocumentPanelFromCommand(
                preferredWindowID: windowID,
                request: LocalDocumentPanelCreateRequest(
                    filePath: fileURL.path,
                    placementOverride: .splitRight
                )
            )
        )

        XCTAssertEqual(
            store.focusedScaleCommandTarget(preferredWindowID: windowID),
            .markdown(windowID: windowID)
        )
    }

    func testFocusedScaleCommandTargetReturnsBrowserForFocusedBrowser() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)

        XCTAssertTrue(
            store.createBrowserPanelFromCommand(
                preferredWindowID: windowID,
                request: BrowserPanelCreateRequest(
                    initialURL: "https://example.com",
                    placementOverride: .splitRight
                )
            )
        )

        let browserSelection = try XCTUnwrap(store.focusedBrowserPanelSelection(preferredWindowID: windowID))
        XCTAssertEqual(
            store.focusedScaleCommandTarget(preferredWindowID: windowID),
            .browser(windowID: windowID, panelID: browserSelection.panelID)
        )
    }

    func testFocusPanelContainingBrowserSelectsBrowserTab() throws {
        let initialState = AppState.bootstrap()
        let windowID = try XCTUnwrap(initialState.windows.first?.id)
        let workspaceID = try XCTUnwrap(initialState.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: initialState, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.createBrowserPanelFromCommand(
                preferredWindowID: windowID,
                request: BrowserPanelCreateRequest(
                    initialURL: "https://example.com",
                    placementOverride: .newTab
                )
            )
        )

        let workspaceAfterCreate = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        let browserTabID = try XCTUnwrap(workspaceAfterCreate.resolvedSelectedTabID)
        let browserPanelID = try XCTUnwrap(workspaceAfterCreate.tab(id: browserTabID)?.focusedPanelID)
        let originalTabID = try XCTUnwrap(workspaceAfterCreate.tabIDs.first)

        XCTAssertTrue(store.send(.selectWorkspaceTab(workspaceID: workspaceID, tabID: originalTabID)))
        XCTAssertTrue(store.focusPanel(containing: browserPanelID))

        let workspaceAfterFocus = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspaceAfterFocus.resolvedSelectedTabID, browserTabID)
        XCTAssertEqual(workspaceAfterFocus.focusedPanelID, browserPanelID)
    }

}
