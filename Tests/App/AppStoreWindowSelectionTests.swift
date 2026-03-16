@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class AppStoreWindowSelectionTests: XCTestCase {
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
            selectedWindowID: firstWindowID,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
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
            selectedWindowID: windowID,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
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
            selectedWindowID: firstWindowID,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
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
            selectedWindowID: firstWindowID,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
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
            selectedWindowID: nil,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertNil(store.commandSelection(preferredWindowID: UUID()))
        XCTAssertNil(store.commandSelection(preferredWindowID: nil))
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
            selectedWindowID: windowID,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
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
            selectedWindowID: windowID,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertEqual(store.commandWindowID(preferredWindowID: windowID), windowID)
        XCTAssertTrue(store.canCreateWorkspaceFromCommand(preferredWindowID: windowID))
    }

    func testCreateWorkspaceFromCommandPopulatesFocusedEmptyWindow() throws {
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
            selectedWindowID: windowID,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(store.createWorkspaceFromCommand(preferredWindowID: windowID))

        let window = try XCTUnwrap(store.window(id: windowID))
        let workspaceID = try XCTUnwrap(window.selectedWorkspaceID)
        XCTAssertEqual(window.workspaceIDs, [workspaceID])
        XCTAssertEqual(store.state.workspacesByID[workspaceID]?.title, "Workspace 1")
    }

    func testCreateWorkspaceFromCommandRecreatesFirstWindowFromEmptyState() throws {
        let expectedFrame = CGRectCodable(x: 320, y: 240, width: 1600, height: 960)
        let state = AppState(
            windows: [],
            workspacesByID: [:],
            selectedWindowID: nil,
            configuredTerminalFontPoints: 13,
            globalTerminalFontPoints: 15
        )
        let store = AppStore(
            state: state,
            persistTerminalFontPreference: false,
            commandCreateWindowFrameProvider: { expectedFrame }
        )

        XCTAssertTrue(store.canCreateWorkspaceFromCommand(preferredWindowID: nil))
        XCTAssertTrue(store.createWorkspaceFromCommand(preferredWindowID: nil))

        let window = try XCTUnwrap(store.state.windows.first)
        let workspaceID = try XCTUnwrap(window.selectedWorkspaceID)
        XCTAssertEqual(store.state.selectedWindowID, window.id)
        XCTAssertEqual(window.frame, expectedFrame)
        XCTAssertEqual(store.state.workspacesByID[workspaceID]?.title, "Workspace 1")
        XCTAssertEqual(store.state.configuredTerminalFontPoints, 13)
        XCTAssertEqual(store.state.globalTerminalFontPoints, 15)
    }

    func testCreateWorkspaceFromCommandSetsPendingRenameForNewWorkspace() throws {
        let windowID = UUID()
        let existingWorkspace = WorkspaceState.bootstrap(title: "One")
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [existingWorkspace.id],
                    selectedWorkspaceID: existingWorkspace.id
                )
            ],
            workspacesByID: [existingWorkspace.id: existingWorkspace],
            selectedWindowID: windowID,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertNil(store.pendingRenameWorkspaceID)
        XCTAssertTrue(store.createWorkspaceFromCommand(preferredWindowID: windowID))

        let newWorkspaceID = try XCTUnwrap(store.selectedWorkspaceID(in: windowID))
        XCTAssertNotEqual(newWorkspaceID, existingWorkspace.id)
        XCTAssertEqual(store.pendingRenameWorkspaceID, newWorkspaceID)
    }

    func testCreateWorkspaceFromCommandSetsPendingRenameForNewWindow() throws {
        let state = AppState(
            windows: [],
            workspacesByID: [:],
            selectedWindowID: nil,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertTrue(store.createWorkspaceFromCommand(preferredWindowID: nil))

        let newWindowID = try XCTUnwrap(store.state.selectedWindowID)
        let newWorkspaceID = try XCTUnwrap(store.selectedWorkspaceID(in: newWindowID))
        XCTAssertEqual(store.pendingRenameWorkspaceID, newWorkspaceID)
    }

    func testRenameSelectedWorkspaceFromCommandSetsPendingRename() throws {
        let workspace = WorkspaceState.bootstrap(title: "Dev")
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
        let store = AppStore(state: state, persistTerminalFontPreference: false)

        XCTAssertNil(store.pendingRenameWorkspaceID)
        store.renameSelectedWorkspaceFromCommand(preferredWindowID: windowID)
        XCTAssertEqual(store.pendingRenameWorkspaceID, workspace.id)
    }

    func testRenameSelectedWorkspaceFromCommandDoesNothingWithoutWorkspace() {
        let store = AppStore(
            state: AppState(
                windows: [],
                workspacesByID: [:],
                selectedWindowID: nil,
                globalTerminalFontPoints: AppState.defaultTerminalFontPoints
            ),
            persistTerminalFontPreference: false
        )

        store.renameSelectedWorkspaceFromCommand(preferredWindowID: nil)
        XCTAssertNil(store.pendingRenameWorkspaceID)
    }

    func testCreateWorkspaceFromCommandDoesNotRerouteMissingFocusedWindow() {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = store.state.windows[0].id
        let originalWorkspaceIDs = store.state.windows[0].workspaceIDs

        XCTAssertFalse(store.canCreateWorkspaceFromCommand(preferredWindowID: UUID()))
        XCTAssertFalse(store.createWorkspaceFromCommand(preferredWindowID: UUID()))

        XCTAssertEqual(store.state.windows[0].id, windowID)
        XCTAssertEqual(store.state.windows[0].workspaceIDs, originalWorkspaceIDs)
    }
}
