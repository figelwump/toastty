@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class AppStoreWindowSelectionTests: AppStoreCommandTestCase {
    func testWindowLookupResolvesSpecificWindowWithoutUsingGlobalSelection() throws {
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

        let resolvedWindow = try XCTUnwrap(store.window(id: secondWindowID))
        let resolvedWorkspace = try XCTUnwrap(store.selectedWorkspace(in: secondWindowID))

        XCTAssertEqual(resolvedWindow.id, secondWindowID)
        XCTAssertEqual(resolvedWorkspace.id, secondWorkspace.id)
        XCTAssertEqual(store.selectedWorkspace?.id, firstWorkspace.id)
    }

    func testSelectedWorkspaceInWindowFallsBackToFirstWorkspaceWhenSelectionIsNil() throws {
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
                )
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: windowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        let resolvedWorkspace = try XCTUnwrap(store.selectedWorkspace(in: windowID))

        XCTAssertEqual(resolvedWorkspace.id, firstWorkspace.id)
        XCTAssertEqual(store.selectedWorkspace?.id, firstWorkspace.id)
    }

    func testCommandSelectionPrefersFocusedWindowOverGlobalSelection() throws {
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

        let selection = try XCTUnwrap(store.commandSelection(preferredWindowID: secondWindowID))

        XCTAssertEqual(selection.windowID, secondWindowID)
        XCTAssertEqual(selection.window.id, secondWindowID)
        XCTAssertEqual(selection.workspace.id, secondWorkspace.id)
    }

    func testCommandSelectionReturnsNilWhenFocusedWindowIsMissing() {
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

        XCTAssertNil(store.commandSelection(preferredWindowID: UUID()))
    }

    func testWindowLookupReturnsNilForUnknownWindowID() {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)

        XCTAssertNil(store.window(id: UUID()))
        XCTAssertNil(store.selectedWorkspaceID(in: UUID()))
        XCTAssertNil(store.selectedWorkspace(in: UUID()))
        XCTAssertNil(store.commandSelection(preferredWindowID: UUID()))
        XCTAssertNotNil(store.commandSelection(preferredWindowID: nil))
    }

    func testCommandSelectionReturnsNilWhenNoWindowCanBeResolved() {
        let workspace = WorkspaceState.bootstrap()
        let state = AppState(
            windows: [],
            workspacesByID: [workspace.id: workspace],
            selectedWindowID: nil
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertNil(store.commandSelection(preferredWindowID: UUID()))
        XCTAssertNil(store.commandSelection(preferredWindowID: nil))
    }

    func testJumpToNextActiveFocusesUnreadProcessWatchViaUnreadPanelPath() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let workspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
        let firstPanelID = try XCTUnwrap(store.state.workspacesByID[workspaceID]?.focusedPanelID)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)

        XCTAssertTrue(store.send(.splitFocusedSlotInDirection(workspaceID: workspaceID, direction: .right)))

        let workspaceAfterSplit = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        let watchedPanelID = try XCTUnwrap(workspaceAfterSplit.focusedPanelID)
        XCTAssertNotEqual(watchedPanelID, firstPanelID)
        XCTAssertTrue(store.send(.focusPanel(workspaceID: workspaceID, panelID: firstPanelID)))

        sessionRuntimeStore.startProcessWatch(
            sessionID: "watcher",
            panelID: watchedPanelID,
            windowID: windowID,
            workspaceID: workspaceID,
            displayTitleOverride: "npm test",
            cwd: "/tmp/project",
            repoRoot: nil,
            at: Date(timeIntervalSinceReferenceDate: 10)
        )
        XCTAssertTrue(
            sessionRuntimeStore.handleCommandFinished(
                panelID: watchedPanelID,
                exitCode: 0,
                at: Date(timeIntervalSinceReferenceDate: 20)
            )
        )

        let workspaceBeforeJump = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspaceBeforeJump.focusedPanelID, firstPanelID)
        XCTAssertEqual(workspaceBeforeJump.unreadPanelIDs, [watchedPanelID])

        XCTAssertTrue(
            store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionRuntimeStore
            )
        )

        let workspaceAfterJump = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspaceAfterJump.focusedPanelID, watchedPanelID)
        XCTAssertTrue(workspaceAfterJump.unreadPanelIDs.isEmpty)
    }

    func testPreferredLocalDocumentOpenDirectoryUsesFocusedTerminalLiveCWD() throws {
        let fileManager = FileManager.default
        let cwdURL = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-local-document-picker-cwd-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: cwdURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: cwdURL)
        }

        let fixture = makeSingleWindowState(initialTerminalCWD: cwdURL.path)
        let store = AppStore(state: fixture.state, persistTerminalFontPreference: false)

        XCTAssertEqual(
            store.preferredLocalDocumentOpenDirectoryURL(preferredWindowID: fixture.windowID)?.path,
            cwdURL.path
        )
    }

    func testPreferredLocalDocumentOpenDirectoryIgnoresNonTerminalFocusedPanel() throws {
        let fileManager = FileManager.default
        let cwdURL = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-local-document-picker-browser-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: cwdURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: cwdURL)
        }

        let fixture = makeSingleWindowState(initialTerminalCWD: cwdURL.path)
        let store = AppStore(state: fixture.state, persistTerminalFontPreference: false)

        XCTAssertTrue(
            store.createBrowserPanelFromCommand(
                preferredWindowID: fixture.windowID,
                request: BrowserPanelCreateRequest(
                    initialURL: "https://example.com",
                    placementOverride: .splitRight
                )
            )
        )

        XCTAssertNil(store.preferredLocalDocumentOpenDirectoryURL(preferredWindowID: fixture.windowID))
    }

    func testPreferredLocalDocumentOpenDirectoryIgnoresMissingFocusedTerminalCWD() {
        let missingCWD = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-local-document-picker-missing-\(UUID().uuidString)", isDirectory: true)
            .path
        let fixture = makeSingleWindowState(initialTerminalCWD: missingCWD)
        let store = AppStore(state: fixture.state, persistTerminalFontPreference: false)

        XCTAssertNil(store.preferredLocalDocumentOpenDirectoryURL(preferredWindowID: fixture.windowID))
    }

    func testSelectedWorkspaceInWindowReturnsNilWhenWindowHasNoWorkspaces() {
        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [],
                    selectedWorkspaceID: nil
                )
            ],
            workspacesByID: [:],
            selectedWindowID: windowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertNil(store.selectedWorkspaceID(in: windowID))
        XCTAssertNil(store.selectedWorkspace(in: windowID))
        XCTAssertNil(store.selectedWorkspace)
        XCTAssertNil(store.commandSelection(preferredWindowID: windowID))
    }

    func testCommandWindowIDResolvesFocusedWindowWithoutAnyWorkspaces() {
        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [],
                    selectedWorkspaceID: nil
                )
            ],
            workspacesByID: [:],
            selectedWindowID: windowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertEqual(store.commandWindowID(preferredWindowID: windowID), windowID)
        XCTAssertTrue(store.canCreateWorkspaceFromCommand(preferredWindowID: windowID))
    }

}
