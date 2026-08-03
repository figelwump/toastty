import CoreState
import Foundation
import XCTest
@testable import ToasttyApp

@MainActor
final class RightPanelRecentItemsAppStoreTests: XCTestCase {
    func testOpenRecentLocalDocumentCreatesRightPanelEvenWhenMainPanelAlreadyHasFile() throws {
        let state = AppState.bootstrap()
        let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let documentStore = ScratchpadDocumentStore(directoryURL: temporaryDirectory())
        let fileURL = temporaryDirectory()
            .appending(path: "README.md", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("# Preview\n".utf8).write(to: fileURL)

        XCTAssertTrue(
            store.createLocalDocumentPanel(
                workspaceID: workspaceID,
                request: LocalDocumentPanelCreateRequest(
                    filePath: fileURL.path,
                    placementOverride: .newTab
                )
            )
        )
        let workspaceBefore = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        let selectedTabBefore = try XCTUnwrap(workspaceBefore.selectedTab)
        let mainPanelID = try XCTUnwrap(workspaceBefore.focusedPanelID)
        XCTAssertNotNil(selectedTabBefore.panels[mainPanelID])
        XCTAssertTrue(selectedTabBefore.rightAuxPanel.tabIDs.isEmpty)

        XCTAssertTrue(
            store.openRecentRightPanelItem(
                RecentRightPanelItem(
                    id: .localDocument(path: fileURL.path),
                    title: "README.md",
                    updatedAt: Date()
                ),
                workspaceID: workspaceID,
                documentStore: documentStore
            )
        )

        let workspaceAfter = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        let selectedTabAfter = try XCTUnwrap(workspaceAfter.selectedTab)
        let rightPanelTab = try XCTUnwrap(selectedTabAfter.rightAuxPanel.activeTab)
        guard case .web(let webState) = rightPanelTab.panelState else {
            XCTFail("expected recent local document to open as web panel")
            return
        }

        XCTAssertEqual(workspaceAfter.focusedPanelID, mainPanelID)
        XCTAssertEqual(selectedTabAfter.rightAuxPanel.focusedPanelID, rightPanelTab.panelID)
        XCTAssertEqual(webState.definition, .localDocument)
        XCTAssertEqual(webState.localDocument?.filePath, fileURL.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    func testBrowserMetadataCoalescesRecentEntryForSamePanel() throws {
        let state = AppState.bootstrap()
        let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.createBrowserPanel(
                workspaceID: workspaceID,
                request: BrowserPanelCreateRequest(initialURL: "https://example.com/start")
            )
        )
        var workspace = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        let browserPanelID = try XCTUnwrap(workspace.rightAuxPanel.activePanelID)
        XCTAssertEqual(store.recentRightPanelItems, [])

        XCTAssertTrue(
            store.send(
                .updateWebPanelMetadata(
                    panelID: browserPanelID,
                    title: "First Page",
                    url: "https://example.com/first"
                )
            )
        )
        XCTAssertEqual(store.recentRightPanelItems.map(\.id), [
            .browser(url: "https://example.com/first"),
        ])

        XCTAssertTrue(
            store.send(
                .updateWebPanelMetadata(
                    panelID: browserPanelID,
                    title: "Second Page",
                    url: "https://example.com/second"
                )
            )
        )
        workspace = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        let activePanelID = try XCTUnwrap(workspace.rightAuxPanel.activePanelID)

        XCTAssertEqual(activePanelID, browserPanelID)
        XCTAssertEqual(store.recentRightPanelItems.map(\.id), [
            .browser(url: "https://example.com/second"),
        ])
        XCTAssertEqual(store.recentRightPanelItems.first?.title, "Second Page")
    }

    func testOpenRecentScratchpadUsesSavedDocumentWithoutSessionBinding() throws {
        let state = AppState.bootstrap()
        let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let documentStore = ScratchpadDocumentStore(directoryURL: temporaryDirectory())
        let sessionLink = ScratchpadSessionLink(
            sessionID: "session-1",
            agent: .codex,
            sourcePanelID: UUID(),
            sourceWorkspaceID: workspaceID,
            repoRoot: "/tmp/project",
            cwd: "/tmp/project",
            displayTitle: "Codex",
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let document = try documentStore.createDocument(
            title: "Architecture",
            content: "<h1>Architecture</h1>",
            sessionLink: sessionLink
        )

        XCTAssertTrue(
            store.openRecentRightPanelItem(
                RecentRightPanelItem(
                    id: .scratchpad(documentID: document.documentID),
                    title: "Architecture",
                    updatedAt: Date()
                ),
                workspaceID: workspaceID,
                documentStore: documentStore
            )
        )

        let workspace = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        let rightPanelTab = try XCTUnwrap(workspace.rightAuxPanel.activeTab)
        guard case .web(let webState) = rightPanelTab.panelState else {
            XCTFail("expected Scratchpad recent to open as web panel")
            return
        }
        let storedDocument = try XCTUnwrap(try documentStore.load(documentID: document.documentID))

        XCTAssertEqual(webState.definition, .scratchpad)
        XCTAssertEqual(webState.title, "Architecture")
        XCTAssertEqual(webState.scratchpad?.documentID, document.documentID)
        XCTAssertEqual(webState.scratchpad?.revision, document.revision)
        XCTAssertNil(webState.scratchpad?.sessionLink)
        XCTAssertEqual(storedDocument.sessionLink, sessionLink)
    }

    func testOpenRecentBrowserFocusesMatchingSelectedRightPanelTab() throws {
        let state = AppState.bootstrap()
        let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let documentStore = ScratchpadDocumentStore(directoryURL: temporaryDirectory())

        XCTAssertTrue(
            store.createBrowserPanel(
                workspaceID: workspaceID,
                request: BrowserPanelCreateRequest(initialURL: "https://example.com/docs")
            )
        )
        var workspace = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        let existingPanelID = try XCTUnwrap(workspace.rightAuxPanel.activePanelID)
        XCTAssertTrue(
            store.send(
                .updateWebPanelMetadata(
                    panelID: existingPanelID,
                    title: "Docs",
                    url: "https://example.com/docs"
                )
            )
        )

        XCTAssertTrue(
            store.openRecentRightPanelItem(
                RecentRightPanelItem(
                    id: .browser(url: "https://example.com/docs"),
                    title: "Docs",
                    detail: "example.com",
                    updatedAt: Date()
                ),
                workspaceID: workspaceID,
                documentStore: documentStore
            )
        )

        workspace = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspace.rightAuxPanel.tabIDs.count, 1)
        XCTAssertEqual(workspace.rightAuxPanel.focusedPanelID, existingPanelID)
    }

    func testOpenRecentExistingBrowserSeedsReplacementAfterRestart() throws {
        let state = AppState.bootstrap()
        let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let initialStore = AppStore(state: state, persistTerminalFontPreference: false)
        let documentStore = ScratchpadDocumentStore(directoryURL: temporaryDirectory())

        XCTAssertTrue(
            initialStore.createBrowserPanel(
                workspaceID: workspaceID,
                request: BrowserPanelCreateRequest(initialURL: "https://example.com/docs")
            )
        )
        let browserPanelID = try XCTUnwrap(
            initialStore.state.workspacesByID[workspaceID]?.rightAuxPanel.activePanelID
        )
        XCTAssertTrue(
            initialStore.send(
                .updateWebPanelMetadata(
                    panelID: browserPanelID,
                    title: "Docs",
                    url: "https://example.com/docs"
                )
            )
        )

        let recentItem = RecentRightPanelItem(
            id: .browser(url: "https://example.com/docs"),
            title: "Docs",
            detail: "example.com",
            updatedAt: Date()
        )
        let recentItemsStore = RightPanelRecentItemsStore.inMemory()
        recentItemsStore.record(recentItem)
        let restartedStore = AppStore(
            state: initialStore.state,
            persistTerminalFontPreference: false,
            recentRightPanelItemsStore: recentItemsStore
        )

        XCTAssertTrue(
            restartedStore.openRecentRightPanelItem(
                recentItem,
                workspaceID: workspaceID,
                documentStore: documentStore
            )
        )
        XCTAssertTrue(
            restartedStore.send(
                .updateWebPanelMetadata(
                    panelID: browserPanelID,
                    title: "Guide",
                    url: "https://example.com/guide"
                )
            )
        )

        XCTAssertEqual(restartedStore.recentRightPanelItems.map(\.id), [
            .browser(url: "https://example.com/guide"),
        ])
    }

    func testOpenRecentInvalidLocalDocumentPrunesRecentItem() throws {
        let state = AppState.bootstrap()
        let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let item = RecentRightPanelItem(
            id: .localDocument(path: "/tmp/unsupported.toastty-recents-test"),
            title: "Unsupported",
            updatedAt: Date()
        )
        let recentItemsStore = RightPanelRecentItemsStore.inMemory()
        recentItemsStore.record(item)
        let store = AppStore(
            state: state,
            persistTerminalFontPreference: false,
            recentRightPanelItemsStore: recentItemsStore
        )
        let documentStore = ScratchpadDocumentStore(directoryURL: temporaryDirectory())

        XCTAssertFalse(
            store.openRecentRightPanelItem(
                item,
                workspaceID: workspaceID,
                documentStore: documentStore
            )
        )
        XCTAssertEqual(store.recentRightPanelItems, [])
    }

    func testOpenRecentInvalidBrowserURLPrunesRecentItem() throws {
        let state = AppState.bootstrap()
        let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        let item = RecentRightPanelItem(
            id: .browser(url: "javascript:alert(1)"),
            title: "Script",
            updatedAt: Date()
        )
        let recentItemsStore = RightPanelRecentItemsStore.inMemory()
        recentItemsStore.record(item)
        let store = AppStore(
            state: state,
            persistTerminalFontPreference: false,
            recentRightPanelItemsStore: recentItemsStore
        )
        let documentStore = ScratchpadDocumentStore(directoryURL: temporaryDirectory())

        XCTAssertFalse(
            store.openRecentRightPanelItem(
                item,
                workspaceID: workspaceID,
                documentStore: documentStore
            )
        )
        XCTAssertEqual(store.recentRightPanelItems, [])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "toastty-right-panel-recents-app-store-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}
